--- Sliding-pane motion for tab switches.
--
-- Switching a tab replaces the whole content area instantly, which gives the user
-- no cue about where the old content went or where the new content came from. On a
-- strip with a dozen tabs and nested groups, that costs real orientation. This
-- module reintroduces the missing spatial information: pages slide horizontally in
-- the direction implied by their position in the strip.
--
-- ### Carbon "pushing", not "sliding"
--
-- Carbon distinguishes two same-direction transitions. A panel on a *higher* layer
-- **slides** over the content below, which stays put and is dimmed. Content on the
-- *same* layer **pushes**: both the outgoing and incoming panes translate together,
-- revealed through a mask, with nothing dimmed.
--
-- Tab pages are peers -- the same layer, one replacing another -- so this is a push.
-- Both snapshots move together and the overlay acts as the mask. Dimming, or moving
-- only the new page, would imply a depth relationship that does not exist.
--
-- ### Why the pages do not travel a full page width
--
-- The literal reading of a push is a rigid pair exactly one page width apart, so
-- the outgoing page exits precisely as the incoming one arrives. That is what this
-- module did first, and on a small window it looks right.
--
-- It does not survive a large one. Carbon's productive band tops out at 240 ms, and
-- a maximised page on a 4K display is close to 3800 px wide -- so the literal push
-- works out at roughly 16,000 px/s. Past a few thousand px/s the eye stops tracking
-- the movement and sees only a smear, which destroys the one thing the transition
-- exists to communicate: *where the content went*. Scaling the duration up until it
-- is trackable, per Carbon's dynamic-duration guidance, lands somewhere north of
-- 600 ms for the app's single most repeated navigation. Neither end of that trade
-- is acceptable.
--
-- So the pages travel a **fraction** of the width (`travel`, 32%) capped in
-- absolute pixels (`max_travel`, 360), and the incoming page cross-fades in over
-- the outgoing one. The spatial story is unchanged -- content still enters from the
-- side the new tab sits on -- but it is told at a speed the eye can follow.
--
-- The pixel cap, not the fraction, is what makes this feel the same everywhere.
-- Perceived speed is absolute distance over time, so a fraction alone either whips
-- on a large display or -- as an earlier 14% did -- becomes so short that the slide
-- is barely present and the whole transition reads as a plain dissolve.
--
-- All of these are fields of the `tab_transition` motion role, so a theme can
-- restore the literal full-width push with `{ travel = 1, fade = false }`, which
-- reproduces the rigid pair exactly (see `_play`).
--
-- ### Why snapshots
--
-- The real widgets cannot be in two places at once, and IUP offers no way to draw
-- a page at an offset. So the transition is a picture: capture the outgoing page,
-- let IUP perform the real switch instantly behind the overlay, capture the
-- incoming page, then animate the two bitmaps. When the animation ends the overlay
-- hides and the live widgets -- which have been correctly switched the whole time --
-- are revealed exactly where the incoming snapshot came to rest.
--
-- A consequence worth knowing: the pages are *pictures* during the transition, so
-- anything that repaints mid-flight (a spinner, a progress bar) is frozen for its
-- duration. At 150-240 ms that is imperceptible, and it is the reason the duration
-- is clamped rather than scaled freely with width.
--
-- ### Interruption
--
-- A user clicking quickly through tabs must not queue up transitions. A switch
-- arriving mid-flight finishes the running one immediately (landing it at its
-- destination) and starts fresh, so the UI always tracks the last thing asked of
-- it rather than replaying a backlog.
--
-- @classmod core.ui.TabTransition

local class = require("middleclass")

local ThemePalette = require("core.classes.Theme")

local TabTransition = class("TabTransition")

-- Every animation this module schedules carries this tag, so a caller that needs
-- the UI settled (a theme switch, a tab-tree rearrangement) can collapse the
-- transition without knowing anything about it.
local TAG = "tab-transition"

-- The motion role this module animates under. Its duration, curve, style, travel
-- fraction and fade flag all come from `core.lib.MotionTokens.ROLES`, as
-- overridden by the active theme.
local ROLE = "tab_transition"

-- Floor on travel distance, in pixels. A narrow pane scaled by `travel` can
-- produce a slide of a few pixels, which reads as a glitch rather than a
-- transition -- below roughly this much movement the fade is doing all the work
-- and the translation only adds jitter.
local MIN_TRAVEL = 24

-- How far the outgoing page travels, as a fraction of the incoming page's travel.
--
-- Moving it *less* than the incoming page is what makes the new content read as
-- leading: two layers moving at different rates is the standard depth cue, and
-- here it puts the emphasis on the arrival rather than the departure.
--
-- It also closes the only hole in the composition. The outgoing page is the opaque
-- base layer, so wherever it has vacated shows through to the incoming page, which
-- is still partly transparent early on. Damping its travel keeps that strip narrow
-- at the moment the incoming page is most transparent.
--
-- Ignored when the fade is off, where the rigid pair covers the frame by
-- construction and any damping would open a real gap.
local OUTGOING_LEAD = 0.5

-- Fraction of the animation over which the incoming page reaches full opacity.
--
-- The fade finishes slightly early so the page is not still visibly translucent as
-- it settles -- which looks like the transition failed to finish rather than like a
-- fade. It should not finish MUCH early either: a fade that completes at 60% turns
-- the last 40% of the slide into a solid page sliding into place with no remaining
-- cross-fade, which is what made the whole transition read as a quick dissolve.
local FADE_SPAN = 0.85

-- =======================================================================
-- CLIPPED COMPOSITING
-- =======================================================================
--
-- Both pages slide horizontally across a fixed canvas, so on every frame each
-- one is partly off-canvas. These helpers compute the visible intersection once
-- and draw only that, rather than handing GDI a full-page rectangle and relying
-- on it to clip. GDI does clip correctly -- the cost is what differs, and for
-- `AlphaBlend` (a software path) the cost is what makes the transition stutter.
--
-- Vertical extent is never clipped: the pages only ever move along X.

-- Visible span of a page whose left edge sits at `x` on a canvas `W` wide.
-- Returns destination X, source X, and width -- or nil when fully off-canvas.
local function visible_span(x, W)
	x = math.floor(x + 0.5)

	local dst_x = x
	local src_x = 0
	if x < 0 then
		-- Hanging off the left: skip the hidden columns in the SOURCE and start
		-- drawing at the canvas edge.
		src_x = -x
		dst_x = 0
	end

	local width = W - src_x
	if dst_x + width > W then width = W - dst_x end
	if width <= 0 then return nil end

	return dst_x, src_x, width
end

local function blit_clipped(o, snap, x, W, H)
	local dst_x, src_x, width = visible_span(x, W)
	if not dst_x then return end
	o:blit(snap, dst_x, 0, width, H, src_x, 0)
end

local function blend_clipped(o, snap, x, W, H, alpha)
	local dst_x, src_x, width = visible_span(x, W)
	if not dst_x then return end
	o:blendBlit(snap, dst_x, 0, alpha, width, H, src_x, 0)
end

-- Paint `color` over the parts of the canvas neither page covers.
--
-- With the shipped geometry this paints NOTHING, and that is the point.
--
-- `travel` is clamped to at most the page width, and the two pages are opaque
-- rectangles of exactly that width moving in opposite directions -- so their
-- union always spans the canvas and there is no backdrop to draw. The composer
-- it replaced filled the entire canvas every frame regardless, which was a
-- full-page `FillRect` whose every pixel was then painted over.
--
-- It is kept as a guard rather than deleted. The invariant it depends on lives
-- in the travel clamping thirty lines away, and if that ever changes -- a theme
-- override, a new `max_travel` interaction, a pane narrower than `MIN_TRAVEL` --
-- the failure mode is uncovered columns showing whatever the back buffer last
-- held, i.e. a ghost of the previous transition. Three comparisons per frame is
-- a fair price for that not being possible.
--
-- The middle band covers the case where the pages do not meet at all; the outer
-- two cover a page hanging off either edge.
local function fill_uncovered(o, from_x, to_x, W, H, color)
	local a = math.min(math.floor(from_x + 0.5), math.floor(to_x + 0.5))
	local b = math.max(math.floor(from_x + 0.5), math.floor(to_x + 0.5))

	local function band(x0, x1)
		if x0 < 0 then x0 = 0 end
		if x1 > W then x1 = W end
		if x1 > x0 then o:fill(x0, 0, x1 - x0, H, color) end
	end

	band(0, a)          -- left of both pages
	band(a + W, b)      -- between them, when they do not meet
	band(b + W, W)      -- right of both pages
end

--- Create a tab transition controller.
--
-- `opts` fields:
--
--   * `iup` -- the IUP binding
--   * `director` -- `core.classes.MotionDirector`
--   * `overlay` -- `core.ui.MotionOverlay`
--   * `log` -- optional `fn(msg)` for diagnostics
--
-- @tparam table opts construction options (see above)
function TabTransition:initialize(opts)
	opts = opts or {}
	self._iup      = opts.iup
	self._director = opts.director
	self._overlay  = opts.overlay
	self._log      = opts.log

	self._active    = nil   -- in-flight transition state
	self._armed     = nil   -- outgoing page captured, awaiting the switch
	self._suspended = 0     -- >0 while the widget tree is being rearranged
end

--- Discard a pending capture without animating.
--
-- Called when the gesture that armed it turns out not to be a navigation: the
-- user started dragging rather than clicking. The page change that follows a drag
-- is a consequence of the tree being rearranged, and animating it would slide the
-- pane sideways while the tab is still under the cursor.
--
-- @usage transition:disarm()
function TabTransition:disarm()
	self:_disarm()
end

function TabTransition:_note(msg)
	if self._log then pcall(self._log, "[TabTransition] " .. tostring(msg)) end
end

--- Record why a switch did not animate, once per distinct reason.
--
-- Every gate below is a legitimate "not this time" -- a press that became a drag,
-- a tree under surgery -- so any of them firing is normal. What is NOT normal is
-- the SAME one firing on every switch forever, which is what "tab switching has no
-- motion" actually looks like from the inside. Logging each reason once turns that
-- from an invisible condition into one line in the app log, and `report()` puts the
-- current state in the diagnostics dialog.
--
-- Deduplicated because these sit on the mouse-down path: logging every time would
-- write a line per click for the life of the process.
-- @local
function TabTransition:_declined(reason)
	self._last_decline = reason
	self._seen = self._seen or {}
	if self._seen[reason] then return end
	self._seen[reason] = true
	self:_note("no transition: " .. reason)
end

--- A snapshot of everything that gates the transition, for the diagnostics dialog.
--
-- Answers "why is nothing moving?" without a debugger: exactly one of these lines
-- is the reason.
--
-- @treturn table `{ label = value }` pairs, all strings.
-- @usage for k, v in pairs(transition:report()) do print(k, v) end
function TabTransition:report()
	local Overlay = require("core.ui.MotionOverlay")
	local d, o = self._director, self._overlay
	local function yn(v) return v and "yes" or "NO" end
	local s = self._stats or {}
	local function n(k) return tostring(s[k] or 0) end

	-- The counters are the useful part once the gates all read "yes". They walk
	-- the path a switch takes, so the first one still at zero is where it stops:
	--
	--   armed 0      -> FLAT_BUTTON_CB is not reaching TabOrder; no click ever
	--                   captures the outgoing page
	--   committed 0  -> TABCHANGE_CB is not reaching TabOrder, or something
	--                   overwrote the chained callback
	--   played 0     -> a capture came back nil or zero-sized
	--   shown 0      -> the overlay window refused to appear
	--   frames 0     -> the director never ticked it
	--   frames > 0   -> it IS running and drawing, and the problem is that the
	--                   overlay is not visible: Z-order, alpha, or a blank capture
	--
	-- "Frame delivery" is the line to read when the transition plays but looks
	-- choppy. The driver is time-based, so a slow frame is DROPPED rather than
	-- stretched -- a mean well above the 16 ms target means most of the animation
	-- was never drawn, and the fix is to make each frame cheaper, not to retune
	-- the duration or the easing.
	local frames = d and d.frameStats and d:frameStats()
	local delivery = "not measured"
	if frames then
		delivery = string.format("%d frames, mean %.1f ms (%.0f fps), worst %.1f ms, target %d ms",
			frames.frames, frames.mean_ms, frames.fps, frames.worst_ms, frames.target_ms)
	end

	return {
		["Motion enabled"]        = yn(d and d:enabled()),
		["Overlay supported"]     = yn(Overlay.supported()),
		["Overlay available"]     = yn(o and o:available()),
		["Alpha compositing"]     = yn(Overlay.blendSupported()),
		["Transitions suspended"] = yn(self:suspended()),
		["Last decline"]          = tostring(self._last_decline or "none"),
		["Count 1 armed"]         = n("armed"),
		["Count 2 committed"]     = n("committed"),
		["Count 3 played"]        = n("played"),
		["Count 4 shown"]         = n("shown"),
		["Count 5 frames"]        = n("frames"),
		["Frame delivery"]        = delivery,
		["Last geometry"]         = tostring(self._last_geometry or "none"),
	}
end

-- @local
function TabTransition:_count(key)
	self._stats = self._stats or {}
	self._stats[key] = (self._stats[key] or 0) + 1
end

--- Is a transition currently playing?
-- @treturn boolean
function TabTransition:busy()
	return self._active ~= nil
end

-- Release snapshots and hide the overlay. Safe to call twice.
function TabTransition:_teardown()
	local st = self._active
	self._active = nil
	if not st then return end

	if self._overlay then self._overlay:hide() end
	if st.from_snap then st.from_snap:release() end
	if st.to_snap then st.to_snap:release() end
end

--- Finish any in-flight transition immediately.
--
-- Call this before anything that rearranges or repaints the widget tree -- a theme
-- apply, a group operation, a tab being destroyed. The snapshots would otherwise
-- keep showing stale pixels over a tree that no longer matches them, and the
-- overlay would cover widgets that have since moved.
--
-- @usage transition:settle()
function TabTransition:settle()
	if self._director then
		self._director:finish({ tag = TAG })
	end
	self:_teardown()
	self:_disarm()
end

-- The widget currently displayed by `strip`, plus its position.
function TabTransition:_currentPage(strip)
	local iup = self._iup
	local ok, pos = pcall(iup.GetAttribute, strip, "VALUEPOS")
	pos = ok and tonumber(pos) or nil
	if not pos then return nil end
	local ok2, child = pcall(iup.GetChild, strip, pos)
	if not ok2 then return nil end
	return child, pos
end

--- Suspend transitions while the widget tree is being rearranged.
--
-- ### Why this is necessary
--
-- `core.classes.TabGroups` calls `reveal()` at the end of a move, which sets
-- `VALUEPOS` on each strip in the chain -- and IUP fires `TABCHANGE_CB`
-- **synchronously** from inside that call. So a page change is reported in the
-- middle of `moveInto`, while pages are detached, re-parented and not yet
-- re-mapped, and before the tree has been refreshed.
--
-- Animating there means capturing and compositing widgets that are mid-surgery,
-- and holding snapshots of pages that the rest of the operation is still moving or
-- destroying. That is a use-after-free waiting to happen, and it presented exactly
-- as one: an intermittent hard crash when dragging tabs around.
--
-- A tab change during surgery is also not something the user should see animated.
-- It is bookkeeping -- the tree settling into its new shape -- not navigation.
--
-- Counted rather than boolean so nested operations (a merge is two moves inside a
-- group creation) resume only once the outermost one is finished.
--
-- @usage
--   transition:suspend()
--   -- ... rearrange the tree ...
--   transition:resume()
function TabTransition:suspend()
	self._suspended = (self._suspended or 0) + 1
	-- Anything already running was scheduled against the tree as it looked before
	-- this operation, so it must not outlive it.
	self:settle()
end

--- Resume transitions after a `suspend`. Safe to over-call.
function TabTransition:resume()
	local n = (self._suspended or 0) - 1
	if n < 0 then n = 0 end
	self._suspended = n
end

--- Are transitions currently suspended for tree surgery?
-- @treturn boolean
function TabTransition:suspended()
	return (self._suspended or 0) > 0
end

--- Run `fn` with transitions suspended, resuming even if it throws.
-- @tparam function fn work to run
-- @treturn boolean ok
-- @treturn any error, when `fn` threw
-- @usage transition:around(function() groups:moveInto(tab, strip) end)
function TabTransition:around(fn)
	self:suspend()
	local ok, err = pcall(fn)
	self:resume()
	return ok, err
end

function TabTransition:_ready()
	if self:suspended() then
		self:_declined("tree surgery in progress")
		return false
	end
	local d, o = self._director, self._overlay
	if d == nil then self:_declined("no motion director"); return false end
	if o == nil then self:_declined("no overlay"); return false end
	if not d:enabled() then
		self:_declined("motion is switched off (setting, or OS reduce-motion)")
		return false
	end
	if not o:available() then
		-- The single most likely answer: the overlay needs FFI, the iupraw bridge, a window handle and a layered
		-- window style, and latches itself off permanently if any of that fails.
		self:_declined("overlay unavailable (FFI, HWND or layered window)")
		return false
	end
	return true
end

--- Capture the outgoing page, ahead of a switch this module does not control.
--
-- IUP reports a tab change only *after* it has happened (`TABCHANGE_CB`), by which
-- point the outgoing page is already hidden and capturing it yields blank pixels.
-- So a native click has to be caught on the way in: `core.classes.TabOrder` hooks
-- `FLAT_BUTTON_CB`, which runs *before* the control performs the switch, and calls
-- this. `commit` then completes the transition once the switch has happened.
--
-- Cheap and side-effect-free when motion is off, so it is safe to call on every
-- mouse-down on a tab strip.
--
-- @tparam ihandle strip the `iup.flattabs` about to change page
-- @usage transition:arm(strip)   -- from FLAT_BUTTON_CB, before the switch
function TabTransition:arm(strip)
	if not strip or not self:_ready() then return end

	-- A click arriving mid-transition supersedes it rather than queueing.
	if self._active then self:settle() end
	self:_disarm()

	local page, pos = self:_currentPage(strip)
	if not page then
		self:_declined("strip reported no current page")
		return
	end

	local snap, why = self._overlay:capture(page)
	if not snap then
		self:_declined("outgoing capture failed: " .. tostring(why))
		return
	end

	self:_count("armed")
	self._armed = { strip = strip, pos = pos, snap = snap }
end

--- Animate the switch that has just happened on `strip`.
--
-- Pairs with `arm`. Does nothing unless a matching capture is waiting, so an
-- unarmed or superseded change simply falls through to today's instant switch.
--
-- ### Why the animation starts on a timer rather than here
--
-- `TABCHANGE_CB` is delivered SYNCHRONOUSLY from inside the control's button-down
-- handling, while the strip holds the Win32 mouse capture and IUP is still
-- dispatching the event. Starting the transition inline meant creating and showing
-- a layered window, and beginning a 60 Hz animation, from inside that handler --
-- and then the user's drag continued on top of it.
--
-- That is the same hazard `core.classes.TabOrder:_scheduleDrop` already documents
-- for widget-tree surgery, and it produced the same result: an intermittent hard
-- crash while dragging tabs. One frame of delay moves all of it onto the main loop,
-- after the event has fully unwound -- and if the press turns out to be the start of
-- a drag, `disarm` cancels it before it ever runs.
--
-- ### Why VALUEPOS is not read here
--
-- `iFlatTabsCallTabChange` in iup_flattabs.c fires `TABCHANGE_CB` *before*
-- `iFlatTabsSetCurrentTab` updates `VALUE`/`VALUEPOS`. Reading VALUEPOS here
-- would therefore return the outgoing position (the one `arm` already captured),
-- making `to_pos == armed.pos` on every click and silently dropping every
-- transition. `_startPending` runs 1 ms later, after the button handler has
-- returned and `iFlatTabsSetCurrentTab` has run, so it sees the correct new
-- position and does the final sanity-check there instead.
--
-- @tparam ihandle strip the `iup.flattabs` whose page changed
-- @treturn boolean true when a transition was scheduled
-- @usage transition:commit(strip)   -- from TABCHANGE_CB, after the switch
function TabTransition:commit(strip)
	local armed = self._armed
	self._armed = nil
	if not armed then
		-- The page changed without a press having armed it. Normal for a
		-- programmatic switch; permanent means FLAT_BUTTON_CB is not reaching
		-- TabOrder, so no click ever arms a capture.
		self:_declined("page changed with no armed capture")
		return false
	end

	if armed.strip ~= strip or not self:_ready() then
		armed.snap:release()
		return false
	end

	-- Do NOT read VALUEPOS here — see the docstring note above.
	-- _startPending (1 ms later) verifies that a real navigation happened.
	self:_count("committed")
	self._pending = { strip = strip, snap = armed.snap, from_pos = armed.pos }
	self:_scheduleStart()
	return true
end

-- Start the pending transition on the next main-loop tick.
function TabTransition:_scheduleStart()
	local iup = self._iup
	if not iup then return end

	if not self._start_timer then
		local this = self
		local timer = iup.timer({ TIME = 1, RUN = "NO" })
		function timer:action_cb()
			pcall(iup.SetAttribute, timer, "RUN", "NO")
			local job = this._pending
			this._pending = nil
			if job then this:_startPending(job) end
			return iup.DEFAULT
		end
		self._start_timer = timer
	end

	pcall(iup.SetAttribute, self._start_timer, "RUN", "NO")
	pcall(iup.SetAttribute, self._start_timer, "RUN", "YES")
end

function TabTransition:_startPending(job)
	-- Conditions can have changed in the intervening frame: the user may have
	-- started dragging, the tree may be under surgery, or motion may have been
	-- switched off. Re-check everything rather than trusting the press.
	if not self:_ready() then
		job.snap:release()
		return
	end
	local to_page, to_pos = self:_currentPage(job.strip)
	if not to_page or to_pos == job.from_pos then
		job.snap:release()
		return
	end
	self:_play(job.strip, job.snap, to_page, job.from_pos, to_pos)
end

-- Drop a capture that was armed, or scheduled but not yet started.
function TabTransition:_disarm()
	local a = self._armed
	self._armed = nil
	if a and a.snap then a.snap:release() end

	local p = self._pending
	self._pending = nil
	if p then
		if self._start_timer and self._iup then
			pcall(self._iup.SetAttribute, self._start_timer, "RUN", "NO")
		end
		if p.snap then p.snap:release() end
	end
end

--- Run a sliding transition around a switch this module performs itself.
--
-- `switch` is invoked between the two captures and **must** perform the actual tab
-- change. It is always called exactly once, whether or not the animation runs, so
-- this is safe to wrap around any programmatic switch -- if motion is off, the
-- overlay is unavailable, or a capture fails, the switch still happens and only
-- the animation is skipped.
--
-- @tparam ihandle strip the `iup.flattabs` whose page is changing
-- @tparam number to_pos destination tab position (0-based)
-- @tparam function switch performs the real switch; called exactly once
-- @treturn boolean true when a transition was animated
-- @usage
--   transition:run(tabs, 3, function()
--     iup.SetAttribute(tabs, "VALUEPOS", "3")
--   end)
function TabTransition:run(strip, to_pos, switch)
	local function do_switch()
		if switch then pcall(switch) end
	end

	if not strip or not self:_ready() then
		do_switch()
		return false
	end

	if self._active then self:settle() end
	self:_disarm()

	local from_page, from_pos = self:_currentPage(strip)
	if not from_page or from_pos == to_pos then
		do_switch()
		return false
	end

	local from_snap = self._overlay:capture(from_page)
	if not from_snap then
		do_switch()
		return false
	end

	do_switch()

	local to_page, actual_pos = self:_currentPage(strip)
	if not to_page then
		from_snap:release()
		return false
	end

	return self:_play(strip, from_snap, to_page, from_pos, actual_pos or to_pos)
end

-- Capture the incoming page and animate the pair.
function TabTransition:_play(strip, from_snap, to_page, from_pos, to_pos)
	local overlay = self._overlay

	local to_snap, why = overlay:capture(to_page)
	if not to_snap then
		self:_declined("incoming capture failed: " .. tostring(why))
		from_snap:release()
		return false
	end

	local w, h = from_snap.w, from_snap.h
	if w <= 0 or h <= 0 then
		self:_declined("captured page has zero size")
		from_snap:release()
		to_snap:release()
		return false
	end

	-- Direction: moving rightward along the strip pushes content leftward, the way
	-- a filmstrip advances. Nested group strips report their own local positions,
	-- which is correct -- the motion should match the strip the user clicked in.
	local forward = (tonumber(to_pos) or 0) > (tonumber(from_pos) or 0)
	local dir = forward and -1 or 1

	local motion = self._director:role(ROLE)

	-- `travel` is a fraction of the page width; 1 restores the literal full-width
	-- push. Clamped so a theme cannot ask for a slide longer than the page (which
	-- would tear the pair apart) or shorter than perception (see MIN_TRAVEL).
	local frac = tonumber(motion.travel) or 1
	if frac > 1 then frac = 1 end
	local travel = w * frac

	-- The pixel cap is what holds the apparent SPEED constant across window sizes:
	-- a fraction alone crosses four times the distance on a 4K page as on a laptop
	-- in the same 240 ms. Skipped at full travel, where the rigid pair has to cover
	-- exactly one page width or it tears open.
	local cap = tonumber(motion.max_travel)
	if cap and frac < 1 and travel > cap then travel = cap end

	if travel < MIN_TRAVEL then travel = math.min(MIN_TRAVEL, w) end

	-- The fade is what lets a partial slide complete the handover, so the two are
	-- not independent: without it the outgoing page has to clear the frame itself,
	-- which is only true at full travel.
	local fade = (motion.fade ~= false) and (frac < 1)
	local lead = fade and OUTGOING_LEAD or 1

	-- Background behind the composition. Only ever visible in the few pixels the
	-- damped outgoing page has vacated before the incoming page is fully opaque --
	-- but leaving those pixels as whatever the back buffer last held is how a
	-- transition picks up a ghost of the previous one.
	local backdrop = ThemePalette.color("bg", "255 255 255")

	local st = {
		from_snap = from_snap,
		to_snap   = to_snap,
		progress  = 0,
		w         = w,
		h         = h,
		-- Logical page offsets for the frame last composed, BEFORE clipping.
		--
		-- The draw calls no longer reveal these: a clipped draw reports where the
		-- visible part landed, and a page entirely off-canvas is not drawn at all.
		-- The geometric contract -- the rigid pair sitting exactly one page width
		-- apart, the incoming page settling at zero -- is about these numbers, so
		-- they are recorded rather than inferred from what was painted.
		from_x    = 0,
		to_x      = 0,
	}
	self._active = st

	self:_count("played")
	self._last_geometry = string.format("page %dx%d, travel %d, fade %s",
		w, h, math.floor(travel), tostring(fade))

	local shown = overlay:show(to_page, function(o)
		local t = st.progress
		local W, H = st.w, st.h

		-- Every draw below is clipped to the part of the page actually on the
		-- canvas.
		--
		-- The naive composer drew all three layers at full page size. That is
		-- correct but wasteful: the pages are mid-slide, so a band of each one is
		-- off-canvas on every frame except the last, and `travel` is capped at
		-- `max_travel` (360 px) -- so on a maximised window the great majority of
		-- those pixels were being blended and then discarded.
		--
		-- It matters more than a normal micro-optimisation because one of the
		-- three is `AlphaBlend`, which GDI implements in software. At 4K a
		-- full-page blend alone can exceed the whole 16 ms frame budget, and when
		-- a frame overruns the driver does not stretch the animation -- it drops
		-- the frame (see core.classes.MotionDirector, "Time-based, not
		-- frame-based"). Dropped frames are exactly the reported choppiness, and
		-- they are also why raising the motion speed did not help: a shorter
		-- duration does not buy more frames, it just spreads the same few over
		-- less time.
		--
		-- Output is unchanged: clipping only removes pixels that fell outside the
		-- canvas.

		-- Outgoing page: the opaque base, drifting in the direction of travel.
		local from_x = dir * travel * lead * t

		-- Incoming page: arrives from the side the new tab sits on, and settles at
		-- zero. At `frac == 1` with the fade off, this sits exactly one page width
		-- from the outgoing page at every instant -- the rigid Carbon pair.
		local to_x = -dir * travel * (1 - t)

		st.from_x, st.to_x = from_x, to_x

		blit_clipped(o, st.from_snap, from_x, W, H)

		-- Backdrop, drawn only where neither page covers the canvas.
		--
		-- Those pixels are only ever the narrow strip the damped outgoing page has
		-- vacated before the incoming page is fully opaque -- but leaving them as
		-- whatever the back buffer last held is how a transition picks up a ghost
		-- of the previous one, so they do have to be painted. Just not all of
		-- them: a full-page fill to cover a strip is the same waste as above.
		fill_uncovered(o, from_x, to_x, W, H, backdrop)

		if fade then
			local alpha = t / FADE_SPAN
			if alpha > 1 then alpha = 1 end
			blend_clipped(o, st.to_snap, to_x, W, H, 255 * alpha)
		else
			blit_clipped(o, st.to_snap, to_x, W, H)
		end
	end)
	if not shown then
		self:_declined("overlay refused to show")
		self:_teardown()
		return false
	end

	self:_count("shown")

	local this = self
	self._director:animate({
		-- Duration, curve and style all come from the role, so a theme retunes the
		-- transition without this module knowing. `distance` is deliberately NOT
		-- passed: the role carries a fixed duration precisely because deriving it
		-- from the page width is what produced the unwatchable speed on large
		-- displays.
		role     = ROLE,
		tag      = TAG,
		target   = strip,
		from     = 0,
		to       = 1,
		on_frame = function(v)
			this:_count("frames")
			st.progress = v
			overlay:redraw()
		end,
		on_done  = function()
			this:_teardown()
		end,
	})

	return true
end

return TabTransition

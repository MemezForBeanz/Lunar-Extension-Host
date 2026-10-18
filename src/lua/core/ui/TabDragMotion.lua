--- Drag feedback and folder-creation motion for the tab strips.
--
-- `core.classes.TabOrder` already decides what a drag *means* -- reorder, combine
-- into a new group, or move into an existing one. It just never showed the user
-- which of the three was about to happen: the only feedback was a cursor shape,
-- and the outcomes look identical until the mouse is released. Dropping a tab a few
-- pixels off silently created a group instead of reordering.
--
-- This module renders that decision. It owns no drop logic and changes none; it
-- reads what `TabOrder` resolved and draws it.
--
-- ### Two outcomes, two deliberately different visuals
--
-- Carbon calls this *intentional inconsistency*: when one gesture can produce
-- meaningfully different results, the motion should not be uniform. So the two
-- outcomes are drawn as differently as possible.
--
--   * **Reorder** -- a thin vertical caret between two tabs, which *slides* from one
--     gap to the next (standard/productive). It reads as "the tab lands here".
--   * **Combine** -- a filled highlight that *scales up* over the target tab
--     (entrance/expressive). It reads as "these two become one thing".
--
-- Nobody has to learn this. A line between things means insertion and a box around
-- a thing means containment, and the difference is legible before the mouse button
-- comes up -- which is the entire point.
--
-- ### Spring-open gets a countdown
--
-- Hovering a group tab opens it after 500 ms so a tab can be dropped at a chosen
-- position inside. Unannounced, that delay reads as the app being stuck. A progress
-- bar drawn under the hovered group tab turns an unexplained wait into a visible
-- one, and shows that releasing early is an option.
--
-- ### Folder creation is the one expressive moment
--
-- Combining two tabs into a group is a structural change to the user's workspace,
-- and it is the moment users most often report as surprising. It gets Carbon's
-- expressive treatment (400 ms, `slow_01`): the new group tab's highlight expands
-- from the width of the two source tabs down to its own. That is the "these two are
-- now one" story told in one gesture, and it is rare enough not to wear out.
--
-- Everything else in the app is productive motion; this is deliberately the
-- exception.
--
-- @classmod core.ui.TabDragMotion

local class = require("middleclass")

local Compositor = require("core.lib.Compositor")
local ThemeReactor = require("core.ui.ThemeReactor")

local TabDragMotion = class("TabDragMotion")

local TAG = "tab-drag"

-- The compositor group this module owns. Its own id, so it shares the Z_TAB band
-- with `core.ui.TabTransition` without either clobbering the other's sprites.
local GROUP = "tab-drag"

-- Insertion caret width. Two pixels reads as a deliberate UI element at every DPI;
-- one pixel disappears on scaled displays.
local CARET_W = 2

-- Height of the spring-open countdown bar, drawn at the bottom of the tab band.
local SPRING_BAR_H = 3

-- "R G B" (the palette's form) as 0xRRGGBB.
local function rgb(value)
	local r, g, b = tostring(value):match("(%d+)%s+(%d+)%s+(%d+)")
	if not r then return 0 end
	return (tonumber(r) % 256) * 65536 + (tonumber(g) % 256) * 256 + (tonumber(b) % 256)
end

local function round(v)
	return math.floor(v + 0.5)
end

--- Create the drag-motion renderer.
--
-- `opts` fields:
--
--   * `iup` -- the IUP binding
--   * `director` -- `core.classes.MotionDirector`
--   * `dialog` -- the dialog whose compositor draws the feedback
--   * `compositor` -- optional `fn() -> manager|nil, why`; defaults to
--     `Compositor.forDialog(iup, dialog)` (tests pass a fake)
--   * `spring_ms` -- spring-open delay to visualise, in milliseconds
--   * `log` -- optional `fn(msg)` for diagnostics
--
-- Without a compositor every feedback call does nothing: the drag still works, the
-- user just gets the cursor shape and no caret.
--
-- @tparam table opts construction options (see above)
function TabDragMotion:initialize(opts)
	opts = opts or {}
	self._iup       = opts.iup
	self._director  = opts.director
	self._log       = opts.log
	self._spring_ms = tonumber(opts.spring_ms) or 500
	self._get_comp  = opts.compositor or function()
		return Compositor.forDialog(opts.iup, opts.dialog)
	end

	self._strip = nil    -- strip the feedback is currently tracking
	self._state = nil    -- current visual state
end

-- The dialog's compositor, made on first use; nil (logged once) when there is none.
function TabDragMotion:_comp()
	if self._compositor then return self._compositor end
	if self._unavailable then return nil end
	local ok, comp, why = pcall(self._get_comp)
	if not ok or not comp then
		self._unavailable = true
		if self._log then
			pcall(self._log, "[TabDragMotion] no compositor (" .. tostring(ok and why or comp) .. "); no drag feedback")
		end
		return nil
	end
	self._compositor = comp
	local me = self
	local function relayout() if me._state then me:_render() end end
	comp:on("resize", relayout)
	comp:on("dpi", relayout)
	return comp
end

function TabDragMotion:_ready()
	return self._director ~= nil and self._director:enabled() and self:_comp() ~= nil
end

-- Theme colors, read live so a theme switch mid-drag is reflected immediately.
function TabDragMotion:_colors()
	local pal = ThemeReactor.palette() or {}
	local accent = ThemeReactor.pal_get(pal, "accent", "15 98 254")
	return {
		accent = rgb(accent),
		-- The combine highlight is the same accent as the caret so the two read as
		-- one language, distinguished by shape rather than by hue.
		fill   = rgb(accent),
		border = rgb(ThemeReactor.pal_get(pal, "borderStrong", accent)),
	}
end

-- =======================================================================
-- COMPOSITOR PLUMBING
-- =======================================================================

-- Track `strip`; false when there is nowhere to draw.
function TabDragMotion:_attach(strip)
	if not self:_ready() then return false end
	if not self._compositor:rect(strip) then return false end
	self._strip = strip
	return true
end

local function fill(sprites, x, y, w, h, color)
	if w <= 0 or h <= 0 then return end
	sprites[#sprites + 1] = { kind = "fill", x = x, y = y,
		w = w, h = h, color = color, alpha = 1 }
end

local function outline(sprites, x, y, w, h, color, thickness)
	if w <= 0 or h <= 0 then return end
	sprites[#sprites + 1] = { kind = "stroke", x = x, y = y,
		w = w, h = h, thickness = thickness, color = color, alpha = 1 }
end

-- Sprites for the current state, in strip-local coordinates offset by (ox, oy).
function TabDragMotion:_sprites(ox, oy, scale)
	local sprites = {}
	local st = self._state
	if not st then return sprites end

	local c = self:_colors()

	if st.kind == "caret" then
		fill(sprites, ox + st.x - CARET_W / 2, oy + st.y, CARET_W, st.h, c.accent)
		-- Small end caps make the caret read as an insertion marker rather than a
		-- stray divider line.
		fill(sprites, ox + st.x - CARET_W * 1.5, oy + st.y, CARET_W * 3, CARET_W, c.accent)
		fill(sprites, ox + st.x - CARET_W * 1.5, oy + st.y + st.h - CARET_W, CARET_W * 3, CARET_W, c.accent)

	elseif st.kind == "combine" then
		-- Scales about the target's centre, so the highlight grows into place
		-- rather than unrolling from one edge.
		local k = st.scale or 1
		local w = st.w * k
		local h = st.h * k
		local x = st.x + (st.w - w) / 2
		local y = st.y + (st.h - h) / 2
		outline(sprites, ox + x, oy + y, w, h, c.fill, 2)

	elseif st.kind == "merge" then
		-- The folder-creation flourish: one rectangle contracting from the span of
		-- both source tabs to the new group tab's own bounds.
		outline(sprites, ox + st.x, oy + st.y, st.w, st.h, c.fill, 2)
	end

	if st.spring then
		local s = st.spring
		fill(sprites, ox + s.x, oy + s.y + s.h - SPRING_BAR_H, s.w * (s.progress or 0), SPRING_BAR_H, c.accent)
	end
	-- The compositor rectangle is in device pixels; TabOrder's strip offsets
	-- remain IUP logical pixels until they are rendered here.
	for _, sprite in ipairs(sprites) do
		sprite.x = round(ox + (sprite.x - ox) * scale)
		sprite.y = round(oy + (sprite.y - oy) * scale)
		sprite.w = round(sprite.w * scale)
		sprite.h = round(sprite.h * scale)
		if sprite.thickness then sprite.thickness = round(sprite.thickness * scale) end
	end
	return sprites
end

-- Put the current state in the compositor and ask for a present (one per director
-- tick, shared with any other effect on this dialog).
function TabDragMotion:_render()
	local comp = self._compositor
	if not comp then return end
	local strip = self._strip
	local r = strip and comp:rect(strip)
	if not self._state or not r then
		comp:remove(GROUP)
	else
		local geometry = comp:geometry()
		comp:set(GROUP, { z = Compositor.Z_TAB,
			sprites = self:_sprites(r.x, r.y, geometry.unit or 1), regions = {} })
	end
	comp:schedule(self._director)
end

function TabDragMotion:_setState(st)
	self._state = st
	self:_render()
end

-- =======================================================================
-- PUBLIC FEEDBACK API (called by core.classes.TabOrder)
-- =======================================================================

--- Show the insertion caret at `x` within `strip`'s tab band.
--
-- Repeated calls slide the existing caret to the new position rather than jumping
-- it, which is what makes scrubbing along a strip feel continuous instead of
-- flickering between discrete states.
--
-- @tparam ihandle strip the tab strip being dragged over
-- @tparam number x caret X in strip-local coordinates
-- @tparam number band height of the tab band in pixels
-- @usage motion:showCaret(strip, 120, 28)
function TabDragMotion:showCaret(strip, x, band)
	if not self:_ready() then return end
	if not self:_attach(strip) then return end

	local st = self._state
	if st and st.kind == "caret" then
		-- Already showing: animate from wherever it is now, so an interrupted
		-- slide continues from its current position instead of snapping back.
		local from = st.x
		local this = self
		self._director:animate({
			-- Fixed rather than scaled by travel: the caret is chasing a live
			-- cursor, so a long hop taking proportionally longer would leave it
			-- furthest behind exactly when the user is moving fastest.
			role     = "tab_drag_caret",
			tag      = TAG,
			target   = strip,
			from     = from,
			to       = x,
			on_frame = function(v)
				local cur = this._state
				if cur and cur.kind == "caret" then
					cur.x = v
					this:_render()
				end
			end,
		})
		return
	end

	self:_setState({
		kind     = "caret",
		x        = x,
		y        = 0,
		h        = band,
	})
end

--- Show the combine highlight over a target tab.
--
-- Scales up with entrance/expressive easing, so it announces itself as a different
-- kind of outcome than the reorder caret.
--
-- @tparam ihandle strip the tab strip being dragged over
-- @tparam number x target tab left edge, strip-local
-- @tparam number w target tab width
-- @tparam number band height of the tab band in pixels
-- @usage motion:showCombine(strip, 100, 96, 28)
function TabDragMotion:showCombine(strip, x, w, band)
	if not self:_ready() then return end
	if not self:_attach(strip) then return end

	local st = self._state
	if st and st.kind == "combine" and st.x == x and st.w == w then
		return   -- already announcing this exact target
	end

	local next_state = {
		kind     = "combine",
		x        = x,
		y        = 0,
		w        = w,
		h        = band,
		scale    = 0.8,
	}
	self:_setState(next_state)

	local this = self
	self._director:animate({
		role     = "tab_drag_combine",
		tag      = TAG,
		target   = strip,
		from     = 0.8,
		to       = 1.0,
		on_frame = function(v)
			local cur = this._state
			if cur and cur.kind == "combine" then
				cur.scale = v
				this:_render()
			end
		end,
	})
end

--- Show the spring-open countdown under a hovered group tab.
--
-- Runs for the same duration as the spring timer it visualises, so the bar fills
-- exactly as the group opens.
--
-- @tparam ihandle strip the tab strip being dragged over
-- @tparam number x group tab left edge, strip-local
-- @tparam number w group tab width
-- @tparam number band height of the tab band in pixels
-- @usage motion:showSpring(strip, 200, 80, 28)
function TabDragMotion:showSpring(strip, x, w, band)
	if not self:_ready() then return end
	if not self:_attach(strip) then return end

	local st = self._state
	if not st then return end
	if st.spring and st.spring.x == x and st.spring.w == w then return end

	st.spring = { x = x, y = 0, w = w, h = band, progress = 0 }

	local this = self
	self._director:animate({
		-- Linear: this is a progress readout, not a movement. Easing it would
		-- misrepresent how much time is actually left.
		duration = self._spring_ms,
		easing   = { 0, 0, 1, 1 },
		tag      = TAG,
		target   = "spring",
		from     = 0,
		to       = 1,
		on_frame = function(v)
			local cur = this._state
			if cur and cur.spring then
				cur.spring.progress = v
				this:_render()
			end
		end,
	})
end

--- Clear the spring-open countdown without disturbing the rest of the feedback.
-- @usage motion:clearSpring()
function TabDragMotion:clearSpring()
	if self._director then
		self._director:cancel({ tag = TAG, target = "spring" })
	end
	local st = self._state
	if st and st.spring then
		st.spring = nil
		self:_render()
	end
end

--- Play the folder-creation flourish, then invoke `done`.
--
-- The highlight contracts from the combined span of both source tabs to the bounds
-- the new group tab will occupy, which is the "two things became one" story told as
-- a single movement. This is the app's one expressive moment, per Carbon's guidance
-- to reserve expressive motion for significant, occasional events.
--
-- `done` is always called exactly once, even when motion is disabled or the
-- compositor is unavailable, so callers can rely on it to carry out the real work.
--
-- @tparam ihandle strip the strip the group is being created in
-- @tparam table from `{ x, w }` combined span of the two source tabs
-- @tparam table to `{ x, w }` bounds the new group tab will occupy
-- @tparam number band height of the tab band in pixels
-- @tparam function done called once when the flourish completes
-- @usage motion:playMerge(strip, {x=0,w=200}, {x=0,w=110}, 28, apply)
function TabDragMotion:playMerge(strip, from, to, band, done)
	local function finish()
		if done then pcall(done) end
	end

	if not self:_ready() or not from or not to then
		self:clear()
		finish()
		return
	end
	if not self:_attach(strip) then
		self:clear()
		finish()
		return
	end

	local st = self._state
	self:_setState({
		kind = "merge", x = from.x, y = 0, w = from.w, h = band,
		-- Carry the countdown across if one was running, so the visual does not
		-- flicker between the drop and the flourish.
		spring = st and st.spring or nil,
	})

	local this = self
	self._director:animate({
		role     = "tab_group_merge",
		tag      = TAG,
		target   = strip,
		from     = 0,
		to       = 1,
		on_frame = function(v)
			local cur = this._state
			if cur and cur.kind == "merge" then
				cur.x = from.x + (to.x - from.x) * v
				cur.w = from.w + (to.w - from.w) * v
				this:_render()
			end
		end,
		on_done  = function()
			this:clear()
			finish()
		end,
	})
end

--- Remove all drag feedback.
--
-- Called when a drag ends, is cancelled, or leaves every valid target. Cancels the
-- module's animations rather than finishing them: a caret sliding toward a target
-- the user has abandoned should disappear, not complete its journey.
--
-- Nothing is captured, so there is nothing to release: the feedback is a handful
-- of sprites over the live strip, removed here.
--
-- @usage motion:clear()
function TabDragMotion:clear()
	if self._director then
		self._director:cancel({ tag = TAG })
	end
	self._state = nil
	self:_render()
	self._strip = nil
end

return TabDragMotion

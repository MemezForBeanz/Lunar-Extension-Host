--- Drag-and-drop behaviour for the host's tab strips.
--
-- Installed on the main `iup.flattabs` and on every group strip
-- (`core.classes.TabGroups`), so a group's sub-bar drags exactly like the main
-- bar. Handles three gestures:
--
--   * **reorder** — drop a tab on the left or right quarter of another tab
--   * **group together** — drop a tab on the middle of another tab; both become
--     members of a new group, browser-style
--   * **move into a group** — drop a tab on the middle of an existing group tab,
--     or drag it into that group's sub-bar directly
--
-- Hovering a group tab during a drag springs it open after a short delay, so a
-- tab can be dropped at a specific position inside the group rather than only
-- appended to it. Right-click offers the same operations as menu items.
--
-- ### FLAT_BUTTON_CB, not BUTTON_CB
--
-- `IupFlatTabs` is a canvas that registers **its own** `BUTTON_CB` in
-- `iFlatTabsCreateMethod` (`iup_flattabs.c`), and that internal handler is what
-- implements tab switching, the tab-strip scroll arrows, `SHOWCLOSE` and
-- `EXTRABUTTONS`. Assigning `button_cb` from Lua replaces it wholesale: click-to-
-- switch would have to be reimplemented, and the strip's scroll arrows never
-- appear.
--
-- `FLAT_BUTTON_CB` is the callback the control provides for exactly this. The
-- internal handler invokes it first and then proceeds with its own work unless
-- the callback returns `IUP_IGNORE`. Hooking there gets drag-and-drop *and* keeps
-- every native behaviour, including the scroll arrows the strip draws at its ends
-- once the tabs overflow.
--
-- Because the native handler still performs the switch, `TABCHANGE_CB` fires for
-- ordinary clicks again; `on_switch` remains for the programmatic switches this
-- module and `TabGroups` perform, which IUP does not report.
--
-- @classmod core.classes.TabOrder

local class  = require("middleclass")
local handle = require("core.lib.handle")

local TabOrder = class("TabOrder")

-- Fraction of a tab's width at each edge that means "insert beside me" rather
-- than "combine with me". 0.25 gives a comfortable 50% middle target.
local EDGE_ZONE = 0.25

-- Milliseconds a dragged tab must rest over a group tab before that group opens.
local SPRING_MS = 500

-- Pixels the pointer must travel with the button down before a press counts as a
-- drag rather than a click. Below this nothing is rearranged at all — which is
-- what stops an ordinary click on a tab from being read as a drop onto its
-- neighbour and combining the two into a group.
local DRAG_THRESHOLD = 6

--- Create the drag coordinator.
--
-- `opts` fields:
--
--   * `iup` — the IUP binding
--   * `settings` — `core.classes.SettingsManager` (unused directly; the layout is
--     persisted by `TabGroups`, which owns the tree)
--   * `on_switch` — called after a programmatic tab change so the host can
--     re-scope menus and status-bar elements
--   * `prompt` — `fn(title, default) -> string|nil`, used for group naming
--   * `motion` — optional `core.ui.TabDragMotion`, which draws what a drag is
--     about to do. Purely presentational: every drop decision below is made
--     identically with or without it.
--
-- @tparam table opts construction options (see above)
function TabOrder:initialize(opts)
	opts = opts or {}
	self._iup       = opts.iup
	self._settings  = opts.settings
	self._on_switch = opts.on_switch
	self._prompt    = opts.prompt
	self._motion    = opts.motion
	self._groups    = nil

	self._drag   = nil    -- { strip, pos, widget }
	self._spring = nil    -- { strip, pos }
	self._strips = {}     -- strips we have installed on (identity set)
	self._strip_handles = {}   -- same set, keyed by id, holding the handles
	self._hooked = {}     -- strips whose tabchange_cb we have already chained
end

--- Attach the drag-feedback renderer (`core.ui.TabDragMotion`).
-- Optional; without it the gestures behave identically but show no feedback.
-- @tparam TabDragMotion motion the renderer
function TabOrder:setMotion(motion)
	self._motion = motion
end

--- Attach the tab-page transition (`core.ui.TabTransition`).
--
-- Installed on every strip this class manages, so a group's sub-bar animates its
-- page switches exactly like the main bar.
--
-- @tparam TabTransition transition the transition controller
function TabOrder:setTransition(transition)
	self._transition = transition
	-- Strips installed before the transition arrived still need their hook.
	for sid, strip in pairs(self._strip_handles) do
		if not self._hooked[sid] then self:_installTransition(sid, strip) end
	end
end

-- IUP reports a page change only after the fact, and by then the outgoing page is
-- hidden and cannot be captured. So the transition is armed on the way in, from
-- the press callback below (which runs before the control switches), and committed
-- from TABCHANGE_CB once the switch has happened.
--
-- Installed AT MOST ONCE per strip. The hook chains whatever `tabchange_cb` was
-- already there (the host's tab-scoping handler), so installing twice would read
-- back this very closure and chain it to itself -- unbounded recursion on the next
-- page change, which on this stack means a stack overflow and a hard crash rather
-- than a Lua error.
function TabOrder:_installTransition(sid, strip)
	if not (self._transition and strip and sid) then return end
	if self._hooked[sid] then return end
	self._hooked[sid] = true

	local self_ = self
	local iup = self._iup

	local prev = nil
	local ok, existing = pcall(function() return strip.tabchange_cb end)
	if ok and type(existing) == "function" then prev = existing end

	function strip:tabchange_cb(new_tab, old_tab)
		if self_._transition then
			pcall(function() self_._transition:commit(strip) end)
		end
		if prev then pcall(prev, strip, new_tab, old_tab) end
		return iup.DEFAULT
	end
end

--- Attach the `core.classes.TabGroups` instance whose tree this manipulates.
-- @tparam TabGroups groups the group manager
function TabOrder:setGroups(groups)
	self._groups = groups
end

-- =======================================================================
-- GEOMETRY
-- =======================================================================

-- Screen-space rectangle of a widget: SCREENPOSITION is "x,y", RASTERSIZE "WxH".
function TabOrder:_rect(widget)
	local iup = self._iup
	local ok, pos = pcall(iup.GetAttribute, widget, "SCREENPOSITION")
	if not ok or type(pos) ~= "string" then return nil end
	local px, py = pos:match("^(%-?%d+),(%-?%d+)")
	local ok2, size = pcall(iup.GetAttribute, widget, "RASTERSIZE")
	if not ok2 or type(size) ~= "string" then return nil end
	local w, h = size:match("^(%d+)x(%d+)")
	if not (px and py and w and h) then return nil end
	return tonumber(px), tonumber(py), tonumber(w), tonumber(h)
end

-- Height of the tab band at the top of a strip. IupFlatTabs reports CLIENTSIZE
-- with the title area already subtracted, so the difference from RASTERSIZE is
-- the band -- no need to reproduce the control's padding/font arithmetic here.
function TabOrder:_bandHeight(strip)
	local iup = self._iup
	local ok, raster = pcall(iup.GetAttribute, strip, "RASTERSIZE")
	local ok2, client = pcall(iup.GetAttribute, strip, "CLIENTSIZE")
	if not ok or not ok2 or type(raster) ~= "string" or type(client) ~= "string" then
		return nil
	end
	local rh = tonumber(raster:match("^%d+x(%d+)"))
	local ch = tonumber(client:match("^%d+x(%d+)"))
	if not rh or not ch then return nil end
	local band = rh - ch
	if band <= 0 then return nil end
	return band
end

function TabOrder:_posAt(strip, x, y)
	local ok, p = pcall(self._iup.ConvertXYToPos, strip, x, y)
	p = ok and tonumber(p) or nil
	if p and p >= 0 then return p end
	return nil
end

-- Horizontal extent of the tab at position `pos`, found by bisecting
-- ConvertXYToPos outward from a point known to be inside it.
--
-- IupFlatTabs exposes no per-tab rectangle, and the width of a tab depends on its
-- title, font, padding, image and close button. Rather than reimplement
-- iFlatTabsGetTabSize in Lua and have it drift, this asks the control the same
-- question it already answers for hit-testing, ~22 times. Each call is a cheap C
-- hit-test, and it only runs when the hovered tab changes.
function TabOrder:_tabBounds(strip, pos, x, y, width)
	-- Motion fires continuously during a drag but the pointer stays over the same
	-- tab for most of it, so remember the last answer. Cleared on button-down.
	local cache = self._bounds
	if cache and handle.same(self._iup, cache.strip, strip) and cache.pos == pos then
		return cache.left, cache.right
	end

	local lo, hi = 0, x
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		if self:_posAt(strip, mid, y) == pos then hi = mid else lo = mid + 1 end
	end
	local left = lo

	lo, hi = x, width - 1
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if self:_posAt(strip, mid, y) == pos then lo = mid else hi = mid - 1 end
	end
	self._bounds = { strip = strip, pos = pos, left = left, right = lo }
	return left, lo
end

-- =======================================================================
-- DROP RESOLUTION
-- =======================================================================

-- Work out what a release (or hover) at strip-local `x`,`y` on `source` means.
--
-- The source strip holds the mouse capture for the whole drag (IupCanvas calls
-- SetCapture on button down), so coordinates arrive in ITS space even when the
-- pointer is over a different strip. They are converted to screen space once and
-- then tested against every strip deepest-first, because a group's sub-bar sits
-- physically inside its parent's rectangle and a parent-first test would always
-- shadow it.
--
-- Returns a table describing the drop, or nil for "nothing here":
--   { strip = <destination>, index = <1-based insert position> }   -- reorder
--   { into  = <group strip> }                                      -- add to group
--   { merge = <tab widget>, strip = <its strip> }                  -- make a group
--
-- Every result also carries the geometry this function already had to compute --
-- `zone` (the destination strip), `band`, and the hovered tab's `tab_x`/`tab_w`,
-- plus `caret_x` for a reorder. `core.ui.TabDragMotion` needs exactly those
-- numbers to draw the outcome, and recomputing them there would mean a second
-- bisection per mouse-move and two hit-test implementations free to disagree.
-- Purely additive: the drop decision itself is untouched.
function TabOrder:_resolveDrop(source, x, y, dragged)
	local groups = self._groups
	if not groups then return nil end

	local sx, sy = self:_rect(source)
	if not sx then return nil end
	local gx, gy = sx + x, sy + y

	for _, strip in ipairs(groups:stripsDeepestFirst()) do
		local px, py, pw, ph = self:_rect(strip)
		if px and gx >= px and gx < px + pw and gy >= py and gy < py + ph then
			local band = self:_bandHeight(strip)
			if not band or gy >= py + band then
				-- Inside this strip's page area, not its tab bar. Deeper strips
				-- were already tested, so this is a miss rather than a fall-through.
				return nil
			end

			local lx, ly = gx - px, gy - py
			local pos = self:_posAt(strip, lx, ly)
			if not pos then
				-- Past the last tab (or on the "+" button): append here.
				return { strip = strip, index = nil, zone = strip, band = band }
			end

			local child = self:_child(strip, pos)
			-- Handle identity, NOT `==`: the binding hands out a fresh userdata per
			-- push (core.lib.handle). With `==` this guard never fired, so a plain
			-- click resolved as dropping a tab on itself and wrapped it in a new
			-- group -- and dropping a group on itself passed straight through.
			if not child or handle.same(self._iup, child, dragged) then return nil end

			local left, right = self:_tabBounds(strip, pos, lx, ly, pw)
			local width = math.max(1, right - left + 1)
			local rel = (lx - left) / width

			if rel >= EDGE_ZONE and rel <= (1 - EDGE_ZONE) then
				if groups:isGroupStrip(child) then
					return {
						into = child, zone = strip, band = band,
						tab_x = left, tab_w = width,
					}
				end
				return {
					merge = child, strip = strip, zone = strip, band = band,
					tab_x = left, tab_w = width,
				}
			end
			local before = (rel < EDGE_ZONE)
			local index = before and (pos + 1) or (pos + 2)
			return {
				strip = strip, index = index, zone = strip, band = band,
				tab_x = left, tab_w = width,
				caret_x = before and left or (left + width),
			}
		end
	end
	return nil
end

function TabOrder:_child(strip, pos)
	local ok, child = pcall(self._iup.GetChild, strip, pos)
	if not ok then return nil end
	return child
end

-- =======================================================================
-- SPRING-OPEN
-- =======================================================================

-- Open a group that the pointer has rested on, so its sub-bar becomes a drop
-- target and the tab can be placed at a chosen position inside it instead of
-- only appended.
function TabOrder:_springTimer()
	if self._timer then return self._timer end
	local iup = self._iup
	local self_ = self
	local timer = iup.timer({ TIME = SPRING_MS, RUN = "NO" })
	function timer:action_cb()
		pcall(iup.SetAttribute, timer, "RUN", "NO")
		local spring = self_._spring
		if spring and self_._drag then
			pcall(iup.SetAttribute, spring.strip, "VALUEPOS", tostring(spring.pos))
			if self_._on_switch then pcall(self_._on_switch) end
			pcall(iup.Refresh, spring.strip)
		end
		return iup.DEFAULT
	end
	self._timer = timer
	return timer
end

function TabOrder:_armSpring(strip, pos)
	if self._spring and handle.same(self._iup, self._spring.strip, strip)
		and self._spring.pos == pos then
		return   -- already counting down on this target
	end
	self._spring = { strip = strip, pos = pos }
	local timer = self:_springTimer()
	pcall(self._iup.SetAttribute, timer, "RUN", "NO")
	pcall(self._iup.SetAttribute, timer, "RUN", "YES")
end

function TabOrder:_cancelSpring()
	self._spring = nil
	if self._timer then pcall(self._iup.SetAttribute, self._timer, "RUN", "NO") end
end

-- =======================================================================
-- DEFERRED APPLY
-- =======================================================================

-- Carry out a resolved drop on the next main-loop tick instead of inside the
-- button callback that produced it.
--
-- The work is widget-tree surgery: detach pages, destroy a group, create a new
-- strip, remap. Doing that from inside `FLAT_BUTTON_CB` tears down and rebuilds
-- native windows while the strip is still dispatching the mouse event that
-- triggered it -- and while `iFlatTabsButton_CB`, which runs AFTER this callback
-- returns, is about to touch the same children. Roughly half the time forming a
-- group took the process down with it.
--
-- A one-shot timer costs a frame and moves all of it onto the main loop, after
-- the event has fully unwound.
function TabOrder:_scheduleDrop(widget, drop)
	self._pending = { widget = widget, drop = drop }

	if not self._drop_timer then
		local iup = self._iup
		local self_ = self
		local timer = iup.timer({ TIME = 1, RUN = "NO" })
		function timer:action_cb()
			pcall(iup.SetAttribute, timer, "RUN", "NO")
			local job = self_._pending
			self_._pending = nil
			if job then
				local ok, err = xpcall(function() self_:_applyDrop(job) end, debug.traceback)
				if not ok then
					local groups = self_._groups
					if groups and groups.log then pcall(groups.log, groups, err) end
				end
			end
			return iup.DEFAULT
		end
		self._drop_timer = timer
	end

	pcall(self._iup.SetAttribute, self._drop_timer, "RUN", "NO")
	pcall(self._iup.SetAttribute, self._drop_timer, "RUN", "YES")
end

-- Bounds of the tab at `pos` when no point inside it is known.
--
-- `_tabBounds` bisects outward from a pointer position, which is exactly right
-- during a drag but useless afterwards -- the folder-creation flourish needs the
-- bounds of a group tab that did not exist when the mouse was last seen. This
-- finds a seed by sampling across the band, then hands off to the same bisection
-- so both paths agree on where a tab's edges are.
--
-- Runs once per merge, not per frame, so the scan cost is irrelevant.
function TabOrder:_boundsOfPos(strip, pos, band, width)
	if not (strip and pos and band and width) then return nil end
	local y = math.floor(band / 2)
	local step = 8
	for x = 0, width - 1, step do
		if self:_posAt(strip, x, y) == pos then
			self._bounds = nil   -- the cache is keyed to the drag, not to this
			local left, right = self:_tabBounds(strip, pos, x, y, width)
			self._bounds = nil
			return left, math.max(1, right - left + 1)
		end
	end
	return nil
end

-- Carry out a resolved drop, with page transitions suspended for its duration.
--
-- The suspension is not optional. `TabGroups` finishes every move by calling
-- `reveal()`, which sets `VALUEPOS` -- and IUP fires `TABCHANGE_CB` SYNCHRONOUSLY
-- from inside that call. Without this guard, a page transition starts in the
-- middle of `moveInto`: it captures and composites pages that are detached and
-- not yet re-mapped, and holds snapshots of widgets the rest of the operation
-- goes on to move or destroy. That produced an intermittent hard crash whenever
-- tabs were dragged around, which is precisely the class of failure the deferred
-- apply below was already introduced to avoid.
function TabOrder:_applyDrop(job)
	local groups = self._groups
	if not groups then return end

	local transition = self._transition
	if transition then transition:suspend() end
	local ok, err = pcall(function() self:_applyDropInner(job) end)
	if transition then transition:resume() end
	if not ok then error(err, 0) end
end

function TabOrder:_applyDropInner(job)
	local groups = self._groups
	local drop = job.drop

	if drop.into then
		groups:moveInto(job.widget, drop.into)
	elseif drop.merge then
		self:_applyMerge(job, drop)
		return
	elseif drop.strip then
		groups:moveInto(job.widget, drop.strip, drop.index)
	end
	if self._on_switch then pcall(self._on_switch) end
end

-- Combine two tabs into a group, then show what happened.
--
-- The tree surgery runs FIRST and the flourish plays over the result, rather than
-- the other way round. Animating before applying would add the animation's full
-- duration to the latency of every group creation, and Carbon is explicit that
-- motion must not stand between the user and their result -- the movement explains
-- the change, it does not gate it.
function TabOrder:_applyMerge(job, drop)
	local groups = self._groups
	local motion = self._motion

	local parent = drop.zone
	local band   = drop.band
	local from_x, from_w

	if motion and parent and band then
		local _, _, pw = self:_rect(parent)
		local dragged_pos = self:_positionOf(parent, job.widget)
		local dx, dw
		if pw and dragged_pos then
			dx, dw = self:_boundsOfPos(parent, dragged_pos, band, pw)
		end
		if dx and drop.tab_x then
			-- The span both tabs occupied, which is what visibly collapses into one.
			local left  = math.min(dx, drop.tab_x)
			local right = math.max(dx + dw, drop.tab_x + drop.tab_w)
			from_x, from_w = left, right - left
		elseif drop.tab_x then
			-- Dragged in from another strip: approximate the pair as two tabs wide.
			from_x, from_w = drop.tab_x, drop.tab_w * 2
		end
	end

	local strip = groups:groupTogether(drop.merge, job.widget)
	if self._on_switch then pcall(self._on_switch) end

	if not (motion and strip and parent and band and from_x) then return end

	local _, _, pw = self:_rect(parent)
	local pos = self:_positionOf(parent, strip)
	local to_x, to_w
	if pw and pos then
		to_x, to_w = self:_boundsOfPos(parent, pos, band, pw)
	end
	if not to_x then return end

	-- Deliberately NOT forcing a repaint here.
	--
	-- An earlier version called `IupRedraw(parent, 1)` so the flourish would
	-- composite over a freshly painted strip. That drives a synchronous repaint of
	-- the strip and all its children from inside a timer callback, immediately
	-- after detach/create/append surgery and before IUP's own deferred refresh has
	-- run -- exactly the "touching the tree while it is still settling" pattern
	-- that makes this code crash. `moveInto` already called `IupRefresh`, so the
	-- repaint arrives on its own; the worst case without the forced redraw is a
	-- backdrop one frame stale, which is invisible at 400 ms.
	motion:playMerge(parent, { x = from_x, w = from_w }, { x = to_x, w = to_w }, band)
end

-- =======================================================================
-- INSTALLATION
-- =======================================================================

--- Install drag, hover and right-click handling on a tab strip.
--
-- Safe to call more than once for the same strip. Called by `TabGroups` for the
-- root strip and for every group strip it creates.
--
-- @tparam userdata strip an `iup.flattabs` handle
function TabOrder:install(strip)
	if not strip then return end
	local sid = handle.id(self._iup, strip)
	if self._strips[sid] then return end
	self._strips[sid] = true
	self._strip_handles[sid] = strip

	local iup   = self._iup
	local self_ = self

	self:_installTransition(sid, strip)

	-- Returning IUP_DEFAULT lets the control's own handler run afterwards, which
	-- is what keeps tab switching, the scroll arrows and the "+" extra button
	-- working.
	function strip:flat_button_cb(button, pressed, x, y, _status)
		if button ~= iup.BUTTON1 then return iup.DEFAULT end

		if pressed == 1 then
			self_._bounds = nil
			local pos = self_:_posAt(strip, x, y)
			if pos then
				-- Capture the outgoing page NOW, while it is still the visible one.
				-- The control switches pages after this callback returns, and IUP
				-- only reports the change afterwards -- by which point the old page
				-- is hidden and captures blank. Cheap and inert when motion is off.
				if self_._transition then
					pcall(function() self_._transition:arm(strip) end)
				end
				-- A press ARMS a possible drag; it does not start one. Nothing is
				-- rearranged until the pointer has actually travelled (see
				-- DRAG_THRESHOLD).
				self_._drag = {
					strip = strip,
					pos = pos,
					widget = self_:_child(strip, pos),
					ox = x, oy = y,
					moved = false,
				}
			else
				self_._drag = nil
			end
			return iup.DEFAULT
		end

		local drag = self_._drag
		self_._drag = nil
		self_:_cancelSpring()
		pcall(iup.SetAttribute, strip, "CURSOR", "ARROW")

		-- The gesture is over either way, so the feedback goes now. A drop that
		-- forms a group re-shows its own flourish below; anything else -- including
		-- an abandoned drag -- just ends, which is Carbon's "reversing the entrance
		-- signals cancellation".
		if self_._motion then self_._motion:clear() end

		-- A press and release without travel is a CLICK: let the control switch
		-- tabs and do nothing else.
		--
		-- This used to be decided by asking whether the release landed on the same
		-- widget as the press, which is not reliable. The control's own press
		-- handler switches the active tab first, and switching can move
		-- _IUPFTABS_SCROLLPOS (iFlatTabsScrollToTab), which shifts every tab along
		-- the strip. The release then hit-tests to a DIFFERENT tab than the press
		-- at the very same pixel, and an ordinary click was read as dropping one
		-- tab onto another -- silently combining them into a group. Travel is the
		-- only thing that actually distinguishes a drag from a click.
		if not (drag and drag.widget and drag.moved and self_._groups) then
			return iup.DEFAULT
		end

		local drop = self_:_resolveDrop(strip, x, y, drag.widget)
		if not drop then return iup.DEFAULT end

		-- Apply OUTSIDE this callback. Acting on the drop here means detaching,
		-- destroying and creating widgets -- and their native windows -- while the
		-- strip is midway through dispatching a mouse event, and while IUP's own
		-- iFlatTabsButton_CB is still to run against the very children being moved.
		-- That is what made forming a group crash roughly half the time.
		self_:_scheduleDrop(drag.widget, drop)
		return iup.DEFAULT
	end

	function strip:flat_motion_cb(x, y, _status)
		local drag = self_._drag
		if not (drag and drag.widget and self_._groups) then return iup.DEFAULT end

		if not drag.moved then
			local dx, dy = x - drag.ox, y - drag.oy
			if (dx * dx + dy * dy) < (DRAG_THRESHOLD * DRAG_THRESHOLD) then
				return iup.DEFAULT   -- still within the click tolerance
			end
			drag.moved = true
			pcall(iup.SetAttribute, strip, "CURSOR", "MOVE")
			-- This gesture is a DRAG, not a click. The capture taken on press was
			-- for a page transition that is no longer going to happen: any page
			-- change from here on is the tree being rearranged, not the user
			-- navigating, and sliding the pane sideways mid-drag would be wrong
			-- as well as expensive.
			if self_._transition then
				pcall(function() self_._transition:disarm() end)
			end
		end

		local drop = self_:_resolveDrop(strip, x, y, drag.widget)
		local motion = self_._motion

		if drop and drop.into then
			-- Hovering a closed group: count down to opening it, and show the
			-- "combine" cursor so the difference from a reorder is visible.
			local parent = self_._groups:stripOf(drop.into)
			local pos = self_:_positionOf(parent, drop.into)
			if parent and pos then self_:_armSpring(parent, pos) end
			pcall(iup.SetAttribute, strip, "CURSOR", "HAND")
			if motion and drop.zone then
				motion:showCombine(drop.zone, drop.tab_x, drop.tab_w, drop.band)
				motion:showSpring(drop.zone, drop.tab_x, drop.tab_w, drop.band)
			end
		elseif drop and drop.merge then
			self_:_cancelSpring()
			pcall(iup.SetAttribute, strip, "CURSOR", "HAND")
			if motion and drop.zone then
				motion:clearSpring()
				motion:showCombine(drop.zone, drop.tab_x, drop.tab_w, drop.band)
			end
		else
			self_:_cancelSpring()
			pcall(iup.SetAttribute, strip, "CURSOR", "MOVE")
			if motion then
				motion:clearSpring()
				if drop and drop.zone and drop.caret_x then
					motion:showCaret(drop.zone, drop.caret_x, drop.band)
				else
					motion:clear()
				end
			end
		end
		return iup.DEFAULT
	end

	function strip:rightclick_cb(pos)
		self_:_showMenu(strip, pos)
		return iup.DEFAULT
	end
end

function TabOrder:_positionOf(strip, widget)
	if not strip then return nil end
	local i = 0
	while true do
		local child = self:_child(strip, i)
		if not child then return nil end
		if handle.same(self._iup, child, widget) then return i end
		i = i + 1
	end
end

-- =======================================================================
-- CONTEXT MENU
-- =======================================================================

-- Right-click menu for the tab at `pos`. Offers the drag gestures as explicit
-- commands (which also makes them discoverable) plus rename/ungroup, which have
-- no drag equivalent.
function TabOrder:_showMenu(strip, pos)
	local groups = self._groups
	if not groups then return end
	local ContextMenu = require("core.ui.ContextMenu")
	local iup = self._iup
	local self_ = self

	local child = (pos ~= nil and pos >= 0) and self:_child(strip, pos) or nil
	local record = child and groups:groupOf(child) or nil
	local items = {}

	if not child then
		-- Right-click landed on the strip background, a scroll arrow or the "+"
		-- button. Offer the one thing that still makes sense there.
		items[#items + 1] = {
			title = "New Group...",
			action = function()
				groups:createGroup(strip, self_:_ask("New Tab Group", nil), "user")
			end,
		}
		if self._menu then pcall(function() self._menu:destroy() end) end
		self._menu = ContextMenu:new(iup, items)
		self._menu:popup()
		return
	end

	if record then
		items[#items + 1] = {
			title = "Rename Group...",
			action = function()
				local name = self_:_ask("Rename Group", record.name)
				if name then groups:renameGroup(child, name) end
			end,
		}
		items[#items + 1] = {
			title = "Ungroup",
			action = function()
				groups:dissolveGroup(child)
				if self_._on_switch then pcall(self_._on_switch) end
			end,
		}
		items[#items + 1] = { separator = true }
	elseif child then
		-- Flattened "move to" list: every group in the tree by full path, plus the
		-- root. ContextMenu is a flat list by design, so paths stand in for submenus.
		for _, entry in ipairs(groups:groupPaths()) do
			if not handle.same(iup, entry.strip, groups:stripOf(child)) then
				items[#items + 1] = {
					title = "Move to " .. entry.path,
					action = function()
						groups:moveInto(child, entry.strip)
						if self_._on_switch then pcall(self_._on_switch) end
					end,
				}
			end
		end
		items[#items + 1] = {
			title = "New Group With This Tab...",
			action = function()
				local name = self_:_ask("New Tab Group", nil)
				local parent = groups:stripOf(child)
				local at = (self_:_positionOf(parent, child) or 0) + 1
				local created = groups:createGroup(parent, name, "user", at)
				if created then groups:moveInto(child, created) end
				if self_._on_switch then pcall(self_._on_switch) end
			end,
		}
		items[#items + 1] = { separator = true }
	end

	items[#items + 1] = {
		title = "New Group...",
		action = function()
			local name = self_:_ask("New Tab Group", nil)
			groups:createGroup(strip, name, "user")
		end,
	}

	-- Kept alive until the NEXT popup rather than destroyed on the line after
	-- IupPopup: on Win32 a popup menu's item actions are delivered by the menu's
	-- own window, and tearing the handle down the instant TrackPopupMenu returns
	-- races that delivery.
	if self._menu then pcall(function() self._menu:destroy() end) end
	self._menu = ContextMenu:new(iup, items)
	self._menu:popup()
end

function TabOrder:_ask(title, default)
	if not self._prompt then return default end
	local ok, value = pcall(self._prompt, title, default)
	if not ok then return default end
	return value
end

return TabOrder

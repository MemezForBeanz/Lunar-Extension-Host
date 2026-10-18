--- Per-dialog retained scene manager over a platform backend.
-- Backend methods: `geometry()` returns `{w,h,scale}` in device pixels;
-- `present(scene, regions, opacity)` displays a frame (`opacity` 0..1 is the
-- whole layer's alpha; the frame number is `scene.generation`); `hide()` hides
-- it; `events()` may return queued resize, dpi, and action events. A backend may
-- instead supply `on(event, callback)` and push those events directly.
--
-- Optional: `fade(opacity)` re-shows the last frame at a new layer alpha without
-- rendering it again. When one group is on screen alone and only its opacity
-- changed, `commit` uses it, which is what makes a full-window scrim fade cost
-- nothing per frame even at 4K. Otherwise a group's opacity is multiplied into
-- its sprites' alpha. `rect(widget)` maps a widget to overlay pixels and
-- `snapshot([widget])` captures the dialog (or a widget) without the overlay.
--
-- `forDialog` builds a manager over the native module (`require("compositor")`)
-- for one IUP dialog.
-- @module core.lib.Compositor

local Scene = require("core.lib.Scene")
local M = {}
M.__index = M

--- Fixed group z bands.
M.Z_LIST_ENTRANCE = 10
M.Z_TAB = 20
M.Z_SCRIM = 30
M.Z_TOASTS = 40

-- A backend may be a table or native userdata (the overlay `require("compositor")`
-- returns); either way, look the methods up without letting a bad index raise.
local function method(backend, name)
	local ok, fn = pcall(function() return backend[name] end)
	return ok and type(fn) == "function" and fn or nil
end

--- Construct a manager for one dialog backend.
-- @tparam table backend Backend implementing geometry, present, and hide.
-- @treturn table Manager.
function M.new(backend)
	local kind = type(backend)
	assert((kind == "table" or kind == "userdata") and method(backend, "present") and
		method(backend, "hide") and method(backend, "geometry"),
		"compositor backend requires present, hide, and geometry")
	local self = setmetatable({ backend = backend, groups = {}, next_order = 0,
		dirty = false, generation = 0, live_actions = {},
		can_fade = method(backend, "fade") ~= nil, can_rect = method(backend, "rect") ~= nil,
		listeners = { resize = {}, dpi = {}, action = {} } }, M)
	local me = self
	self._commit_fn = function() me:commit() end
	if method(backend, "on") then
		for _, event in ipairs({ "resize", "dpi", "action" }) do
			backend:on(event, function(payload) self:_event(event, payload) end)
		end
	end
	return self
end

--- Set or replace only the named group's retained content.
-- @tparam string|number group_id Stable owner identifier.
-- @tparam table group `{z, sprites, regions}`.
function M:set(group_id, group)
	assert(type(group_id) == "string" or type(group_id) == "number", "group_id must be string or number")
	assert(type(group) == "table" and type(group.z) == "number" and
		group.z == group.z and group.z > -math.huge and group.z < math.huge,
		"group z must be finite number")
	assert(type(group.sprites) == "table" and type(group.regions) == "table",
		"group sprites and regions must be arrays")
	local opacity = group.opacity
	assert(opacity == nil or (type(opacity) == "number" and opacity >= 0 and opacity <= 1),
		"group opacity must be in [0, 1]")
	local old = self.groups[group_id]
	if not old then self.next_order = self.next_order + 1 end
	self.groups[group_id] = { z = group.z, sprites = group.sprites, regions = group.regions,
		opacity = opacity or (old and old.opacity) or 1,
		_order = old and old._order or self.next_order }
	self.dirty = true
end

--- Change one group's opacity (0..1) without touching its content.
-- @tparam string|number group_id Owner identifier.
-- @tparam number opacity New opacity; ignored for a group that isn't set.
function M:setOpacity(group_id, opacity)
	assert(type(opacity) == "number" and opacity >= 0 and opacity <= 1, "opacity must be in [0, 1]")
	local g = self.groups[group_id]
	if g and g.opacity ~= opacity then
		g.opacity = opacity
		self.faded = true
	end
end

--- Remove one owner's group.
-- @tparam string|number group_id Owner identifier.
function M:remove(group_id)
	local g = self.groups[group_id]
	if g then
		-- Its action ids are retired: a group set again before the next commit is a
		-- new owner of those ids, and clicks from the old frames aren't for it.
		self.retired = self.retired or {}
		for _, r in ipairs(g.regions) do
			if r.mode == "action" then self.retired[r.id] = true end
		end
		self.groups[group_id] = nil
		self.dirty = true
	end
end

--- A widget's rectangle in overlay pixels, when the backend can map it.
-- @param widget IUP handle
-- @treturn table|nil `{x, y, w, h}`
function M:rect(widget)
	if not self.can_rect then return nil end
	local x, y, w, h = self.backend:rect(widget)
	if not x then return nil end
	return { x = x, y = y, w = w, h = h }
end

--- A snapshot of the dialog (or one widget's part of it), without the overlay.
-- Best effort: nil and a reason where the backend can't capture. The caller owns
-- the snapshot and must `release()` it; it works as an `image` sprite's `snap`.
-- @param[opt] widget IUP handle
-- @treturn table|nil snapshot with `w`, `h` and `release()`
-- @treturn string|nil why not
function M:snapshot(widget)
	if not method(self.backend, "snapshot") then return nil, "the backend can't take snapshots" end
	local ok, snap, why = pcall(function() return self.backend:snapshot(widget) end)
	if not ok then return nil, tostring(snap) end
	if not snap then return nil, why or "no snapshot" end
	return snap
end

--- Return current device geometry and scale.
-- @treturn table `{w,h,scale}` from the backend.
function M:geometry()
	return self.backend:geometry()
end

--- Subscribe to resize, dpi, or action events.
-- @tparam string event Event name.
-- @tparam function fn Called with the event payload.
function M:on(event, fn)
	assert(self.listeners[event], "event must be resize, dpi, or action")
	assert(type(fn) == "function", "listener must be a function")
	self.listeners[event][#self.listeners[event] + 1] = fn
end

-- An action is delivered while the region it was clicked on is still on screen.
-- The backend resolved the id against the frame on screen when the click
-- happened (`payload.generation`), so a later frame of some unrelated animation
-- (which advances the generation every frame) must not discard it. A region that
-- has gone away does, and so does a *new* region that reuses the id: each id
-- remembers the frame it (re)appeared in, and a click from before that frame
-- belonged to the old one.
function M:_event(event, payload)
	if not self.listeners[event] then return end
	if event == "action" then
		if type(payload) ~= "table" then return end
		local since = self.live_actions[payload.id]
		if not since then return end
		local gen = tonumber(payload.generation)
		if gen and gen < since then return end
	end
	-- A new size or scale needs a fresh frame even if no group changed.
	if event == "resize" or event == "dpi" then self.dirty = true end
	for _, fn in ipairs(self.listeners[event]) do fn(payload) end
end

--- Deliver queued backend events, if the backend exposes `events()`.
function M:poll()
	if not method(self.backend, "events") then return end
	for _, event in ipairs(self.backend:events() or {}) do
		self:_event(event.type, event)
	end
end

-- The one group with sprites, if exactly one has any.
local function sole_group(groups)
	local only
	for id, g in pairs(groups) do
		if #g.sprites > 0 then
			if only ~= nil then return nil end
			only = id
		end
	end
	return only
end

-- Groups as the scene should draw them: opacity multiplied into sprite alpha.
local function baked(groups)
	local out = {}
	for id, g in pairs(groups) do
		local sprites = g.sprites
		if g.opacity < 1 then
			sprites = {}
			for i, s in ipairs(g.sprites) do
				local c = {}
				for k, v in pairs(s) do c[k] = v end
				c.alpha = s.alpha * g.opacity
				sprites[i] = c
			end
		end
		out[id] = { z = g.z, sprites = sprites, regions = g.regions, _order = g._order }
	end
	return out
end

--- Commit at the end of the director's current frame (once, however many effects
-- ask), or now when no frame is running. Effects animating on the same dialog
-- call this from `on_frame` so the dialog presents one frame per tick.
-- @tparam[opt] table director `core.classes.MotionDirector`; without one, commits now
function M:schedule(director)
	if director and director.atFrameEnd then
		director:atFrameEnd(self._commit_fn)
	else
		self:commit()
	end
end

--- Present a coalesced scene, or hide an empty one.
-- Calling commit again without changes has no backend effect. The generation
-- advances once for each changed frame, including a hide; an opacity-only
-- `fade` of the frame already on screen keeps it (the regions are unchanged).
-- @treturn boolean True if a changed frame was submitted.
function M:commit()
	self:poll()
	if not self.dirty then
		if not self.faded then return false end
		self.faded = false
		local layer = self.layer_group and self.groups[self.layer_group]
		if layer and sole_group(self.groups) == self.layer_group then
			-- false: no frame to fade, or it is stale after a resize; render instead.
			if self.backend:fade(layer.opacity) ~= false then return true end
		end
		self.dirty = true
	end
	-- One group alone is shown at full strength and faded as a layer, so later
	-- opacity changes need no render; several are baked into one frame.
	local layer = self.can_fade and sole_group(self.groups) or nil
	local opacity = 1
	local draw = self.groups
	if layer ~= nil then opacity = self.groups[layer].opacity else draw = baked(self.groups) end
	local geometry = self:geometry()
	if type(geometry) ~= "table" then
		-- The dialog is gone (or not mapped): nothing can be shown; keep the work,
		-- but stop pumping for it.
		self.dirty = true
		self:_pump(false)
		return false
	end
	local sprites, regions = Scene.flatten(draw)
	local scene = { w = geometry.w, h = geometry.h, regions = regions }
	for i, sprite in ipairs(sprites) do scene[i] = sprite end
	local valid, why = Scene.validate(scene)
	if not valid then error("invalid compositor scene: " .. why, 2) end
	local generation = self.generation + 1
	scene.generation = generation
	-- Input-only content (block/action regions, no pixels) still needs the layer up.
	local takes_input = false
	for _, r in ipairs(regions) do if r.mode ~= "pass" then takes_input = true break end end
	local visible = #sprites > 0 or takes_input
	local shown, err = true, nil
	if not visible then self.backend:hide()
	else shown, err = self.backend:present(scene, regions, opacity) end
	if shown == false then
		-- Nothing changed on screen: keep the work pending and the old actions live.
		self.dirty, self.faded = true, false
		self.last_error = err
		return false
	end
	-- Published only now that the frame is on screen.
	self.generation = generation
	local live, retired = {}, self.retired or {}
	for _, region in ipairs(regions) do
		if region.mode == "action" then
			live[region.id] = (not retired[region.id] and self.live_actions[region.id]) or generation
		end
	end
	self.live_actions = live
	self.retired = nil
	self.layer_group = layer
	self.dirty, self.faded = false, false
	self.last_error = nil
	self:_pump(visible)
	return true
end

-- While anything is on screen, commit every `pump_ms` so a resize or DPI change
-- is answered even when no effect is animating (a scrim at rest under a modal),
-- and put the layer back on top of any sibling IUP raised meanwhile.
function M:_pump(on)
	local iup = self.iup
	if not iup then return end
	if on and not self.pump then
		local me = self
		self.pump = iup.timer({ time = self.pump_ms or 100 })
		function self.pump.action_cb()
			pcall(me._pumpTick, me)
			return iup.DEFAULT
		end
		self.pump.run = "YES"
	elseif not on and self.pump then
		local t = self.pump
		self.pump = nil
		t.run = "NO"
		if iup.Destroy then pcall(iup.Destroy, t) end
	end
end

function M:_pumpTick()
	if not self:commit() and self.pump and method(self.backend, "raise") then
		self.backend:raise()
	end
end

--- Stop the pump and drop retained content (the dialog is going away).
function M:close()
	self:_pump(false)
	self.groups = {}
	self.live_actions = {}
end

local by_dialog = setmetatable({}, { __mode = "k" })

--- The compositor for an IUP dialog, created on first use.
-- The dialog must be shown (the backend needs its native window). Returns nil
-- and a reason where the platform has no compositor backend yet (Linux until
-- the GTK backend lands) or the overlay can't be created.
-- @tparam table iup the IUP binding (for the resize pump)
-- @param dialog IUP dialog handle
-- @tparam[opt] table native the native module (default `require("compositor")`)
-- @treturn table|nil manager
-- @treturn string|nil why not
function M.forDialog(iup, dialog, native)
	local cached = by_dialog[dialog]
	if cached then return cached end
	if not native then
		local ok, mod = pcall(require, "compositor")
		if not ok then return nil, "no compositor module" end
		native = mod
	end
	local ok, supported, why = pcall(native.supported)
	if not ok or not supported then return nil, why or "the compositor isn't supported here" end
	local ov, err = native.overlay(dialog)
	if not ov then return nil, err end
	local comp = M.new(ov)
	comp.iup = iup
	by_dialog[dialog] = comp
	return comp
end

return M

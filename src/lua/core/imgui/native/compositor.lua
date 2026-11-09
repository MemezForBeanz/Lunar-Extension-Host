--- ImGui-host compositor compatible with Lunar's native compositor module.
--
-- Unlike the IUP backend this does not allocate another OS window.  Its overlay
-- is a Runtime overlay, so it remains in the same retained frame and never
-- participates in input routing.
-- @module core.imgui.native.compositor

local Element = require("core.imgui.Element")
local Draw = require("core.imgui.Draw")
local Runtime = require("core.imgui.Runtime")

local M = {}

local function state(el)
	return el and Element.state(el)
end

local function geometry(dialog)
	local st = state(dialog)
	if st and st.w and st.h and st.w > 0 and st.h > 0 then
		return { w = math.floor(st.w), h = math.floor(st.h), scale = 1 }
	end
	local backend = Runtime.backend()
	if backend and backend.window then
		local w, h = backend.window("client")
		if w and h then return { w = math.floor(w), h = math.floor(h), scale = 1 } end
	end
	return nil
end

local function rect(widget)
	local st = state(widget)
	if not st then return nil end
	return { x = math.floor(st.x or 0), y = math.floor(st.y or 0),
		w = math.max(0, math.floor(st.w or 0)), h = math.max(0, math.floor(st.h or 0)) }
end

local function snapshot(widget)
	local st = state(widget)
	local dc = Runtime.dc()
	if not st or not dc then return nil, "widget is not mapped" end
	local r = rect(widget)
	if not r or r.w <= 0 or r.h <= 0 then return nil, "widget has no size" end

	-- Record in widget-local coordinates.  This makes the recording usable as
	-- an image sprite, whose x/y is the destination rather than the source.
	dc:offset_push(-r.x, -r.y)
	dc:record(false)
	Runtime.paint(widget, dc)
	local calls = dc:stop()
	dc:offset_pop()

	local snap = { w = r.w, h = r.h, calls = calls, recording = calls }
	function snap:release()
		self.calls = {}
		self.recording = self.calls
		self.released = true
	end
	return snap
end

local function clip(dc, r)
	if not r then return false end
	dc:clip_push(r.x, r.y, r.w, r.h)
	return true
end

local function draw_sprite(dc, sprite, layer_alpha)
	local alpha = (tonumber(sprite.alpha) or 1) * layer_alpha
	if alpha <= 0 then return end
	local clipped = clip(dc, sprite.clip)
	if sprite.kind == "image" then
		local snap = sprite.snap
		if snap and snap.calls and not snap.released then
			-- Draw.replay has no scale operation.  Motion's scene coordinates
			-- are already integral, so preserve the recording at native size.
			dc:replay(snap.calls, sprite.x or 0, sprite.y or 0, alpha)
		end
	elseif sprite.kind == "fill" then
		dc:alpha_push(alpha)
		dc:fill(sprite.x or 0, sprite.y or 0, sprite.w or 0, sprite.h or 0, sprite.color)
		dc:alpha_pop()
	elseif sprite.kind == "rrect" then
		dc:alpha_push(alpha)
		dc:fill(sprite.x or 0, sprite.y or 0, sprite.w or 0, sprite.h or 0,
			sprite.color, { radius = sprite.radius or 0 })
		dc:alpha_pop()
	elseif sprite.kind == "stroke" then
		dc:alpha_push(alpha)
		dc:rect(sprite.x or 0, sprite.y or 0, sprite.w or 0, sprite.h or 0,
			sprite.color, { thickness = sprite.thickness or 1 })
		dc:alpha_pop()
	end
	if clipped then dc:clip_pop() end
end

local Overlay = {}
Overlay.__index = Overlay

function Overlay:geometry()
	return geometry(self.dialog)
end

function Overlay:rect(widget)
	local r = rect(widget)
	if not r then return nil end
	return r.x, r.y, r.w, r.h
end

function Overlay:snapshot(widget)
	return snapshot(widget or self.dialog)
end

function Overlay:present(scene, regions, opacity)
	if type(scene) ~= "table" then return nil, "scene must be a table" end
	self.scene = scene
	self.regions = regions or scene.regions or {}
	self.opacity = math.max(0, math.min(1, tonumber(opacity) or 1))
	self.visible = true
	if not self.handle or not self.handle:isOpen() then
		self.handle = Runtime.overlay({
			owner = self.dialog,
			draw = function(dc)
				if not self.visible or not self.scene then return end
				Runtime.animate()
				for i = 1, #self.scene do
					draw_sprite(dc, self.scene[i], self.opacity)
				end
			end,
		})
	end
	Runtime.animate()
	return true
end

function Overlay:hide()
	self.visible = false
	self.scene = nil
	if self.handle then self.handle:close() end
	return true
end

function Overlay:fade(opacity)
	self.opacity = math.max(0, math.min(1, tonumber(opacity) or 0))
	if self.visible then Runtime.animate() end
	return true
end

function Overlay:events()
	return {}
end

function Overlay:on(event, fn)
	if type(fn) ~= "function" then error("listener must be a function", 2) end
	self.listeners[event] = self.listeners[event] or {}
	self.listeners[event][#self.listeners[event] + 1] = fn
end

function Overlay:emit(event, payload)
	for _, fn in ipairs(self.listeners[event] or {}) do fn(payload) end
end

function Overlay:isOpen()
	return self.visible == true
end

function M.supported()
	return true
end

function M.overlay(dialog)
	if not state(dialog) then return nil, "dialog is not an ImGui element" end
	return setmetatable({
		dialog = dialog, listeners = {}, visible = false, opacity = 1,
	}, Overlay)
end

-- These two helpers are part of compositor_lua.c's module-level API.  Pixel
-- buffers are not consumed by ImGui's draw list, but retaining their dimensions
-- keeps callers that construct image sprites source-compatible.
function M.image(w, h, bytes)
	return { w = assert(tonumber(w)), h = assert(tonumber(h)), bytes = bytes,
		release = function(self) self.released = true; self.bytes = nil end }
end

function M.render(scene)
	return scene
end

return M

--- The main window's frame on the ImGui host: Lunar's title bar in place of the caption.
--
-- The same API as `src/c/libs/winframe_wrap.c`. There the frame was a Win32 subclass
-- painting three caption buttons on the dialog's surface. Here the window is already
-- ours: it opens without a system caption, the backend's hit test makes the bar drag
-- the window (and the maximize button open Snap Layouts), and the buttons are drawn
-- after the main dialog each frame with the colours Lua supplies.
--
--     winframe.supported()              true when the backend can run a custom frame
--     winframe.attach(dialog)           true once the frame is ours (before the first Show)
--     winframe.caption(dialog, height)  the bar's height in pixels
--     winframe.colors(dialog, bg, fg, muted, hover, press)  COLORREFs (0x00BBGGRR)
--     winframe.reserved(dialog)         the width the buttons take, in pixels
--
-- @module core.imgui.native.winframe
local Element = require("core.imgui.Element")
local Color = require("core.imgui.Color")

local M = {}

local BUTTON_W = 46
local CLOSE_RED = Color.pack(196, 43, 28)
local CLOSE_RED_PRESS = Color.pack(180, 39, 26)

local frames = setmetatable({}, { __mode = "k" })

local function rt() return require("core.imgui.Runtime") end

local function scale()
	local B = rt().backend()
	local s = B and B.window and B.window("dpi")
	return (type(s) == "number" and s > 0) and s or 1
end

local function colorref(c)
	c = tonumber(c) or 0
	local r = c % 256
	local g = math.floor(c / 256) % 256
	local b = math.floor(c / 65536) % 256
	return Color.pack(r, g, b, 255)
end

function M.supported()
	local B = rt().backend()
	return B ~= nil and B.window ~= nil
end

local function buttons(f, w)
	local bw = math.floor(BUTTON_W * scale() + 0.5)
	local h = f.caption
	return {
		{ kind = "min", x = w - 3 * bw, w = bw, h = h },
		{ kind = "max", x = w - 2 * bw, w = bw, h = h },
		{ kind = "close", x = w - bw, w = bw, h = h },
	}
end

-- Classes that are not windows in IUP: layout boxes and fills. Over the caption they let
-- the bar drag the window; anything else there (buttons, tab strips, labels, canvases)
-- is a child window in IUP, so a click on it is the control's, not the frame's. A class is
-- windowless when IupGetClassType says "void"; the dialog being walked is the frame itself.
local function windowless(st) return st.classname == "dialog" or st.class.type == "void" end

--- The rectangles over the caption that must not drag the window.
local function no_drag_rects(main, caption_h)
	local rects = {}
	local R = rt()
	local function walk(el)
		local st = Element.state(el)
		if not st or st.attrs.VISIBLE == "NO" then return end
		if st.h > 0 and st.y >= caption_h then return end -- below the bar: nothing under it can reach up
		if not windowless(st) and st.w > 0 and st.h > 0 and st.y < caption_h then
			rects[#rects + 1] = { x = st.x, y = st.y, w = st.w, h = math.min(st.h, caption_h - st.y) }
			return -- a window covers its children
		end
		for _, c in ipairs(R.childrenShown(el, st)) do walk(c) end
	end
	if main then walk(main) end
	return rects
end
M._noDragRects = no_drag_rects

local function paint(f, dc, input)
	if f.caption <= 0 then return end
	local w = input.w
	local B = rt().backend()
	local maximized = B.window("is_maximized")
	for i, b in ipairs(buttons(f, w)) do
		local hover = input.mx >= b.x and input.mx < b.x + b.w and input.my >= 0 and input.my < b.h
		local pressed = hover and f.press == i
		local bg
		if b.kind == "close" and (hover or pressed) then bg = pressed and CLOSE_RED_PRESS or CLOSE_RED
		elseif pressed then bg = f.press_bg
		elseif hover then bg = f.hover_bg end
		if bg then dc:fill(b.x, 0, b.w, b.h, bg) end
		local fg = (b.kind == "close" and hover) and Color.pack(255, 255, 255) or (f.active and f.fg or f.muted)
		local cx, cy = b.x + math.floor(b.w / 2), math.floor(b.h / 2)
		local s = math.floor(5 * scale() + 0.5)
		if b.kind == "min" then
			dc:line(cx - s, cy + 0.5, cx + s, cy + 0.5, fg, 1)
		elseif b.kind == "max" then
			if maximized then
				dc:rect(cx - s, cy - s + 2, 2 * s - 2, 2 * s - 2, fg, { radius = 1 })
				dc:line(cx - s + 2, cy - s + 0.5, cx + s - 0.5, cy - s + 0.5, fg, 1)
				dc:line(cx + s - 0.5, cy - s, cx + s - 0.5, cy + s - 2, fg, 1)
			else
				dc:rect(cx - s, cy - s, 2 * s, 2 * s, fg, { radius = 1 })
			end
		else
			dc:line(cx - s, cy - s, cx + s, cy + s, fg, 1)
			dc:line(cx + s, cy - s, cx - s, cy + s, fg, 1)
		end
	end
	-- Tell the backend where the caption is, so dragging and Snap work.
	local bs = buttons(f, w)
	B.window("caption", { x = 0, y = 0, w = w, h = f.caption }, {
		min = { x = bs[1].x, y = 0, w = bs[1].w, h = f.caption },
		max = { x = bs[2].x, y = 0, w = bs[2].w, h = f.caption },
		close = { x = bs[3].x, y = 0, w = bs[3].w, h = f.caption },
		nodrag = no_drag_rects(rt().mainDialog(), f.caption),
	})
end

local function route(f, input)
	if f.caption <= 0 then return false end
	local B = rt().backend()
	local inside_bar = input.my >= 0 and input.my < f.caption
	local which
	for i, b in ipairs(buttons(f, input.w)) do
		if inside_bar and input.mx >= b.x and input.mx < b.x + b.w then which = i end
	end
	if input.pressed[1] > 0 and which then f.press = which; return true end
	if f.press then
		if input.released[1] > 0 or not input.down[1] then
			local done = f.press == which and which
			f.press = nil
			if done == 1 then B.window("minimize")
			elseif done == 2 then
				if B.window("is_maximized") then B.window("restore") else B.window("maximize") end
			elseif done == 3 then
				local main = rt().mainDialog()
				if main and Element.call(main, "CLOSE_CB") ~= -1 then rt().hide(main) end
			end
		end
		return true
	end
	return false
end

function M.attach(dialog)
	local st = Element.state(dialog)
	if not st or not M.supported() then return false end
	if frames[dialog] then return true end
	local f = { caption = 0, fg = Color.pack(255, 255, 255), muted = Color.pack(160, 160, 160),
		hover_bg = Color.pack(255, 255, 255, 24), press_bg = Color.pack(255, 255, 255, 40), active = true }
	frames[dialog] = f
	st.data.custom_frame = true
	local B = rt().backend()
	if B.alive and B.alive() then pcall(B.window, "custom_frame", true) end
	local R = rt()
	R.postPaint[#R.postPaint + 1] = function(dc, input)
		if R.mainDialog() == dialog then paint(f, dc, input) end
	end
	R.preRoute[#R.preRoute + 1] = function(input)
		if R.mainDialog() ~= dialog then return false end
		return route(f, input)
	end
	return true
end

function M.caption(dialog, height)
	local f = frames[dialog]
	if not f then return false end
	f.caption = math.floor((tonumber(height) or 0) * scale() + 0.5)
	return true
end

function M.colors(dialog, bg, fg, muted, hover, press)
	local f = frames[dialog]
	if not f then return false end
	f.bg = colorref(bg)
	f.fg = colorref(fg)
	f.muted = colorref(muted)
	f.hover_bg = colorref(hover)
	f.press_bg = colorref(press)
	return true
end

function M.reserved(dialog)
	if not frames[dialog] then return 0 end
	return 3 * math.floor(BUTTON_W * scale() + 0.5)
end

return M

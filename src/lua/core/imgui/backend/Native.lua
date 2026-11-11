--- The native backend: `lunarimgui` (the C module in src/cpp/lunarimgui.cpp) with its hot
-- path called through LuaJIT's FFI.
--
-- Window, system and resource calls (open, window, clipboard, dialogs, fonts, textures,
-- frame_begin/frame_end) stay on the Lua C API: they pump Win32 messages, and the window
-- procedure calls back into Lua while the window is being sized, which a function called
-- through the FFI must never do. Everything a frame does per primitive (rectangles, lines,
-- text, images, clipping, measuring) and the frame's input are FFI calls and FFI struct
-- reads: LuaJIT compiles them into its traces, and no Lua table is built per frame.
--
-- The full Dear ImGui C API (cimgui) is in the same executable; `core.imgui.cimgui` gives
-- extensions that want real ImGui windows or widgets the FFI namespace for it.
--
-- @module core.imgui.backend.Native
local C_API = require("lunarimgui")

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then return C_API end

local cdef_ok = pcall(ffi.cdef, [[
typedef struct ImDrawList ImDrawList;
typedef struct ImFont ImFont;
typedef struct LunarUiEvent {
	int32_t type, button, mods, code;
	float x, y, dx, dy;
} LunarUiEvent;
typedef struct LunarUiFrame {
	int32_t w, h;
	float scale;
	int32_t focused, resized, minimized, close_requested, inside;
	float mx, my;
	int32_t nevents;
	const LunarUiEvent *events;
	int32_t nchars;
	const char *const *chars;
	int32_t nfiles;
	const char *const *files;
} LunarUiFrame;
ImDrawList *lunar_ui_draw_list(int layer);
void lunar_ui_rect(ImDrawList *dl, float x1, float y1, float x2, float y2, uint32_t col, float rounding, float thick, int flags);
void lunar_ui_rect_filled(ImDrawList *dl, float x1, float y1, float x2, float y2, uint32_t col, float rounding, int flags);
void lunar_ui_rect_gradient(ImDrawList *dl, float x1, float y1, float x2, float y2, uint32_t a, uint32_t b, uint32_t c, uint32_t d);
void lunar_ui_line(ImDrawList *dl, float x1, float y1, float x2, float y2, uint32_t col, float thick);
void lunar_ui_circle(ImDrawList *dl, float cx, float cy, float r, uint32_t col, float thick, int segments);
void lunar_ui_poly(ImDrawList *dl, const float *xy, int n, uint32_t col, int filled, float thick);
void lunar_ui_text(ImDrawList *dl, int face, float px, float x, float y, uint32_t col, const char *s, size_t len,
	float wrap, float cx1, float cy1, float cx2, float cy2, int gid);
void lunar_ui_text_size(int face, float px, const char *s, size_t len, float wrap, float *out);
int lunar_ui_image(ImDrawList *dl, int tex, float x1, float y1, float x2, float y2, float u1, float v1, float u2, float v2, uint32_t col);
void lunar_ui_clip_push(ImDrawList *dl, float x1, float y1, float x2, float y2);
void lunar_ui_clip_pop(ImDrawList *dl);
ImFont *lunar_ui_face_font(int face);
int lunar_ui_sizeof(int which);
int lunar_ui_gdi_text_size(int id, float px, const char *s, size_t len, float wrap, float *out);
]])

local C = ffi.C
-- An exe without the exports (an older build) keeps the C API for everything.
local have = cdef_ok and pcall(function() return C.lunar_ui_sizeof end)
if not have then return C_API end
if C.lunar_ui_sizeof(0) ~= ffi.sizeof("LunarUiEvent") or C.lunar_ui_sizeof(1) ~= ffi.sizeof("LunarUiFrame") then
	error("lunarimgui: the FFI declarations do not match this executable")
end

local B = {}
for k, v in pairs(C_API) do B[k] = v end
B.ffi = true

local FLT_MAX = 3.402823466e38
local floor = math.floor
local dl = C.lunar_ui_draw_list(0)
local layer = 0
-- The surface draws land on: 0 is the main window, else a dialog window's id
-- (window("popup_open")). An exe without dialog windows draws everything on the main one.
local surface = 0
local list_of = function(n) return C.lunar_ui_draw_list(n) end
if pcall(ffi.cdef, "ImDrawList *lunar_ui_popup_list(int id, int layer);")
	and pcall(function() return C.lunar_ui_popup_list end) then
	list_of = function(n) return C.lunar_ui_popup_list(surface, n) end
	B.dialog_windows = true
	--- Draw on a dialog window (id) or the main window (0) from here on.
	function B.surface(id)
		id = id or 0
		if id ~= surface then surface = id; dl = list_of(layer) end
	end
end

-- Input -----------------------------------------------------------------------------------
-- The table Runtime reads, filled from the frame struct and reused every frame.
local frame_ptr_t = ffi.typeof("const LunarUiFrame *")
local input = {
	w = 0, h = 0, scale = 1, mx = -1, my = -1, inside = false,
	down = { false, false, false }, pressed = { 0, 0, 0 }, released = { 0, 0, 0 }, double = { 0, 0, 0 },
	wheel_x = 0, wheel_y = 0, keys = {}, chars = {}, files = {}, events = {},
	mods = { shift = false, ctrl = false, alt = false, sys = false },
	focused = false, resized = false, minimized = false, close_requested = false,
}
local events = {}       -- pooled event tables
local MODS = {}         -- mods bits -> a shared mods table
local function mods_of(bits)
	local m = MODS[bits]
	if not m then
		m = { shift = bit.band(bits, 1) ~= 0, ctrl = bit.band(bits, 2) ~= 0, alt = bit.band(bits, 4) ~= 0,
			sys = bit.band(bits, 8) ~= 0, b1 = bit.band(bits, 16) ~= 0, b2 = bit.band(bits, 32) ~= 0,
			b3 = bit.band(bits, 64) ~= 0 }
		MODS[bits] = m
	end
	return m
end
local TYPES = { "move", "press", "release", "wheel", "keydown", "keyup", "char", "leave", "file", "tray" }

local raw_frame_begin = C_API.frame_begin
function B.frame_begin()
	local f = ffi.cast(frame_ptr_t, raw_frame_begin())
	surface = 0
	dl, layer = C.lunar_ui_draw_list(0), 0
	input.w, input.h, input.scale = f.w, f.h, f.scale
	input.mx, input.my, input.inside = f.mx, f.my, f.inside ~= 0
	input.focused, input.resized = f.focused ~= 0, f.resized ~= 0
	input.minimized, input.close_requested = f.minimized ~= 0, f.close_requested ~= 0
	local pressed, released, double, down = input.pressed, input.released, input.double, input.down
	for b = 1, 3 do pressed[b], released[b], double[b] = 0, 0, 0 end
	local wx, wy = 0, 0
	local keys, chars, files, list = input.keys, input.chars, input.files, input.events
	for i = #keys, 1, -1 do keys[i] = nil end
	for i = #list, 1, -1 do list[i] = nil end
	for i = #chars, 1, -1 do chars[i] = nil end
	for i = #files, 1, -1 do files[i] = nil end
	for i = 0, f.nchars - 1 do chars[i + 1] = ffi.string(f.chars[i]) end
	for i = 0, f.nfiles - 1 do files[i + 1] = ffi.string(f.files[i]) end
	local last_mods = 0
	for i = 0, f.nevents - 1 do
		local e = f.events[i]
		local ev = events[i + 1]
		if not ev then ev = {}; events[i + 1] = ev end
		local t = TYPES[e.type]
		local button = e.button
		local dbl = button > 8
		if dbl then button = button - 8 end
		ev.type, ev.x, ev.y, ev.button, ev.double = t, e.x, e.y, button, dbl
		ev.dx, ev.dy, ev.code, ev.char, ev.file = e.dx, e.dy, nil, nil, nil
		-- bits 8 and up: the window it came from (0 the main one, else a dialog window id)
		local bits = bit.band(e.mods, 0xFF)
		ev.win = bit.rshift(e.mods, 8)
		ev.mods = mods_of(bits)
		last_mods = bits
		if t == "press" then
			pressed[button] = pressed[button] + 1
			if dbl then double[button] = double[button] + 1 end
		elseif t == "release" then
			released[button] = released[button] + 1
		elseif t == "wheel" then
			wx, wy = wx + e.dx, wy + e.dy
		elseif t == "keydown" or t == "keyup" then
			ev.code = e.code
			local m = ev.mods
			keys[#keys + 1] = { code = e.code, down = t == "keydown", shift = m.shift, ctrl = m.ctrl, alt = m.alt, sys = m.sys }
		elseif t == "char" then
			ev.char = chars[e.code + 1]
		elseif t == "file" then
			ev.file = files[e.code + 1]
		elseif t == "tray" then
			-- lunarimgui: button + 8 on a double click, dx = pressed, dy = double
			ev.button = e.button > 8 and e.button - 8 or e.button
			ev.pressed = e.dx ~= 0
			ev.double = e.dy ~= 0
		end
		list[i + 1] = ev
	end
	input.wheel_x, input.wheel_y = wx, wy
	-- Buttons held now: the last event's state, or what the previous frame left.
	if f.nevents > 0 then
		down[1], down[2], down[3] = bit.band(last_mods, 16) ~= 0, bit.band(last_mods, 32) ~= 0, bit.band(last_mods, 64) ~= 0
		for b = 1, 3 do
			local last = nil
			for i = #list, 1, -1 do
				local ev = list[i]
				if (ev.type == "press" or ev.type == "release") and ev.button == b then last = ev.type; break end
			end
			if last == "press" then down[b] = true elseif last == "release" then down[b] = false end
		end
	end
	local m = input.mods
	local held = mods_of(last_mods)
	if f.nevents == 0 then held = mods_of(0) end
	m.shift, m.ctrl, m.alt, m.sys = held.shift, held.ctrl, held.alt, held.sys
	return input
end

-- Drawing --------------------------------------------------------------------------------
function B.layer(n)
	n = (n == 1) and 1 or 0
	if n ~= layer then layer = n; dl = list_of(n) end
end
function B.rect(x1, y1, x2, y2, col, rounding, thick, flags)
	C.lunar_ui_rect(dl, x1, y1, x2, y2, col, rounding or 0, thick or 1, flags or 0)
end
function B.rect_filled(x1, y1, x2, y2, col, rounding, flags)
	C.lunar_ui_rect_filled(dl, x1, y1, x2, y2, col, rounding or 0, flags or 0)
end
function B.rect_gradient(x1, y1, x2, y2, a, b, c, d)
	C.lunar_ui_rect_gradient(dl, x1, y1, x2, y2, a, b, c, d)
end
function B.line(x1, y1, x2, y2, col, thick)
	C.lunar_ui_line(dl, x1, y1, x2, y2, col, thick or 1)
end
function B.circle(cx, cy, r, col, thick, segments)
	C.lunar_ui_circle(dl, cx, cy, r, col, thick or 1, segments or 0)
end
local poly_buf, poly_cap = ffi.new("float[64]"), 64
function B.poly(points, col, filled, thick)
	local n = #points
	if n > poly_cap then poly_cap = n; poly_buf = ffi.new("float[?]", n) end
	for i = 1, n do poly_buf[i - 1] = points[i] end
	C.lunar_ui_poly(dl, poly_buf, floor(n / 2), col, filled and 1 or 0, thick or 1)
end
-- gid: the GDI font (Fonts' `gid`); its character positions place the glyphs.
function B.text(face, px, x, y, col, s, wrap, cx1, cy1, cx2, cy2, gid)
	C.lunar_ui_text(dl, face, px, x, y, col, s, #s, wrap or 0,
		cx1 or -FLT_MAX, cy1 or -FLT_MAX, cx2 or FLT_MAX, cy2 or FLT_MAX, gid or -1)
end
local size_out = ffi.new("float[2]")
function B.text_size(face, px, s, wrap)
	C.lunar_ui_text_size(face, px, s, #s, wrap or 0, size_out)
	return size_out[0], size_out[1]
end
function B.gdi_text_size(id, px, s, wrap)
	if C.lunar_ui_gdi_text_size(id, px, s, #s, wrap or 0, size_out) == 0 then return nil end
	return size_out[0], size_out[1]
end
function B.image(tex, x1, y1, x2, y2, u1, v1, u2, v2, col)
	C.lunar_ui_image(dl, tex, x1, y1, x2, y2, u1 or 0, v1 or 0, u2 or 1, v2 or 1, col or 0xFFFFFFFF)
end
-- Provider pixels (iupdrvDrawBits): 32-bit BGRA behind a pointer, premultiplied, with a stride.
if pcall(ffi.cdef, [[
int lunar_ui_texture_bits(const void *bgra, int w, int h, int stride, int premultiplied);
void lunar_ui_texture_free(int id);
int lunar_ui_image_rounded(ImDrawList *dl, int tex, float x1, float y1, float x2, float y2, uint32_t col, float rounding);
]]) and pcall(function() return C.lunar_ui_texture_bits end) then
	function B.texture_bits(ptr, w, h, stride, premultiplied)
		local id = C.lunar_ui_texture_bits(ptr, w, h, stride or w * 4, premultiplied == false and 0 or 1)
		return id ~= 0 and id or nil
	end
	local texture_free = B.texture_free
	function B.texture_free(id)
		if texture_free then texture_free(id) else C.lunar_ui_texture_free(id) end
	end
	function B.image_rounded(tex, x1, y1, x2, y2, col, rounding)
		C.lunar_ui_image_rounded(dl, tex, x1, y1, x2, y2, col or 0xFFFFFFFF, rounding or 0)
	end
end
function B.clip_push(x1, y1, x2, y2) C.lunar_ui_clip_push(dl, x1, y1, x2, y2) end
function B.clip_pop() C.lunar_ui_clip_pop(dl) end

--- The ImDrawList the next primitive lands on, for code that draws with cimgui directly.
function B.drawList() return dl end

return B

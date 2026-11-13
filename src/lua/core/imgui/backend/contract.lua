--- The backend contract: what `core.imgui` needs from a platform backend.
--
-- A backend is a table of functions. The runtime opens a window, runs frames (input in,
-- draw primitives out), measures text, manages textures and asks the window for a few
-- operations. Everything else is an optional capability the host uses when present.
-- `check` reports what a backend lacks; `exercise` drives a live one through the
-- contract and reports what misbehaves. spec/imgui_backend_contract_spec.lua runs both on
-- the headless backend, scripts/backend_conformance.lua on the native one; every new
-- backend (another platform, an embedding host) is held to the same checks.
--
-- Units: pixels in the window's client area, origin top left. Colours are packed
-- 0xAABBGGRR numbers (core.imgui.Color). Text sizes are em pixels (pt * dpi / 72).
--
-- @module core.imgui.backend.contract
local M = {}

--- Calls every backend provides.
M.REQUIRED = {
	-- the window and the loop
	"open",          -- open({ title, w, h, x?, y?, maximized?, borderless?, hidden? }) -> ok, err
	"close",         -- close()
	"alive",         -- alive() -> bool
	"now",           -- now() -> seconds, monotonic
	"wait",          -- wait(seconds) -> true when input woke it (false on timeout, nil: unknown)
	"frame_begin",   -- frame_begin() -> input (M.INPUT)
	"frame_end",     -- frame_end(): present what was drawn
	"window",        -- window(op, ...): M.WINDOW_REQUIRED, M.WINDOW_OPTIONAL
	-- drawing (between frame_begin and frame_end)
	"layer",         -- layer(0 main | 1 overlay)
	"rect", "rect_filled", "rect_gradient", "line", "circle", "poly",
	"text",          -- text(face, px, x, y, col, s, wrap, cx1, cy1, cx2, cy2, gid)
	"image",         -- image(tex, x1, y1, x2, y2, u1, v1, u2, v2, col)
	"clip_push", "clip_pop",
	-- text and resources
	"text_size",     -- text_size(face, px, s, wrap) -> w, h
	"font_metrics",  -- font_metrics(face, px) -> ascent, descent, height, avg_char_width
	"font_load",     -- font_load(path) -> face | nil
	"font_find",     -- font_find(name, bold, italic) -> path | nil
	"texture",       -- texture(rgba_string, w, h) -> id | nil
	"texture_free",  -- texture_free(id)
	-- system
	"cursor",        -- cursor(name)
	"clipboard_get", "clipboard_set",
	"cursor_pos",    -- cursor_pos() -> screen x, y
}

--- Optional capabilities, by group: the host uses a group only when all of it is there.
M.OPTIONAL = {
	live_resize = { "set_paint_callback" },          -- paint while the user sizes the window
	gdi_text = { "gdi_font", "gdi_metrics", "gdi_text_size" }, -- measure as IUP's Windows driver
	provider_pixels = { "texture_bits", "image_rounded" },    -- iupdrvDrawBits and rounded images
	texture_sharing = { "texture_retain" },          -- recordings keep textures alive
	dialog_windows = { "surface" },                  -- secondary dialogs as native windows
	stock_dialogs = { "file_dialog", "message_box" },
	diagnostics = { "screenshot", "memory_stats", "renderer" },
	font_listing = { "font_names" },
}

--- window(op) calls every backend answers.
M.WINDOW_REQUIRED = {
	"title", "size", "pos", "client_origin", "show", "hide", "focus", "dpi", "screen", "full",
	"maximize", "minimize", "restore", "is_maximized", "is_minimized",
}
--- window(op) calls the host uses when the backend answers them.
M.WINDOW_OPTIONAL = {
	"fullscreen", "caption", "custom_frame", "icon", "hwnd", "window_size",
	"tray", "traytip", "tray_image", "tray_balloon", "tray_balloon_title",
	"videohost_create", "videohost", "videohost_frame", "videohost_destroy",
	"popup_open", "popup_place", "popup_state", "popup_focus", "popup_hwnd", "popup_close",
}

--- The table frame_begin returns: field -> Lua type.
M.INPUT = {
	w = "number", h = "number", scale = "number", mx = "number", my = "number",
	inside = "boolean", focused = "boolean", resized = "boolean", minimized = "boolean",
	close_requested = "boolean", wheel_x = "number", wheel_y = "number",
	down = "table", pressed = "table", released = "table", double = "table",
	keys = "table", chars = "table", files = "table", mods = "table",
}
--- An event in input.events (when the backend reports ordered events): field -> type.
M.EVENT_TYPES = { move = true, press = true, release = true, wheel = true, keydown = true,
	keyup = true, char = true, leave = true, file = true, tray = true }

--- What a backend lacks. Returns missing (list of required names) and caps (group ->
-- true when the whole group is there).
function M.check(B)
	local missing = {}
	for _, name in ipairs(M.REQUIRED) do
		if type(B[name]) ~= "function" then missing[#missing + 1] = name end
	end
	local caps = {}
	for group, names in pairs(M.OPTIONAL) do
		local all = true
		for _, name in ipairs(names) do if type(B[name]) ~= "function" then all = false end end
		caps[group] = all
	end
	return missing, caps
end

--- Drive a backend through the contract (it opens and closes a window). Returns a list
-- of problems, empty when the backend conforms.
function M.exercise(B, opts)
	opts = opts or {}
	local problems = {}
	local function fail(fmt, ...) problems[#problems + 1] = string.format(fmt, ...) end
	local missing = M.check(B)
	for _, name in ipairs(missing) do fail("missing %s", name) end
	if #missing > 0 then return problems end

	local ok, err = B.open({ title = "contract", w = opts.w or 320, h = opts.h or 200, hidden = opts.hidden })
	if not ok then fail("open failed: %s", tostring(err)); return problems end
	if not B.alive() then fail("alive() is false after open") end

	local t0 = B.now()
	if type(t0) ~= "number" then fail("now() is not a number") end

	-- a frame: the input table and every primitive
	local input = B.frame_begin()
	if type(input) ~= "table" then
		fail("frame_begin() returned %s", type(input))
	else
		for field, kind in pairs(M.INPUT) do
			if type(input[field]) ~= kind then fail("input.%s is %s, not %s", field, type(input[field]), kind) end
		end
		for i, ev in ipairs(input.events or {}) do
			if not M.EVENT_TYPES[ev.type] then fail("input.events[%d].type is %s", i, tostring(ev.type)) end
		end
	end
	local white = 0xFFFFFFFF
	local calls = {
		function() B.layer(0) end,
		function() B.rect(1, 1, 20, 20, white, 0, 1, 0) end,
		function() B.rect_filled(1, 1, 20, 20, white, 4, 0) end,
		function() B.rect_gradient(1, 1, 20, 20, white, white, white, white) end,
		function() B.line(1, 1, 20, 20, white, 1) end,
		function() B.circle(10, 10, 5, white, 1, 0) end,
		function() B.poly({ 1, 1, 10, 1, 5, 8 }, white, true, 1) end,
		function() B.clip_push(0, 0, 50, 50); B.clip_pop() end,
		function() B.text(0, 13, 2, 2, white, "contract", 0, -1e9, -1e9, 1e9, 1e9, -1) end,
		function() B.layer(1); B.rect_filled(0, 0, 4, 4, white, 0, 0); B.layer(0) end,
	}
	for i, call in ipairs(calls) do
		local okc, errc = pcall(call)
		if not okc then fail("draw call %d failed: %s", i, tostring(errc)) end
	end

	-- textures: create, draw, free
	local px = string.rep("\255\0\0\255", 4 * 4)
	local tex = B.texture(px, 4, 4)
	if not tex then fail("texture() returned nil for a 4x4 image")
	else
		local okd, errd = pcall(B.image, tex, 0, 0, 4, 4, 0, 0, 1, 1, white)
		if not okd then fail("image() failed: %s", tostring(errd)) end
	end
	local okf, errf = pcall(B.frame_end)
	if not okf then fail("frame_end() failed: %s", tostring(errf)) end
	-- Layout and motion capture can issue clipping calls between frames.
	-- The native adapter must redirect them away from already rendered lists.
	local okclip, errclip = pcall(function() B.clip_push(0, 0, 8, 8); B.clip_pop() end)
	if not okclip then fail("between-frame clipping failed: %s", tostring(errclip)) end
	if tex then
		local okt, errt = pcall(B.texture_free, tex)
		if not okt then fail("texture_free() failed: %s", tostring(errt)) end
	end

	-- text measuring: positive, and wider for a longer string and a bigger size
	local w1, h1 = B.text_size(0, 13, "abc", 0)
	local w2 = B.text_size(0, 13, "abcabc", 0)
	local w3 = B.text_size(0, 26, "abc", 0)
	if not (type(w1) == "number" and w1 > 0 and type(h1) == "number" and h1 > 0) then
		fail("text_size(abc) = %s, %s", tostring(w1), tostring(h1))
	elseif not (w2 > w1 and w3 > w1) then
		fail("text_size does not grow with length and size (%s, %s, %s)", tostring(w1), tostring(w2), tostring(w3))
	end
	local asc, desc, height = B.font_metrics(0, 13)
	if not (type(height) == "number" and height > 0 and type(asc) == "number") then
		fail("font_metrics(0, 13) = %s, %s, %s", tostring(asc), tostring(desc), tostring(height))
	end

	-- the clipboard round-trips text with line breaks
	if not opts.skip_clipboard then
		local saved = B.clipboard_get()
		B.clipboard_set("contract\nline two")
		local got = B.clipboard_get()
		if got ~= "contract\nline two" then fail("clipboard round trip gave %q", tostring(got)) end
		if saved then B.clipboard_set(saved) end
	end

	-- the required window operations answer
	for _, op in ipairs(M.WINDOW_REQUIRED) do
		local okw, errw = pcall(B.window, op)
		if not okw then fail("window(%q) failed: %s", op, tostring(errw)) end
	end
	B.window("title", "contract renamed")
	if B.window("title") ~= "contract renamed" then fail("window title does not round-trip") end
	local sw, sh = B.window("size")
	if not (type(sw) == "number" and sw > 0 and type(sh) == "number" and sh > 0) then
		fail("window('size') = %s, %s", tostring(sw), tostring(sh))
	end
	local dpi = B.window("dpi")
	if not (type(dpi) == "number" and dpi > 0) then fail("window('dpi') = %s", tostring(dpi)) end

	B.close()
	if B.alive() then fail("alive() is true after close") end
	return problems
end

return M

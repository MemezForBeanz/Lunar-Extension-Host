--- A backend with no window: the same calls as the native one, recorded in memory.
--
-- The busted suite drives the whole ImGui host through this: it queues input frames,
-- advances a fake clock, and reads back the draw calls a frame produced. Text metrics
-- are deterministic: every character is `px / 2` wide and a line is `ceil(px * 1.25)`
-- tall, so layouts can be asserted to the pixel.
--
-- @module core.imgui.backend.Null
local M = {}

function M.new(opts)
	opts = opts or {}
	local B = {
		name = "null",
		w = opts.w or 1280, h = opts.h or 800,
		clock = 0, open_ = false, frames = 0,
		calls = {}, frame_calls = {}, inputs = {},
		mx = -1, my = -1, down = { false, false, false },
		clipboard = "", cursor_name = "ARROW", title = nil,
		maximized = false, minimized = false, x = 100, y = 100,
		textures = {}, next_tex = 1, fonts = { [0] = "default" }, next_font = 1,
		file_dialog_result = nil, message_boxes = {},
		dpi_scale = opts.scale or 1,
	}

	local function record(op, ...)
		local c = { op, ... }
		B.frame_calls[#B.frame_calls + 1] = c
	end

	function B.open(o)
		o = o or {}
		B.open_ = true
		B.title = o.title
		if o.w then B.w = o.w end
		if o.h then B.h = o.h end
		if o.x then B.x = o.x end
		if o.y then B.y = o.y end
		B.maximized = o.maximized and true or false
		return true
	end
	function B.close() B.open_ = false end
	function B.alive() return B.open_ end
	function B.now() return B.clock end
	function B.wait(t) B.clock = B.clock + math.max(0, math.min(t or 0, 1)) end
	function B.advance(dt) B.clock = B.clock + dt end

	--- Queue an input frame: { mx, my, press = 1, release = 1, wheel = -1, keys = {...},
	-- chars = {...}, w, h, close_requested }. Unset fields keep the last state.
	function B.queue(input) B.inputs[#B.inputs + 1] = input end

	function B.frame_begin()
		B.frames = B.frames + 1
		B.calls = B.frame_calls
		B.frame_calls = {}
		local q = table.remove(B.inputs, 1) or {}
		if q.w then B.w = q.w end
		if q.h then B.h = q.h end
		if q.mx then B.mx = q.mx end
		if q.my then B.my = q.my end
		local pressed, released, double = {}, {}, {}
		for b = 1, 3 do pressed[b], released[b], double[b] = 0, 0, 0 end
		if q.press then pressed[q.press] = 1; B.down[q.press] = true end
		if q.release then released[q.release] = 1; B.down[q.release] = false end
		if q.double then double[q.double] = 1; pressed[q.double] = 1 end
		local mods = q.mods or {}
		return {
			w = B.w, h = B.h, scale = B.dpi_scale,
			mx = B.mx, my = B.my, inside = B.mx >= 0,
			down = { B.down[1], B.down[2], B.down[3] },
			pressed = pressed, released = released, double = double,
			wheel_x = q.wheel_x or 0, wheel_y = q.wheel or 0,
			keys = q.keys or {}, chars = q.chars or {},
			mods = { shift = mods.shift or false, ctrl = mods.ctrl or false, alt = mods.alt or false, sys = mods.sys or false },
			focused = true, resized = q.w ~= nil, close_requested = q.close_requested or false,
			files = q.files or {},
			-- Ordered events, as the native backend reports them: { type = "move"|"press"|
			-- "release"|"wheel"|"leave"|"keydown"|"char", x, y, button, double, dx, dy, code,
			-- char, mods = { shift, ctrl, alt, sys, b1, b2, b3 } }.
			events = q.events and B._events(q.events) or nil,
		}
	end

	-- Fill in what a queued event leaves out: the last pointer position and plain mods.
	function B._events(list)
		local out = {}
		for i, e in ipairs(list) do
			local ev = {}
			for k, v in pairs(e) do ev[k] = v end
			ev.x = ev.x or B.mx
			ev.y = ev.y or B.my
			ev.dx, ev.dy = ev.dx or 0, ev.dy or 0
			ev.mods = ev.mods or { shift = false, ctrl = false, alt = false, sys = false,
				b1 = ev.type == "press" and ev.button == 1, b2 = false, b3 = false }
			if ev.type ~= "leave" and ev.type ~= "keydown" and ev.type ~= "char" then B.mx, B.my = ev.x, ev.y end
			out[i] = ev
		end
		return out
	end

	function B.frame_end() B.last = B.frame_calls end

	--- The calls of the frame that was last ended.
	function B.lastFrame() return B.last or {} end

	function B.rect(...) record("rect", ...) end
	function B.rect_filled(...) record("rect_filled", ...) end
	function B.rect_gradient(...) record("rect_gradient", ...) end
	function B.line(...) record("line", ...) end
	function B.circle(...) record("circle", ...) end
	function B.poly(...) record("poly", ...) end
	function B.text(...) record("text", ...) end
	function B.image(...) record("image", ...) end
	function B.clip_push(...) record("clip_push", ...) end
	function B.clip_pop(...) record("clip_pop", ...) end
	function B.layer(...) record("layer", ...) end

	local function utf8len(s)
		local _, n = s:gsub("[^\128-\191]", "")
		return n
	end

	function B.text_size(font, px, str, wrap)
		local w, lines = 0, 0
		for line in (str .. "\n"):gmatch("(.-)\n") do
			lines = lines + 1
			w = math.max(w, utf8len(line) * px / 2)
		end
		if wrap and wrap > 0 and w > wrap then
			lines = lines + math.floor(w / wrap)
			w = wrap
		end
		return w, math.ceil(px * 1.25) * math.max(1, lines)
	end

	function B.font_metrics(font, px)
		return px, math.ceil(px * 1.25) - px, math.ceil(px * 1.25), px / 2
	end

	function B.font_load(path)
		local id = B.next_font
		B.next_font = id + 1
		B.fonts[id] = path
		return id
	end

	function B.font_find(face, bold, italic)
		return (face or "default") .. (bold and "-bold" or "") .. (italic and "-italic" or "") .. ".ttf"
	end

	--- Name tables of fake font files: B.font_name_tables[path] = { [1]=family, [2]=sub, [4]=full }
	B.font_name_tables = {}
	function B.font_names(path) return B.font_name_tables[path] end

	function B.texture(rgba, w, h)
		local id = B.next_tex
		B.next_tex = id + 1
		B.textures[id] = { w = w, h = h, bytes = type(rgba) == "string" and #rgba or 0 }
		return id
	end
	function B.texture_free(id) B.textures[id] = nil end

	function B.cursor(name) B.cursor_name = name end
	function B.clipboard_get() return B.clipboard end
	function B.clipboard_set(s) B.clipboard = s end
	function B.cursor_pos() return B.x + math.max(0, B.mx), B.y + math.max(0, B.my) end

	function B.window(op, a, b, c, d)
		if op == "title" then if a ~= nil then B.title = a end return B.title
		elseif op == "size" then if a then B.w, B.h = a, b end return B.w, B.h
		elseif op == "pos" then if a then B.x, B.y = a, b end return B.x, B.y
		elseif op == "client_origin" then return B.x, B.y
		elseif op == "maximize" then B.maximized = true; B.minimized = false
		elseif op == "minimize" then B.minimized = true
		elseif op == "restore" then B.maximized = false; B.minimized = false
		elseif op == "is_maximized" then return B.maximized
		elseif op == "is_minimized" then return B.minimized
		elseif op == "fullscreen" then B.fullscreen = a and true or false
		elseif op == "show" then B.visible = true
		elseif op == "hide" then B.visible = false
		elseif op == "focus" then return true
		elseif op == "hwnd" then return 0
		elseif op == "caption" then B.caption = { a, b }
		elseif op == "screen" then return 1920, 1040
		elseif op == "full" then return 1920, 1080
		elseif op == "dpi" then return B.dpi_scale
		elseif op == "icon" then B.icon = { a, b, c }
		end
		return nil
	end

	function B.file_dialog(o)
		B.last_file_dialog = o
		return B.file_dialog_result
	end

	function B.message_box(title, text, kind)
		B.message_boxes[#B.message_boxes + 1] = { title, text, kind }
		return 1
	end

	--- Every text string drawn in the last frame, in order (handy in tests).
	function B.texts()
		local out = {}
		for _, c in ipairs(B.last or {}) do
			if c[1] == "text" then out[#out + 1] = c[7] end
		end
		return out
	end

	return B
end

return M

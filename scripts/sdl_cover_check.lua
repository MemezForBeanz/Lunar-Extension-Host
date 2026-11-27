-- scripts/sdl_cover_check.lua -- the direct-draw floor's whole-or-hidden body on a live host.
--   lunar scripts/sdl_cover_check.lua [log]
--   luajit scripts/sdl_cover_check.lua --null [log]   (the headless backend, no window)
-- With no scene target (the SDL/OpenGL host), core.ui.Background draws its layers straight
-- onto the main ImDrawList and recolours a `whole` body's vertices when the layout over it
-- changes (Background.cover). This opens a window, turns the scene target off, and steps a
-- panel over the body: clear, partial, partial, clear, partial; then a pushed signal moves
-- the body across a panel's edge and back. After each present it reads the body's vertices
-- back from the list that was rendered: there must be 4 every time (a hidden body keeps
-- them), where the floor drew it, at alpha 0 while partly covered and 255 while clear, set
-- on the present that found the change. Exits non-zero on any miss, including a host whose
-- executable lacks lunar_ui_vtx_count / lunar_ui_vtx_color. Run it off-screen (xvfb).
do
	local here = debug.getinfo(1, "S").source:gsub("^@", ""):gsub("\\", "/")
	local root = here:match("^(.*)/scripts/[^/]+$") or (here:match("^scripts/[^/]+$") and ".")
	if root and root ~= "" then
		local mine = root .. "/src/lua/?.lua;" .. root .. "/src/lua/?/init.lua"
		table.insert(package.loaders, 2, function(name)
			local file = package.searchpath(name, mine)
			if not file then return nil end
			return assert(loadfile(file))
		end)
	end
end

local null = arg[1] == "--null"
local log_path = arg[null and 2 or 1]
local lines = {}
local function say(s)
	lines[#lines + 1] = s
	print(s)
	if log_path then
		local fh = io.open(log_path, "w")
		if fh then fh:write(table.concat(lines, "\n"), "\n"); fh:close() end
	end
end

-- the scene's clock, the pointer and wakes, without the runtime (no UI tree here)
local clock = 10
package.loaded["core.imgui.Runtime"] = {
	now = function() return clock end,
	pointer = function() return -1, -1, false end,
	wakeAt = function() end, animate = function() end,
}

local B, ffi
local ok, err = xpcall(function()
	if null then
		B = require("core.imgui.backend.Null").new()
	else
		ffi = require("ffi")
		B = require("core.imgui.backend.Native")
		assert(B.ffi, "the native backend is not on LuaJIT's FFI (an executable without its exports)")
		-- the two exports the direct-draw floor needs, resolved by name: a host that lacks
		-- them would silently draw a hidden body that can never be shown again
		pcall(ffi.cdef, "int lunar_ui_vtx_count(ImDrawList *dl); void lunar_ui_vtx_color(ImDrawList *dl, int from, int to, uint32_t col);")
		for _, name in ipairs({ "lunar_ui_vtx_count", "lunar_ui_vtx_color" }) do
			local found, why = pcall(function() return ffi.C[name] end)
			assert(found, "LuaJIT cannot resolve " .. name .. " in this executable: " .. tostring(why))
		end
		assert(B.vtx_mark and B.vtx_color, "core.imgui.backend.Native did not bind vtx_mark / vtx_color")
		require("core.imgui.cimgui")   -- ImDrawList's layout, checked against the executable
		assert(B.open({ title = "Lunar cover check", w = 800, h = 600 }))
	end
	-- no scene target: the floor draws onto the main list
	B.scene_begin, B.scene_present, B.scene_valid = nil, nil, nil
	say(string.format("backend %s  renderer %s  scene target off  vtx bindings %s", null and "Null" or "native",
		B.renderer and tostring((B.renderer() or {}).active) or "-", B.vtx_mark and "yes" or "NO"))

	local Reactor = require("core.ui.ThemeReactor")
	Reactor.themeManager = function() return nil end   -- motion off: each change is instant
	Reactor.palette = function() return nil end
	local Scene = require("core.ui.Background")
	Scene._svg_pixels = function(_, w, h) return string.rep("\255", w * h * 4), w, h end
	local Draw = require("core.imgui.Draw")
	local dc = Draw.new(B)

	-- a 100 px red body centred at (400, 300) on a dark sky; `fullscreen` moves it to x 600
	local p = { background = { id = "sdl-cover-check", layers = {
		{ kind = "fill", top = "#000010", bottom = "#000020" },
		{ svg = "<svg/>", size = 100, unit = "px", x = { signal = "fullscreen", from = 400, to = 600 }, y = 300,
			tint = "#FF2020", whole = true },
	} } }
	local CUT = { 420, 200, 200, 200 }    -- x, y, w, h: over the body's right part at 350..450
	local EDGE = { 600, 0, 200, 600 }     -- from x 600: clear of it at 350..450, cuts it at 550..650
	Scene.set("fullscreen", 0)

	-- the body's sprite this frame: its list and vertex range [from, to)
	local body
	local image = B.image
	B.image = function(tex, x1, y1, x2, y2, ...)
		local is = math.abs(x2 - x1 - 100) < 0.5 and math.abs(y1 - 250) < 0.5 and math.abs(y2 - 350) < 0.5
		local list, from
		if is then list, from = B.vtx_mark() end
		image(tex, x1, y1, x2, y2, ...)
		if is then
			local _, to = B.vtx_mark()
			body = { list = list, from = from, to = to }
		end
	end
	-- [from, to) on `list` now: the vertex count, the one alpha they share (-1 when they
	-- differ) and their left edge
	local function alphas(list, from, to)
		local alpha, left
		if null then
			local n = 0
			for i = from + 1, to do
				local c = list[i]
				if c and c[1] == "image" then
					n = n + 1
					local a = math.floor(c[11] / 16777216) % 256
					if alpha == nil then alpha = a elseif alpha ~= a then alpha = -1 end
					left = math.min(left or c[3], c[3])
				end
			end
			return n * 4, alpha, left
		end
		local l = ffi.cast("ImDrawList *", list)
		assert(to <= l.VtxBuffer.Size, "the body's vertices are past the list's end")
		for i = from, to - 1 do
			local v = l.VtxBuffer.Data[i]
			local a = math.floor(v.col / 16777216) % 256
			if alpha == nil then alpha = a elseif alpha ~= a then alpha = -1 end
			left = math.min(left or v.pos.x, v.pos.x)
		end
		return to - from, alpha, left
	end

	local pass = true
	local W, H = 800, 600
	local function step(tag, panel, want, at)
		at = at or 350
		clock = clock + 0.02
		body = nil
		local f = B.frame_begin()
		if f and f.w and f.w > 0 then W, H = f.w, f.h end
		dc:begin(W, H)
		Scene.floor(dc, 0, 0, W, H, p, false)
		if panel then dc:fill(panel[1], panel[2], panel[3], panel[4], "#304050") end
		Scene.cover(dc.cover)
		B.frame_end()
		-- read after the present: what the renderer drew from
		local state = Scene.coverState(2)
		local n, alpha, left = 0, nil, nil
		if body then n, alpha, left = alphas(body.list, body.from, body.to) end
		local want_a = want == "partial" and 0 or 255
		local good = state == want and n == 4 and alpha == want_a and left and math.abs(left - at) < 0.5
		say(string.format("%-18s coverage %-8s (want %-7s)  vertices %d (want 4) from x %s (want %d)  alpha %s (want %d)  %s",
			tag, tostring(state), want, n, tostring(left), at, tostring(alpha), want_a, good and "ok" or "MISS"))
		if not good then pass = false end
		if not null and B.wait then B.wait(0.01) end
	end
	-- a first frame lays the scene out and uploads its textures
	step("first-clear", nil, "clear")
	step("partial", CUT, "partial")
	step("partial-again", CUT, "partial")   -- emitted hidden from the start, vertices kept
	step("clear", nil, "clear")             -- shown on this present
	step("partial-last", CUT, "partial")
	-- the signal moves it: tested where it is drawn
	step("edge-clear", EDGE, "clear")
	Scene.set("fullscreen", 1)
	step("moved-partial", EDGE, "partial", 550)
	Scene.set("fullscreen", 0)
	step("moved-back-clear", EDGE, "clear")
	assert(W >= 600 and H >= 400, "window too small for the check: " .. W .. "x" .. H)
	assert(pass, "the direct-draw body missed its vertices or alpha on a present (see above)")
end, debug.traceback)
if B and not null and B.close then pcall(B.close) end
if not ok then
	say("FAIL: " .. tostring(err))
	os.exit(1)
end
say("PASS: the direct-draw body keeps its vertices and takes its alpha on the present that finds the change")
os.exit(0)

-- scripts/flat_grid_check.lua: acceptance for media_native, IupFlatGrid, IupFlatRows and
-- IupFlatSeek in a real window, with real input messages and measured frame times.
--
-- Run on a private desktop: its windows must not reach anyone's screen.
--   Lunar scripts/flat_grid_check.lua [capture_dir] [image_dir]
-- capture_dir receives BMP shots. image_dir, if given, adds every .jpg and .png in it as real
-- decoder input, listed in image_dir/list.txt.
--
-- Frame times on a private desktop differ from a real one. Compare runs only on the same kind.

local iup = require("iup")
local ffi = require("ffi")
local CellGrid = require("core.ui.CellGrid")
local PosterCache = require("core.ui.PosterCache")
local RowList = require("core.ui.RowList")
local SeekBar = require("core.ui.SeekBar")

local capture_dir, image_dir = arg and arg[1], arg and arg[2]

ffi.cdef[[
int QueryPerformanceCounter(int64_t*);
int QueryPerformanceFrequency(int64_t*);
int PostMessageA(void*, unsigned, uintptr_t, intptr_t);
typedef struct { long left, top, right, bottom; } FGC_RECT;
int GetWindowRect(void*, FGC_RECT*);
int PrintWindow(void*, void*, unsigned);
void* GetDC(void*); int ReleaseDC(void*, void*);
void* CreateCompatibleDC(void*); void* CreateCompatibleBitmap(void*, int, int);
void* SelectObject(void*, void*); int DeleteObject(void*); int DeleteDC(void*);
typedef struct { uint32_t biSize; long biWidth, biHeight; uint16_t biPlanes, biBitCount;
  uint32_t biCompression, biSizeImage; long a, b; uint32_t c, d; } FGC_BMIH;
int GetDIBits(void*, void*, unsigned, unsigned, void*, FGC_BMIH*, unsigned);
int GetCurrentProcessId(void);
]]
local user32, gdi32 = ffi.load("user32"), ffi.load("gdi32")
local frequency = ffi.new("int64_t[1]")
ffi.C.QueryPerformanceFrequency(frequency)
local counter = ffi.new("int64_t[1]")
local function now_ms()
	ffi.C.QueryPerformanceCounter(counter)
	return tonumber(counter[0]) * 1000 / tonumber(frequency[0])
end

local failures = 0
local function line(text) io.stdout:write(text, "\n"); io.stdout:flush() end
local function report(name, pass, detail)
	if not pass then failures = failures + 1 end
	line(string.format("[%s] %s%s", pass and "PASS" or "FAIL", name, detail and (" -- " .. tostring(detail)) or ""))
end
local function pump(ms)
	local stop = now_ms() + (ms or 0)
	repeat
		for _ = 1, 32 do iup.LoopStep() end
	until now_ms() >= stop
end

local function hwnd(widget) return ffi.cast("void*", iup.GetAttribute(widget, "HWND")) end
local function post(widget, msg, wparam, lparam)
	user32.PostMessageA(hwnd(widget), msg, wparam or 0, lparam or 0)
	pump(0)
end
local function point(x, y) return y * 65536 + x end
local WM = { KEYDOWN = 0x100, MOUSEMOVE = 0x200, LBUTTONDOWN = 0x201, LBUTTONUP = 0x202, RBUTTONDOWN = 0x204,
	LBUTTONDBLCLK = 0x203, MOUSEWHEEL = 0x20A, MOUSELEAVE = 0x2A3 }
local VK = { LEFT = 0x25, UP = 0x26, RIGHT = 0x27, DOWN = 0x28, PRIOR = 0x21, NEXT = 0x22, END = 0x23, HOME = 0x24, RETURN = 0x0D }
local function key(widget, code) post(widget, WM.KEYDOWN, code, 1) end

local function shot(dialog, name)
	if not capture_dir then return end
	local window = hwnd(dialog)
	local rect = ffi.new("FGC_RECT")
	user32.GetWindowRect(window, rect)
	local w, h = rect.right - rect.left, rect.bottom - rect.top
	local screen = user32.GetDC(window)
	local mem = gdi32.CreateCompatibleDC(screen)
	local bitmap = gdi32.CreateCompatibleBitmap(screen, w, h)
	local previous = gdi32.SelectObject(mem, bitmap)
	user32.PrintWindow(window, mem, 2)
	local info = ffi.new("FGC_BMIH")
	info.biSize, info.biWidth, info.biHeight, info.biPlanes, info.biBitCount = ffi.sizeof(info), w, -h, 1, 32
	local size = w * h * 4
	local pixels = ffi.new("uint8_t[?]", size)
	gdi32.GetDIBits(mem, bitmap, 0, h, pixels, info, 0)
	local file = assert(io.open(capture_dir .. "/" .. name .. ".bmp", "wb"))
	local head = ffi.new("uint8_t[14]")
	head[0], head[1] = 0x42, 0x4D
	ffi.cast("uint32_t*", head + 2)[0] = 54 + size
	ffi.cast("uint32_t*", head + 10)[0] = 54
	file:write(ffi.string(head, 14), ffi.string(info, 40), ffi.string(pixels, size))
	file:close()
	gdi32.SelectObject(mem, previous)
	gdi32.DeleteObject(bitmap)
	gdi32.DeleteDC(mem)
	user32.ReleaseDC(window, screen)
end

-- A 32-bit BMP of a diagonal gradient, with a solid red band in the middle third, as bytes.
local function bmp_bytes(w, h, seed)
	local size = w * h * 4
	local out = ffi.new("uint8_t[?]", size)
	for y = 0, h - 1 do
		for x = 0, w - 1 do
			local at = ((h - 1 - y) * w + x) * 4
			local band = y >= h / 3 and y < h * 2 / 3
			out[at] = band and 0 or (x * 200 / w + seed * 37) % 256
			out[at + 1] = band and 0 or (y * 200 / h + seed * 91) % 256
			out[at + 2] = band and 255 or (seed * 53) % 256
			out[at + 3] = 255
		end
	end
	local head = ffi.new("uint8_t[54]")
	head[0], head[1] = 0x42, 0x4D
	ffi.cast("uint32_t*", head + 2)[0] = 54 + size
	ffi.cast("uint32_t*", head + 10)[0] = 54
	local info = ffi.cast("int32_t*", head + 14)
	info[0], info[1], info[2] = 40, w, h
	ffi.cast("uint16_t*", head + 26)[0] = 1
	ffi.cast("uint16_t*", head + 28)[0] = 32
	return ffi.string(head, 54) .. ffi.string(out, size)
end

local function wait_for(cache, keys, limit_ms)
	local stop = now_ms() + (limit_ms or 8000)
	local missing = {}
	for _, k in ipairs(keys) do missing[k] = true end
	while next(missing) and now_ms() < stop do
		for _, k in ipairs(cache:drain()) do missing[k] = nil end
	end
	return next(missing) == nil
end

---------------------------------------------------------------------------------------------
line("-- media_native")
local cache = assert(PosterCache.new({ max_mb = 128 }))

local temp = (os.getenv("TEMP") or ".") .. "/lunar_flat_grid_check_" .. ffi.C.GetCurrentProcessId() .. ".bmp"
do
	local file = assert(io.open(temp, "wb"))
	file:write(bmp_bytes(300, 600, 1))
	file:close()
end
report("queues a new key", cache:request("file@100x150", temp, 100, 150) == true)
report("refuses a key it already has", cache:request("file@100x150", temp, 100, 150) == false)
report("a queued key has no pixels yet", cache:status("file@100x150") == "queued" and cache:get("file@100x150") == nil)
cache:requestBytes("mem@100x150", bmp_bytes(600, 300, 2), 100, 150)
cache:request("missing@10x10", "Z:/no/such/file.png", 10, 10)
cache:requestBytes("junk@10x10", "this is not an image", 10, 10)
report("finished work arrives", wait_for(cache, { "file@100x150", "mem@100x150", "missing@10x10", "junk@10x10" }))
do
	local pixels, stride, w, h = cache:get("file@100x150")
	report("file decoded to exact cell size", pixels ~= nil and w == 100 and h == 150 and stride == 400)
	local bytes = ffi.cast("uint8_t*", pixels)
	local middle = bytes + 75 * stride + 50 * 4
	report("pixels are BGRA, top row first", middle[2] > 240 and middle[0] < 16, string.format("middle %d %d %d", middle[0], middle[1], middle[2]))
	local wide, _, ww, wh = cache:get("mem@100x150")
	report("a wide source covers a tall cell", wide ~= nil and ww == 100 and wh == 150)
	report("a missing file fails, with a reason", cache:status("missing@10x10") == "failed", select(2, cache:status("missing@10x10")))
	report("bad bytes fail, with a reason", cache:status("junk@10x10") == "failed", select(2, cache:status("junk@10x10")))
	cache:forget("missing@10x10")
	report("forget allows another try", cache:status("missing@10x10") == nil)
end
os.remove(temp)

if image_dir then
	local list = io.open(image_dir .. "/list.txt", "r")
	if list then
		local keys = {}
		for name in list:lines() do
			name = name:gsub("%s+$", "")
			if name ~= "" then
				keys[#keys + 1] = name
				cache:request(name, image_dir .. "/" .. name, 150, 225)
			end
		end
		list:close()
		report("real files decode", wait_for(cache, keys), #keys .. " files")
		for _, name in ipairs(keys) do
			report("decoded " .. name, cache:status(name) == "ready", select(2, cache:status(name)))
		end
	end
end

do
	local small = assert(PosterCache.new({ max_mb = 1, threads = 2 }))
	local keys, data = {}, bmp_bytes(64, 96, 3)
	for i = 1, 40 do
		keys[i] = "lru" .. i
		small:requestBytes(keys[i], data, 200, 300)
		if i % 8 == 0 then wait_for(small, { keys[i] }) end
	end
	wait_for(small, keys)
	local stats = small:stats()
	report("the cache stays inside its budget", stats.used_bytes <= stats.max_bytes and stats.evicted > 0,
		string.format("%d bytes of %d, %d evicted", stats.used_bytes, stats.max_bytes, stats.evicted))
	small:clear()
	report("clear empties it", small:stats().entries == 0 and small:stats().used_bytes == 0)
	for i = 1, 500 do small:requestBytes("q" .. i, data, 64, 96) end
	report("the queue is bounded", small:stats().queued <= 256, small:stats().queued)
	local t0 = now_ms()
	small:close()
	report("close stops workers with work queued", now_ms() - t0 < 2000, string.format("%.1f ms", now_ms() - t0))
	small:close()
	report("close is safe twice, and later calls fail cleanly", pcall(small.stats, small) == false)
end

---------------------------------------------------------------------------------------------
line("-- IupFlatGrid")
local COUNT = 100000
local value_calls, bit_calls = 0, 0
local selected_cb, activated_cb, activated_how, context_cb, change_cb = 0, 0, nil, 0, 0
local fields = {
	TITLE = function(pos) return "Film number " .. pos end,
	SECONDARY = function(pos) return (1950 + pos % 75) .. " - " .. (80 + pos % 100) .. " min" end,
	BADGE = function(pos) return pos % 7 == 0 and "4K" or (pos % 5 == 0 and "HDR" or nil) end,
	PROGRESS = function(pos) return pos % 3 == 0 and (pos * 7) % 100 or nil end,
	STATE = function(pos) return pos % 4 == 0 and "unplayed" or (pos % 11 == 0 and "offline" or nil) end,
}
local grid = CellGrid.new(iup, {
	count = COUNT,
	cell_width = 150,
	value = function(pos, field) value_calls = value_calls + 1; return fields[field](pos) end,
	on_select = function(pos) selected_cb = pos end,
	on_activate = function(pos, how) activated_cb, activated_how = pos, how end,
	on_context = function(pos) context_cb = pos end,
	on_change = function() change_cb = change_cb + 1 end,
})
-- LUNAR_CHECK_THEME names a theme class, such as LunarDarkTheme, to use its real rules.
local theme_rules
do
	local theme_name = os.getenv("LUNAR_CHECK_THEME")
	if theme_name and theme_name ~= "" then
		theme_rules = require("core.classes.Themes." .. theme_name):new():rules()
	end
end
local ThemeManager = require("core.classes.ThemeManager")
local function style(widget, colours, class)
	local attrs = colours
	if theme_rules and class then attrs = ThemeManager._attrsFromRule({}, class, theme_rules[class]) end
	for name, value in pairs(attrs) do iup.SetAttribute(widget, name, value) end
end
local theme = { BGCOLOR = "22 24 28", FGCOLOR = "232 234 238", SECONDARYCOLOR = "150 156 166", PLACEHOLDERCOLOR = "38 41 47",
	HLCOLOR = "90 96 106", ITEMMARKERCOLOR = "96 165 250", FONT = "Segoe UI, 10", SCROLLBARSIZE = "8", SHOWARROWS = "NO",
	SB_CORNERRADIUS = "4", SB_FORECOLOR = "90 96 106" }
style(grid.widget, theme, "flatgrid")

local shared = {}
for i = 1, 240 do shared[i] = "poster" .. i end
local poster_data = {}
for i = 1, 12 do poster_data[i] = bmp_bytes(200, 300, i) end
local poster_source = function(pos)
	local i = (pos - 1) % 240 + 1
	return { bytes = poster_data[(i - 1) % 12 + 1], id = shared[i] }
end
local drain = CellGrid.posters(grid, cache, poster_source)
local inner_bits = grid.bits
grid.bits = function(pos, w, h) bit_calls = bit_calls + 1; return inner_bits(pos, w, h) end

local dlg = iup.dialog({ grid.widget, rastersize = "1280x800", title = "grid check" })
dlg:showxy(iup.CENTER, iup.CENTER)
iup.SetFocus(grid.widget)
pump(200)

report("a hundred thousand items are mapped", tonumber(iup.GetAttribute(grid.widget, "COUNT")) == COUNT)
local first, last = grid:visibleRange()
report("only a screenful is in view", first == 1 and last < 100, first .. ":" .. last)
do
	-- Fill the cache: the visible range decodes, and each arrival repaints one cell.
	local stop = now_ms() + 6000
	repeat
		drain()
		pump(5)
	until (now_ms() > stop) or cache:stats().queued == 0 and cache:get("poster1@150x225") ~= nil and cache:get("poster" .. last .. "@150x225") ~= nil
	drain()
	pump(50)
	shot(dlg, "grid-top")
end

local function percentile(sorted, p) return sorted[math.max(1, math.ceil(#sorted * p))] end
local function frame_report(name, times, budget)
	table.sort(times)
	local total = 0
	for _, t in ipairs(times) do total = total + t end
	local p99 = percentile(times, 0.99)
	report(name, p99 < budget, string.format("%d frames, mean %.2f, p50 %.2f, p95 %.2f, p99 %.2f, max %.2f ms",
		#times, total / #times, percentile(times, 0.5), percentile(times, 0.95), p99, times[#times]))
end

-- Warm: 240 posters repeat through the whole list, so every frame is cache hits.
for i = 1, 240 do
	local poster = "poster" .. i .. "@150x225"
	if not cache:get(poster) then cache:requestBytes(poster, poster_data[(i - 1) % 12 + 1], 150, 225) end
end
do
	local keys = {}
	for i = 1, 240 do keys[i] = "poster" .. i .. "@150x225" end
	wait_for(cache, keys, 15000)
end

local ymax = tonumber(iup.GetAttribute(grid.widget, "YMAX"))
do
	local times = {}
	value_calls, bit_calls = 0, 0
	for i = 1, 1200 do
		iup.SetAttribute(grid.widget, "POSY", tostring(math.floor((i * 2477) % ymax)))
		local t0 = now_ms()
		iup.Redraw(grid.widget, 0)
		times[i] = now_ms() - t0
	end
	frame_report("jumps across the whole list, full paint each", times, 16.7)
	line(string.format("[info] %.1f cells a frame, %.1f value calls a frame", bit_calls / 1200, value_calls / 1200))
	report("no frame touches more than the cells in view", bit_calls / 1200 < 40)
end
do
	local times, position = {}, 0
	iup.SetAttribute(grid.widget, "POSY", "0")
	for i = 1, 1200 do
		position = position + 37
		iup.SetAttribute(grid.widget, "POSY", tostring(position))
		local t0 = now_ms()
		iup.Redraw(grid.widget, 0)
		times[i] = now_ms() - t0
	end
	frame_report("smooth scroll at 37 px a frame", times, 16.7)
end
do
	local times = {}
	iup.SetAttribute(grid.widget, "POSY", "0")
	iup.Redraw(grid.widget, 0)
	for i = 1, 400 do
		local t0 = now_ms()
		post(grid.widget, WM.MOUSEWHEEL, 0xFF880000, point(600, 400))
		pump(0)
		times[i] = now_ms() - t0
	end
	report("the wheel scrolls", tonumber(iup.GetAttribute(grid.widget, "POSY")) > 0, iup.GetAttribute(grid.widget, "POSY"))
	frame_report("wheel messages through the real path", times, 16.7)
end
do
	-- Cold: every cell is a new key, so each frame queues decodes while the list flies past.
	local cold = assert(PosterCache.new({ max_mb = 64 }))
	local cold_drain = CellGrid.posters(grid, cold, function(pos)
		return { bytes = poster_data[(pos - 1) % 12 + 1], id = "cold" .. pos }
	end)
	local times = {}
	for i = 1, 600 do
		iup.SetAttribute(grid.widget, "POSY", tostring(math.floor((i * 90019) % ymax)))
		local t0 = now_ms()
		iup.Redraw(grid.widget, 0)
		cold_drain()
		times[i] = now_ms() - t0
	end
	frame_report("fling over undecoded posters, decoding behind", times, 16.7)
	local stats = cold:stats()
	report("the cold cache stayed in budget", stats.used_bytes <= stats.max_bytes, string.format("%.1f MB, %d queued", stats.used_bytes / 1048576, stats.queued))
	cold:close()
	drain = CellGrid.posters(grid, cache, poster_source)
	inner_bits = grid.bits
	grid.bits = function(pos, w, h) bit_calls = bit_calls + 1; return inner_bits(pos, w, h) end
	drain()
end

iup.SetAttribute(grid.widget, "POSY", "0")
iup.Redraw(grid.widget, 0)
pump(30)
do
	grid:scrollTo(5000)
	pump(30)
	first, last = grid:visibleRange()
	report("scrollTo brings a cell into view", first <= 5000 and last >= 5000, first .. ":" .. last)
	dlg.rastersize = "860x640"
	iup.Refresh(dlg)
	pump(60)
	first, last = grid:visibleRange()
	report("a resize keeps the place", first <= 5000 and last >= 5000, first .. ":" .. last)
	dlg.rastersize = "1280x800"
	iup.Refresh(dlg)
	iup.SetAttribute(grid.widget, "POSY", "0")
	iup.Redraw(grid.widget, 0)
	pump(60)
end
local lanes
do
	-- The second cell of the top line, to read the lane count from the first press of Down.
	post(grid.widget, WM.LBUTTONDOWN, 1, point(30, 30))
	post(grid.widget, WM.LBUTTONUP, 0, point(30, 30))
	report("a click selects a cell", grid:selected() == 1 and selected_cb == 1, grid:selected())
	key(grid.widget, VK.DOWN)
	lanes = grid:selected() - 1
	report("Down moves one whole line", lanes > 1, "lanes " .. lanes)
	key(grid.widget, VK.RIGHT)
	report("Right moves one cell", grid:selected() == lanes + 2, grid:selected())
	key(grid.widget, VK.UP)
	report("Up moves one whole line back", grid:selected() == 2, grid:selected())
	key(grid.widget, VK.UP)
	report("Up on the top line stays", grid:selected() == 2, grid:selected())
	key(grid.widget, VK.NEXT)
	local paged = grid:selected()
	report("Page Down moves by lines in view", paged > lanes and (paged - 2) % lanes == 0, paged)
	key(grid.widget, VK.PRIOR)
	report("Page Up comes back", grid:selected() == 2, grid:selected())
	key(grid.widget, VK.PRIOR)
	report("Page Up near the top lands on the first cell", grid:selected() == 1, grid:selected())
	key(grid.widget, VK.END)
	report("End goes to the last cell and scrolls there", grid:selected() == COUNT and select(2, grid:visibleRange()) == COUNT, grid:selected())
	key(grid.widget, VK.HOME)
	report("Home comes back", grid:selected() == 1 and select(1, grid:visibleRange()) == 1, grid:selected())
	key(grid.widget, VK.RETURN)
	report("Enter activates", activated_cb == 1 and activated_how == "enter")
	post(grid.widget, WM.LBUTTONDBLCLK, 1, point(30, 30))
	report("a double click activates", activated_how == "double")
	post(grid.widget, WM.RBUTTONDOWN, 2, point(200, 30))
	report("a right click selects and asks for a menu", context_cb == 2 and grid:selected() == 2, context_cb)
end
do
	-- Targeted repaint. On a private desktop the pointer is never really there, so
	-- TrackMouseEvent reports a leave right after the first move. That move and two more in
	-- the same cell are queued ahead of it, and the leave itself is checked by reading HOVER.
	pump(30)
	bit_calls = 0
	user32.PostMessageA(hwnd(grid.widget), WM.MOUSEMOVE, 0, point(30, 30))
	user32.PostMessageA(hwnd(grid.widget), WM.MOUSEMOVE, 0, point(31, 31))
	user32.PostMessageA(hwnd(grid.widget), WM.MOUSEMOVE, 0, point(32, 32))
	iup.LoopStep(); iup.LoopStep(); iup.LoopStep()
	report("the pointer sets the hover", iup.GetAttribute(grid.widget, "HOVER") == "1", iup.GetAttribute(grid.widget, "HOVER"))
	pump(30)
	report("three moves in one cell cost one cell", bit_calls <= 2, bit_calls)
	report("leaving clears the hover", iup.GetAttribute(grid.widget, "HOVER") == "0", iup.GetAttribute(grid.widget, "HOVER"))
	bit_calls = 0
	grid:refreshCell(1)
	pump(20)
	report("refreshCell repaints that cell", bit_calls >= 1 and bit_calls <= 4, bit_calls)
end
do
	-- Type-ahead, against a list with real titles.
	local names = { "Alien", "Amadeus", "Brazil", "Casablanca", "Chinatown", "Citizen Kane", "Heat", "Vertigo" }
	grid.bits = nil
	grid:setProvider(#names, function(pos, field) return field == "TITLE" and names[pos] or nil end)
	pump(30)
	grid:select(1)
	local letter = function(ch) key(grid.widget, string.byte(ch:upper())) end
	letter("c")
	report("a letter jumps to the first match", grid:selected() == 4, grid:selected())
	letter("h")
	report("more letters narrow it", grid:selected() == 5, grid:selected())
	local deadline = now_ms() + 1000
	while now_ms() < deadline do pump(20) end
	letter("c")
	report("the same letter later moves on", grid:selected() == 6, grid:selected())
end
do
	-- MULTIPLE needs its own widget: the selection store is sized when COUNT is set.
	local many = CellGrid.new(iup, { count = 50, multiple = true,
		value = function(pos, field) return field == "TITLE" and ("Item " .. pos) or nil end })
	style(many.widget, theme, "flatgrid")
	local box = iup.dialog({ many.widget, rastersize = "900x600", title = "multi" })
	box:showxy(iup.CENTER, iup.CENTER)
	iup.SetFocus(many.widget)
	pump(100)
	post(many.widget, WM.LBUTTONDOWN, 1, point(30, 30))
	post(many.widget, WM.LBUTTONUP, 0, point(30, 30))
	post(many.widget, WM.KEYDOWN, 0x20, 1)
	report("Space toggles a selected cell off", #many:selection() == 0, #many:selection())
	post(many.widget, WM.KEYDOWN, 0x20, 1)
	report("Space toggles it back on", #many:selection() == 1, #many:selection())
	post(many.widget, WM.KEYDOWN, 0x41, 1)  -- a letter with no Ctrl is type-ahead, not select all
	report("a plain letter does not select everything", #many:selection() <= 1, #many:selection())
	many:select(3)
	report("select replaces the selection", many:selection()[1] == 3 and #many:selection() == 1)
	report("a mask becomes positions", CellGrid.parseMask("-+-+")[2] == 4)
	local half = iup.GetAttribute(many.widget, "SELECTEDCOUNT")
	report("the count is reported", half == "1", half)
	shot(box, "grid-multi")
	iup.Destroy(box)
end

local shelf_count = 40
do
	local shelf = CellGrid.new(iup, { count = shelf_count, shelf = true, cell_width = 240, aspect = "16:9",
		value = function(pos, field) return field == "TITLE" and ("Episode " .. pos) or (field == "SECONDARY" and "42 min" or nil) end })
	style(shelf.widget, theme, "flatgrid")
	local holder = iup.dialog({ shelf.widget, rastersize = "1000x280", title = "shelf" })
	holder:showxy(iup.CENTER, iup.CENTER)
	iup.SetFocus(shelf.widget)
	pump(100)
	post(shelf.widget, WM.LBUTTONDOWN, 1, point(30, 30))
	post(shelf.widget, WM.LBUTTONUP, 0, point(30, 30))
	key(shelf.widget, VK.RIGHT)
	report("Right moves along a shelf", shelf:selected() == 2, shelf:selected())
	key(shelf.widget, VK.END)
	local at_end = tonumber(iup.GetAttribute(shelf.widget, "POSX"))
	report("a shelf scrolls sideways to the end", shelf:selected() == shelf_count and at_end > 0, shelf:selected() .. " at " .. at_end)
	post(shelf.widget, WM.MOUSEWHEEL, 0x00780000, point(100, 60))
	pump(10)
	report("the wheel scrolls a shelf sideways", tonumber(iup.GetAttribute(shelf.widget, "POSX")) < at_end, iup.GetAttribute(shelf.widget, "POSX"))
	pump(30)
	shot(holder, "grid-shelf")
	iup.Destroy(holder)
end

---------------------------------------------------------------------------------------------
line("-- IupFlatRows")
do
	local sorts, row_calls = {}, 0
	local rows = RowList.new(iup, {
		count = 200, row_height = 64, image_size = "40x60",
		column_widths = { 70, 90, 110 },
		header = { title = "Name", columns = { "Year", "Runtime", "Size" }, sorted = { column = 1 } },
		on_sort = function(column, descending) sorts[#sorts + 1] = column .. (descending and "d" or "a") end,
		bits = function() row_calls = row_calls + 1 end,  -- a miss draws the tile
		value = function(pos, field)
			if field == "TITLE" then return "Row " .. pos end
			if field == "SECONDARY" then return "second line" end
			if field == "COLUMN1" then return tostring(1950 + pos) end
			if field == "COLUMN2" then return "1h 38m" end
			if field == "COLUMN3" then return "2.4 GB" end
			if field == "PROGRESS" then return pos % 2 == 0 and 40 or nil end
		end,
	})
	style(rows.widget, theme, "flatrows")
	if not theme_rules then
		iup.SetAttribute(rows.widget, "PSCOLOR", "48 60 84")
		iup.SetAttribute(rows.widget, "BORDERCOLOR", "60 64 72")
	end
	local box = iup.dialog({ rows.widget, rastersize = "900x560", title = "rows" })
	box:showxy(iup.CENTER, iup.CENTER)
	iup.SetFocus(rows.widget)
	pump(100)
	shot(box, "rows-header")
	post(rows.widget, WM.LBUTTONDOWN, 1, point(120, 40))
	post(rows.widget, WM.LBUTTONUP, 0, point(120, 40))
	report("a row under the header is row 1", rows:selected() == 1, rows:selected())
	key(rows.widget, VK.DOWN); key(rows.widget, VK.DOWN)
	key(rows.widget, VK.PRIOR)
	report("Page Up near the top lands on the first row", rows:selected() == 1, rows:selected())
	key(rows.widget, VK.END)
	report("End reaches the last row", rows:selected() == 200 and tonumber(iup.GetAttribute(rows.widget, "POSY")) > 0, rows:selected())
	key(rows.widget, VK.NEXT)
	report("Page Down at the end stays", rows:selected() == 200, rows:selected())
	key(rows.widget, VK.HOME)
	pump(30)
	row_calls = 0
	user32.PostMessageA(hwnd(rows.widget), WM.MOUSEMOVE, 0, point(200, 60))
	user32.PostMessageA(hwnd(rows.widget), WM.MOUSEMOVE, 0, point(201, 61))
	user32.PostMessageA(hwnd(rows.widget), WM.MOUSEMOVE, 0, point(202, 62))
	iup.LoopStep(); iup.LoopStep(); iup.LoopStep()
	report("the pointer sets the hover", iup.GetAttribute(rows.widget, "HOVER") == "1", iup.GetAttribute(rows.widget, "HOVER"))
	pump(30)
	report("three moves in one row cost one row", row_calls <= 2, row_calls)
	report("leaving clears the hover", iup.GetAttribute(rows.widget, "HOVER") == "0", iup.GetAttribute(rows.widget, "HOVER"))
	post(rows.widget, WM.LBUTTONDOWN, 1, point(120, 10))
	post(rows.widget, WM.LBUTTONUP, 0, point(120, 10))
	report("a header click sorts by the title", sorts[1] == "0a", sorts[1])
	post(rows.widget, WM.LBUTTONDOWN, 1, point(120, 10))
	post(rows.widget, WM.LBUTTONUP, 0, point(120, 10))
	report("a second click turns it round", sorts[2] == "0d", sorts[2])
	local width = tonumber((iup.GetAttribute(rows.widget, "RASTERSIZE") or ""):match("^(%d+)")) or 880
	post(rows.widget, WM.LBUTTONDOWN, 1, point(width - 60, 10))
	post(rows.widget, WM.LBUTTONUP, 0, point(width - 60, 10))
	report("a column header sorts by that column", sorts[3] == "3a", sorts[3])
	pump(30)
	shot(box, "rows-sorted")
	iup.Destroy(box)
end

---------------------------------------------------------------------------------------------
line("-- IupFlatSeek")
do
	local seeks, changing, hovered, left = {}, {}, nil, false
	local bar = SeekBar.new(iup, {
		max = 1000, value = 250,
		on_seek = function(v) seeks[#seeks + 1] = v end,
		on_changing = function(v) changing[#changing + 1] = v end,
		on_hover = function(v, x) if x >= 0 then hovered = { v, x } else left = true end end,
	})
	style(bar.widget, { BGCOLOR = "22 24 28", TRACKCOLOR = "70 74 82", BUFFERCOLOR = "120 126 136", PSCOLOR = "96 165 250", MARKCOLOR = "232 234 238" }, "flatseek")
	bar:setBuffered({ { 0, 400 }, { 600, 700 } })
	bar:setMarks({ { at = 95, to = 180 }, { at = 300 }, { at = 550 }, { at = 820 } })
	local box = iup.dialog({ iup.vbox({ bar.widget, margin = "16x16" }), rastersize = "804x120", title = "seek" })
	box:showxy(iup.CENTER, iup.CENTER)
	iup.SetFocus(bar.widget)
	pump(100)
	shot(box, "seek-rest")
	report("a value reads back", math.abs(bar:value() - 250) < 0.01, bar:value())
	key(bar.widget, VK.RIGHT)
	report("Right steps and commits", #seeks == 1 and math.abs(seeks[1] - 255) < 0.01, seeks[1])
	key(bar.widget, VK.END)
	report("End goes to the end", math.abs(seeks[2] - 1000) < 0.01, seeks[2])
	key(bar.widget, VK.HOME)
	report("Home goes to the start", math.abs(seeks[3]) < 0.01, seeks[3])
	post(bar.widget, WM.MOUSEMOVE, 0, point(380, 12))
	report("hover reports a position", hovered and hovered[1] > 400 and hovered[1] < 550 and hovered[2] == 380, hovered and hovered[1])
	pump(30)
	shot(box, "seek-hover")
	post(bar.widget, WM.LBUTTONDOWN, 1, point(100, 12))
	local down = bar:value()
	report("press shows the place at once", #changing >= 1 and down > 90 and down < 160, down)
	bar:setValue(900)
	report("a playback tick cannot move the line during a drag", bar:value() == down, bar:value())
	post(bar.widget, WM.MOUSEMOVE, 1, point(500, 12))
	report("no commit until release", #seeks == 3, #seeks)
	post(bar.widget, WM.LBUTTONUP, 0, point(500, 12))
	report("release commits", #seeks == 4 and seeks[4] > 600, seeks[4])
	post(bar.widget, WM.MOUSELEAVE, 0, 0)
	report("leaving reports x = -1", left)
	bar:setValue(300)
	report("after a drag ticks move it again", math.abs(bar:value() - 300) < 0.01, bar:value())
	iup.Destroy(box)
end

---------------------------------------------------------------------------------------------
cache:close()
line(failures == 0 and "ALL PASS" or (failures .. " FAILED"))
os.exit(failures == 0 and 0 or 1)

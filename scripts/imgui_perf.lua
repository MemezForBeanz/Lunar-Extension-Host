-- scripts/imgui_perf.lua -- time the ImGui host's frames on every tool page.
--
--   Lunar scripts/imgui_perf.lua <out_dir> [frames]
--
-- For each page: the mean and worst time of a full frame (route, layout, paint, render),
-- of a paint alone, and of a forced relayout, plus the element count. Then a LuaJIT
-- profile (jit.p) of repeated frames on the last page. Writes <out_dir>/perf.txt.
local out_dir = (arg and arg[1]) or "."
local frames = tonumber(arg and arg[2]) or 120
package.path = (LUNAR_SOURCE_DIR or ".") .. "/vendor/luajit/bin/lua/?.lua;" .. package.path

local iup = require("iup")
local out = assert(io.open(out_dir .. "/perf.txt", "w"))
local function say(...) out:write(string.format(...), "\n"); out:flush() end

local Runtime = require("core.imgui.Runtime")
local Element = require("core.imgui.Element")
local Layout = require("core.imgui.Layout")
local clock = os.clock
local ffi = require("ffi")
ffi.cdef[[ int QueryPerformanceCounter(int64_t*); int QueryPerformanceFrequency(int64_t*);
typedef struct { uint32_t cb, PageFaultCount; size_t PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage,
  QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage,
  PrivateUsage; } PERF_PMC;
void* GetCurrentProcess(void);
int K32GetProcessMemoryInfo(void*, PERF_PMC*, uint32_t); ]]
local function memory()
	local pmc = ffi.new("PERF_PMC"); pmc.cb = ffi.sizeof(pmc)
	ffi.C.K32GetProcessMemoryInfo(ffi.C.GetCurrentProcess(), pmc, pmc.cb)
	return tonumber(pmc.WorkingSetSize) / 1048576, tonumber(pmc.PrivateUsage) / 1048576, tonumber(pmc.PeakWorkingSetSize) / 1048576
end
local qpc = ffi.new("int64_t[1]")
local freq = ffi.new("int64_t[1]"); ffi.C.QueryPerformanceFrequency(freq)
local hz = tonumber(freq[0])
local function now() ffi.C.QueryPerformanceCounter(qpc); return tonumber(qpc[0]) / hz end
_ = clock

local function count(el)
	local st = Element.state(el)
	local n = 1
	for _, c in ipairs(st.children) do n = n + count(c) end
	return n
end

local function children(h)
	local list, i = {}, 0
	local c = iup.GetChild(h, 0)
	while c do list[#list + 1] = c; i = i + 1; c = iup.GetChild(h, i) end
	return list
end
local function leaves(strip, path, acc)
	for i, page in ipairs(children(strip)) do
		local step = {}
		for _, s in ipairs(path) do step[#step + 1] = s end
		step[#step + 1] = { strip = strip, pos = i - 1 }
		if iup.GetClassName(page) == "flattabs" then leaves(page, step, acc)
		else acc[#acc + 1] = { path = step, title = iup.GetAttribute(strip, "TABTITLE" .. (i - 1)) or ("tab" .. i) } end
	end
	return acc
end
local function find_strip(h)
	local role = iup.GetAttribute(h, "THEMEROLE")
	if role == "titlebar_tabs" or role == "tool_rail" then return nil end
	if iup.GetClassName(h) == "flattabs" then return h end
	for _, c in ipairs(children(h)) do
		local f = find_strip(c)
		if f then return f end
	end
end

local function stats(list)
	local sum, worst = 0, 0
	for _, v in ipairs(list) do sum = sum + v; if v > worst then worst = v end end
	table.sort(list)
	return sum / #list * 1000, list[math.ceil(#list / 2)] * 1000, worst * 1000
end

local real_mainloop = iup.MainLoop
iup.MainLoop = function()
	local t = iup.timer({ time = 4000 })
	function t:action_cb()
		self.run = "NO"
		local ok, err = pcall(function()
			local B = Runtime.backend()
			B.window("restore"); B.window("size", 1400, 900)
			local dlg = Runtime.mainDialog()
			local pages = leaves(find_strip(dlg), {}, {})
			local dc = Runtime.dc()
			say("elements in main dialog: %d", count(dlg))
			say("memory at start: working set %.1f MB, private %.1f MB, peak working set %.1f MB", memory())
			say("native backend through FFI: %s", tostring(B.ffi == true))
			say("%-16s %8s %8s %8s | %8s %8s | %8s", "page", "frame", "median", "worst", "paint", "worst", "layout")
			for _, page in ipairs(pages) do
				for _, s in ipairs(page.path) do iup.SetAttribute(s.strip, "VALUEPOS", tostring(s.pos)) end
				for _ = 1, 5 do Runtime.frame() end
				local ft, pt, lt = {}, {}, {}
				for i = 1, frames do
					Runtime.redraw()
					local a = now(); Runtime.frame(); ft[i] = now() - a
				end
				local st = Element.state(dlg)
				for i = 1, frames do
					B.frame_begin()
					dc:begin(st.w, st.h)
					local a = now(); Runtime.paint(dlg, dc); pt[i] = now() - a
					B.frame_end()
				end
				for i = 1, 20 do
					st.data.layout_dirty = true
					local a = now(); Layout.run(dlg, st.w, st.h); lt[i] = now() - a
				end
				local fm, fmed, fw = stats(ft)
				local pm, _, pw = stats(pt)
				local lm = stats(lt)
				say("%-16s %8.2f %8.2f %8.2f | %8.2f %8.2f | %8.2f", page.title:sub(1, 16), fm, fmed, fw, pm, pw, lm)
			end
			collectgarbage("collect")
			say("lua heap after: %.1f MB", collectgarbage("count") / 1024)
			say("memory after pages: working set %.1f MB, private %.1f MB, peak working set %.1f MB", memory())
			local okp, prof = pcall(require, "jit.p")
			if okp then
				prof.start("Fl2", out_dir .. "/profile-funcs.txt")
				for _ = 1, frames * 3 do Runtime.redraw(); Runtime.frame() end
				prof.stop()
				prof.start("l", out_dir .. "/profile-lines.txt")
				for _ = 1, frames * 3 do Runtime.redraw(); Runtime.frame() end
				prof.stop()
			else
				say("no jit.p: %s", tostring(prof))
			end
		end)
		if not ok then say("error: %s", tostring(err)) end
		out:close()
		return iup.CLOSE
	end
	t.run = "YES"
	return real_mainloop()
end

local ok, err = pcall(dofile, (LUNAR_SOURCE_DIR or ".") .. "/src/lua/core/main.lua")
if not ok then say("main.lua: %s", tostring(err)); out:close(); os.exit(1) end
os.exit(0)

-- scripts/ui_memory.lua -- the process's memory after start-up, on either build.
--
--   Lunar scripts/ui_memory.lua <out_dir>
--
-- Writes <out_dir>/memory-<iup|imgui>.txt: working set and private bytes eight seconds
-- after start, the Lua heap, and the loaded modules by mapped image size (what the
-- working set is made of beyond Lua: GPU driver, fonts, system DLLs).
local iup = require("iup")
local ffi = require("ffi")
local IMGUI = rawget(iup, "_IMGUI") == true
local out = assert(io.open(((arg and arg[1]) or ".") .. "/memory-" .. (IMGUI and "imgui" or "iup") .. ".txt", "w"))
local function say(...) out:write(string.format(...), "\n"); out:flush() end

ffi.cdef[[
typedef struct { uint32_t cb, PageFaultCount; size_t PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage,
  QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage,
  PrivateUsage; } MEM_PMC;
typedef struct { void* lpBaseOfDll; uint32_t SizeOfImage; void* EntryPoint; } MEM_MODINFO;
void* GetCurrentProcess(void);
int K32GetProcessMemoryInfo(void*, MEM_PMC*, uint32_t);
int K32EnumProcessModules(void*, void**, uint32_t, uint32_t*);
int K32GetModuleInformation(void*, void*, MEM_MODINFO*, uint32_t);
uint32_t K32GetModuleBaseNameA(void*, void*, char*, uint32_t);
int K32EmptyWorkingSet(void*);
]]
local C = ffi.C

local function memory()
	local pmc = ffi.new("MEM_PMC"); pmc.cb = ffi.sizeof(pmc)
	C.K32GetProcessMemoryInfo(C.GetCurrentProcess(), pmc, pmc.cb)
	return tonumber(pmc.WorkingSetSize) / 1048576, tonumber(pmc.PrivateUsage) / 1048576
end

local function modules()
	local proc = C.GetCurrentProcess()
	local list = ffi.new("void*[1024]")
	local need = ffi.new("uint32_t[1]")
	C.K32EnumProcessModules(proc, list, ffi.sizeof(list), need)
	local n = math.min(1024, need[0] / ffi.sizeof("void*"))
	local rows, total = {}, 0
	local name = ffi.new("char[260]")
	for i = 0, n - 1 do
		local info = ffi.new("MEM_MODINFO")
		C.K32GetModuleInformation(proc, list[i], info, ffi.sizeof(info))
		C.K32GetModuleBaseNameA(proc, list[i], name, 260)
		rows[#rows + 1] = { ffi.string(name), info.SizeOfImage / 1048576 }
		total = total + info.SizeOfImage / 1048576
	end
	table.sort(rows, function(a, b) return a[2] > b[2] end)
	return rows, total
end

local real_mainloop = iup.MainLoop
iup.MainLoop = function()
	local t = iup.timer({ time = 8000 })
	function t:action_cb()
		self.run = "NO"
		collectgarbage("collect")
		say("build: %s", IMGUI and "imgui" or "iup")
		say("after start: working set %.1f MB, private %.1f MB, lua heap %.1f MB", select(1, memory()), select(2, memory()), collectgarbage("count") / 1024)
		C.K32EmptyWorkingSet(C.GetCurrentProcess())
		say("after trimming the working set: %.1f MB (what the next seconds fault back in)", (memory()))
		local rows, total = modules()
		say("%d modules, %.1f MB of mapped images; largest:", #rows, total)
		for i = 1, math.min(15, #rows) do say("  %7.1f MB  %s", rows[i][2], rows[i][1]) end
		out:close()
		iup.ExitLoop()
		return iup.CLOSE
	end
	t.run = "YES"
	return real_mainloop()
end

local ok, err = pcall(dofile, (LUNAR_SOURCE_DIR or ".") .. "/src/lua/core/main.lua")
if not ok then say("main.lua: %s", tostring(err)); out:close(); os.exit(1) end
os.exit(0)

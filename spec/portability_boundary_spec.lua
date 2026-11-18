-- spec/portability_boundary_spec.lua -- the core stays independent of the OS.
--
-- Lunar reaches the operating system through two layers: core.platform (files, folders,
-- clocks, processes...) and the UI backend (core.imgui.backend, with the native shims in
-- core.imgui.native). Everything else must load and run with neither Windows nor the FFI
-- there, so another platform, an embedding host or a future browser runtime only adds a
-- platform module and a backend (docs/imgui-portability.md). These checks keep it so:
--   * every core module loads with require("ffi") failing, but for the listed exceptions;
--   * direct OS access outside those layers is only in the listed files, and the list
--     can only shrink (a listed file that no longer needs it fails too).

-- Modules that may not load without the FFI or the executable's native modules, and why.
local NEEDS_NATIVE = {
	["core.imgui.backend.Native"] = "the Windows backend itself (lunarimgui)",
	["core.imgui.cimgui"] = "raw Dear ImGui bindings for extensions, FFI by nature",
	["core.imgui.native.themeapply"] = "the IUP build's theme applier, absent by design on ImGui",
	["core.imgui.native.svgicon"] = "the native SVG rasterizer's size table (svgicon_sizes)",
	["core.main"] = "the executable's entry point (subprocess, the platform window)",
	["core.ui.RowList"] = "the fork's raw list widget (iupraw)",
}

-- Files outside core.platform*, core.imgui.backend and core.imgui.native that call the
-- OS directly (ffi.C, ffi.load, os.execute, io.popen). Each should move behind
-- core.platform or the backend; none may be added.
local OS_ACCESS_BASELINE = {
	"core/classes/IupFFI.lua", "core/classes/ThemeManager.lua", "core/classes/host/Database.lua",
	"core/imgui/NativeLayout.lua", "core/imgui/cimgui.lua", "core/lib/HttpTokens.lua",
	"core/lib/Instance.lua", "core/lib/Service.lua", "core/lib/desktop.lua", "core/lib/sqlite.lua",
	"core/lib/winbatch.lua", "core/ui/BackgroundWindow.lua", "core/ui/FolderDialog.lua",
	"core/ui/TitleBar.lua", "core/ui/VectorIcon.lua", "core/ui/VideoHost.lua",
	"core/ui/WindowChrome.lua", "installer/backend.lua",
}

local windows = package.config:sub(1, 1) == "\\"

local function lua_files()
	local list = {}
	local cmd = windows and 'dir /s /b src\\lua\\*.lua' or 'find src/lua -name "*.lua"'
	local p = assert(io.popen(cmd))
	for line in p:lines() do
		local rel = line:gsub("\\", "/"):match("src/lua/(.+)$")
		if rel then list[#list + 1] = rel end
	end
	p:close()
	return list
end

local function in_os_layer(rel)
	return rel:match("^core/platform") or rel:match("^core/imgui/backend/") or rel:match("^core/imgui/native/")
end

local OS_PATTERNS = { "ffi%.C%f[^%w_]", "ffi%.load%f[^%w_]", "os%.execute%f[^%w_]", "io%.popen%f[^%w_]" }
local function touches_os(path)
	local f = assert(io.open(path, "rb"))
	local text = f:read("*a")
	f:close()
	for _, pat in ipairs(OS_PATTERNS) do if text:find(pat) then return true end end
	return false
end

describe("portability boundary", function()
	it("keeps direct OS access inside the platform and backend layers", function()
		local listed = {}
		for _, rel in ipairs(OS_ACCESS_BASELINE) do listed[rel] = true end
		local new, stale, seen = {}, {}, {}
		for _, rel in ipairs(lua_files()) do
			if not in_os_layer(rel) and touches_os("src/lua/" .. rel) then
				seen[rel] = true
				if not listed[rel] then new[#new + 1] = rel end
			end
		end
		for rel in pairs(listed) do if not seen[rel] then stale[#stale + 1] = rel end end
		table.sort(new); table.sort(stale)
		assert.same({}, new, "new direct OS access outside core.platform / the backend")
		assert.same({}, stale, "no longer touches the OS: take it off OS_ACCESS_BASELINE")
	end)

	it("loads every core module with the FFI unavailable, but for the listed exceptions", function()
		local exe = windows and "vendor\\luajit\\bin\\luajit.exe" or "luajit"
		local p = assert(io.popen(exe .. " scripts/portability_check.lua 2>&1"))
		local out = p:read("*a")
		p:close()
		local done = out:match("DONE (%d+)/(%d+)")
		assert.truthy(done, "portability_check did not finish:\n" .. out)
		local unexpected, failed = {}, {}
		for m, why in out:gmatch("FAIL (%S+) <%- ([^\n]*)") do
			failed[m] = true
			if not NEEDS_NATIVE[m] then unexpected[#unexpected + 1] = m .. " (" .. why .. ")" end
		end
		local loads_now = {}
		for m in pairs(NEEDS_NATIVE) do if not failed[m] then loads_now[#loads_now + 1] = m end end
		table.sort(unexpected); table.sort(loads_now)
		assert.same({}, unexpected, "these core modules need the FFI or a native module to load")
		assert.same({}, loads_now, "these load without native code now: take them off NEEDS_NATIVE")
	end)
end)

-- scripts/portability_check.lua -- which core modules load on a platform with no FFI.
--   luajit scripts/portability_check.lua            (from the repo root)
-- Prints "FAIL <module> <- <reason>" for each module that does not load with
-- require("ffi") failing, then "DONE <loaded>/<total>". Each module loads in a clean
-- package state (loaded modules, preloads and paths restored after it), so one module's
-- side effects cannot hide or cause another's failure. spec/portability_boundary_spec.lua
-- runs it; docs/imgui-portability.md says why it matters.
package.path = "./src/lua/?.lua;./src/lua/?/init.lua;./vendor/copas/?.lua;"
	.. "./vendor/luarocks-tree/share/lua/5.1/?.lua;./vendor/luarocks-tree/share/lua/5.1/?/init.lua;" .. package.path
package.cpath = "./vendor/luarocks-tree/lib/lua/5.1/?.dll;./vendor/luarocks-tree/lib/lua/5.1/?.so;" .. package.cpath

local windows = package.config:sub(1, 1) == "\\"
local function core_modules()
	local list = {}
	local cmd = windows and 'dir /s /b src\\lua\\core\\*.lua' or 'find src/lua/core -name "*.lua"'
	local p = assert(io.popen(cmd))
	for line in p:lines() do
		local m = line:gsub("\\", "/"):match("src/lua/(core/.+)%.lua$")
		if m then list[#list + 1] = (m:gsub("/init$", ""):gsub("/", ".")) end
	end
	p:close()
	table.sort(list)
	return list
end

local base_loaded, base_preload = {}, {}
for k, v in pairs(package.loaded) do base_loaded[k] = v end
for k, v in pairs(package.preload) do base_preload[k] = v end
local base_path, base_cpath = package.path, package.cpath
local function reset()
	for k in pairs(package.loaded) do if base_loaded[k] == nil then package.loaded[k] = nil end end
	for k, v in pairs(base_loaded) do package.loaded[k] = v end
	for k in pairs(package.preload) do package.preload[k] = nil end
	for k, v in pairs(base_preload) do package.preload[k] = v end
	package.path, package.cpath = base_path, base_cpath
	package.loaded.ffi = nil
	package.preload.ffi = function() error("FFI-UNAVAILABLE", 0) end
	package.preload.iup = function() return require("core.imgui.iup") end
end

local modules, loaded = core_modules(), 0
for _, m in ipairs(modules) do
	reset()
	local ok, err = xpcall(function() return require(m) end, debug.traceback)
	if ok then loaded = loaded + 1
	else
		err = tostring(err):gsub("\n.*", "")
		local why = (err:find("FFI-UNAVAILABLE", 1, true) or err:find("error loading module 'ffi'", 1, true))
			and "needs ffi" or err:gsub("^.-:%d+: ", ""):sub(1, 160)
		print("FAIL " .. m .. " <- " .. why)
	end
end
print(string.format("DONE %d/%d", loaded, #modules))

-- uninstall.lua — removes a Lunar installed by the Linux setup program. Installed as
-- <app>/setup/uninstall.lua and started by `lunar-uninstall` (and its menu entry):
--   <app>/lunar <app>/setup/uninstall.lua            (a window)
--   <app>/setup/lunar-cli <app>/setup/uninstall.lua --quiet
-- (The console executable has no embedded Lua, so it reads setup/lua/ beside this file.)
if not package.preload["installer.main"] then
	package.path = (arg[0]:match("^(.*)/[^/]*$") or ".") .. "/lua/?.lua"
end
local argv = { "--uninstall" }
for i = 1, #arg do argv[#argv + 1] = arg[i] end
local code = require("installer.main").run(argv, arg[0], rawget(_G, "iup"))
if code ~= 0 then os.exit(code) end

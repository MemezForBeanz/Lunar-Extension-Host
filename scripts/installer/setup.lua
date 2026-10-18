-- setup.lua — starts the Lunar installer. Run by the Lunar executable, which runs a
-- .lua path in place of the app:
--   Linux:   lunar <payload>/setup/setup.lua [--type user|system --extensions all|none|a,b ...]
--            lunar-cli <payload>/setup/setup.lua --quiet ...    (no window, no display needed)
--   Windows: Lunar.exe setup.lua              (from the Lunar-Setup-<version>.exe self-extractor)
-- The installer itself is src/lua/installer/. The GUI executable has it embedded; the
-- console executable (lunar-cli) reads the copy in setup/lua/ beside this file.
if not package.preload["installer.main"] then
	package.path = (arg[0]:match("^(.*)/[^/]*$") or ".") .. "/lua/?.lua"
end
local code = require("installer.main").run(arg, arg[0], rawget(_G, "iup"))
if code ~= 0 then os.exit(code) end

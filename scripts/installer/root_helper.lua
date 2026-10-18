-- root_helper.lua — the part of the Linux "Everyone" install that runs as root.
-- Started by the installer as `pkexec <dir>/lunar-cli root_helper.lua <verb> ...`
-- (an argument list, never a shell string):
--   install <absolute payload folder> <ids|->    copy the payload into /opt/lunar etc.
--   uninstall                                     remove the system install
-- It takes no paths to write to: it only ever uses the fixed system locations and
-- rebuilds the whole plan itself (installer/linux.lua, `helper_main`).
local dir = arg[0]:match("^(.*)/[^/]*$") or "."
package.path = dir .. "/lua/?.lua"
local args = {}
for i = 1, #arg do args[i] = arg[i] end
os.exit(require("installer.linux").helper_main(args))

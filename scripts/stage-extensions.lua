-- Shared release staging for Windows and Linux. Runs with the freshly built CLI.
local repo = assert(arg[1], 'Expected repository path')
package.path = repo .. '/src/lua/?.lua;' .. package.path
local exts, skipped = require('installer.package').stage(assert(arg[2]), assert(arg[3]), assert(arg[4]), {os = assert(arg[5])})
for _, item in ipairs(skipped) do print('Skipped extension ' .. item.source .. ': ' .. item.reason) end
for _, ext in ipairs(exts) do print('Installer extension: ' .. ext.id .. ' (' .. ext.name .. ')') end

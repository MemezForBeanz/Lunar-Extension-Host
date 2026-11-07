--- Build the shared extension payload used by the platform installers.
-- @module installer.package
local lfs = require('lfs')
local plan = require('installer.plan')
local platform = require('core.platform')
local M = {}
local function copy_file(from, to)
 local input = assert(io.open(from, 'rb'))
 local output, why = io.open(to, 'wb')
 if not output then input:close(); error(why) end
 while true do
  local bytes = input:read(1024 * 1024)
  if not bytes then break end
  local ok, err = output:write(bytes)
  if not ok then input:close(); output:close(); error(err) end
 end
 input:close(); assert(output:close())
end
local function copy_entry(from, to)
 local mode = lfs.symlinkattributes(from, 'mode')
 if mode == 'directory' then
  local dirs, files = plan.list_tree(from)
  assert(dirs, files)
  assert(platform.mkdirs(to))
  for _, dir in ipairs(dirs) do assert(platform.mkdirs(to .. '/' .. dir)) end
  for _, file in ipairs(files) do copy_file(from .. '/' .. file, to .. '/' .. file) end
 elseif mode == 'file' then copy_file(from, to)
 else error('Not a regular extension payload entry: ' .. from) end
end

--- Merge built-in plugins and project extensions into an empty staging folder.
-- Uses the installer's manifest/platform rules. Archives and loose project support
-- files are not extensions. Duplicate IDs or destination names fail before copying.
-- @tparam string builtin built-in plugins root
-- @tparam string extensions project extensions root
-- @tparam string destination empty staging directory
-- @tparam[opt] table opts same platform options as installer.plan.scan_extensions
-- @treturn table staged extension descriptors
-- @treturn table skipped extension descriptors
function M.stage(builtin, extensions, destination, opts)
 local entries, skipped, ids, names, offered = {}, {}, {}, {}, {}
 for index, root in ipairs({builtin, extensions}) do
  local exts, ignored, support = plan.scan_extensions(root, opts)
  for _, item in ipairs(ignored) do skipped[#skipped + 1] = item end
  local function add(name)
   local key = name:lower()
   assert(not names[key], 'Extension payload name collision: ' .. name)
   names[key] = true
   entries[#entries + 1] = {from = root .. '/' .. name, name = name}
  end
  for _, ext in ipairs(exts) do
   assert(not ids[ext.id], 'Duplicate extension id: ' .. ext.id)
   ids[ext.id] = true
   add(ext.source)
   for _, companion in ipairs(ext.companions or {}) do add(companion) end
   offered[#offered + 1] = ext
  end
  -- Built-ins may carry shared runtime files. Project support includes download
  -- archives and author notes; only actual extensions enter the release payload.
  if index == 1 then for _, name in ipairs(support) do add(name) end end
 end
 if lfs.attributes(destination, 'mode') then
  for name in lfs.dir(destination) do assert(name == '.' or name == '..', 'Staging destination must be empty') end
 else assert(platform.mkdirs(destination)) end
 for _, entry in ipairs(entries) do copy_entry(entry.from, destination .. '/' .. entry.name) end
 return offered, skipped
end
return M

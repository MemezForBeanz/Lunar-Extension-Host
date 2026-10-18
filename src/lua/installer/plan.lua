--- Installer logic that doesn't depend on the operating system's installer: what
-- extensions a payload carries, which of them the user wants, and the command line.
--
-- The installer is the same program on Windows and Linux (`installer.ui`), driven by
-- a payload folder the package carries beside the executable:
--
--   * Linux: the app folder itself (`lunar`, `assets/`, `certs/`, `plugins/`) plus
--     `setup/`. Extensions are found by scanning `plugins/`.
--   * Windows: the MSI plus `setup\payload.json`, whose `extensions` list `build.ps1`
--     wrote from the same `plugins\` folder it turned into MSI features.
--
-- Nothing here touches the screen or runs a program.
--
-- @module installer.plan

local lfs = require("lfs")
local cjson = require("cjson")
local Manifest = require("core.lib.ExtensionManifest")
local platform = require("core.platform")

local M = {}

local function is_file(path) return lfs.attributes(path, "mode") == "file" end
local function is_dir(path) return lfs.attributes(path, "mode") == "directory" end

local function join(a, b) return a .. "/" .. b end

--- Read and decode a JSON file.
-- @treturn[1] table
-- @treturn[2] nil
-- @treturn[2] string why.
function M.read_json(path, reader)
	local text, err
	if reader then text, err = reader(path)
	else
		local f
		f, err = io.open(path, "rb")
		if f then text = f:read("*a"); f:close() end
	end
	if not text then return nil, err end
	local ok, value = pcall(cjson.decode, text)
	if not ok then return nil, tostring(path) .. ": " .. tostring(value) end
	return value
end

--- Encode `value` as JSON text (empty tables come out as `{}`; readers here treat
-- either as an empty list).
function M.encode_json(value)
	return cjson.encode(value)
end

local function info_from_manifest(manifest, entry)
	return {
		id = manifest.id,
		name = manifest.name or entry.name,
		version = manifest.version or "",
		description = manifest.description or "",
		source = entry.name,
		kind = entry.kind,
		companions = entry.companions,
	}
end

--- Find the extensions under a `plugins/` folder, the way the host will load them:
-- `<name>.lua` (with an optional `<name>.manifest.json`) or `<name>/init.lua` (with
-- `<name>/manifest.json`). A folder that holds neither is left alone.
--
-- Extensions whose manifest is unreadable, that need another OS or a newer host are
-- not offered; each is reported in the second result with the reason.
--
-- @tparam string plugins_dir
-- @tparam[opt] table opts `os` (default: this OS), `host_api` (default: this host's).
-- @treturn table extensions sorted by name: `{ id, name, version, description,
--   source (entry name under plugins/), kind ("file"|"dir"), companions }`.
-- @treturn table skipped: `{ { source, reason } }`.
-- @treturn table support: entry names that aren't extensions (a README, shared
--   libraries); installs copy them whatever the user picks.
function M.scan_extensions(plugins_dir, opts)
	opts = opts or {}
	local os_name = opts.os or platform.os
	local host_api = opts.host_api or Manifest.HOST_API
	local exts, skipped, support, seen = {}, {}, {}, {}
	if not is_dir(plugins_dir) then return exts, skipped, support end

	local names = {}
	for name in lfs.dir(plugins_dir) do
		if name ~= "." and name ~= ".." then names[#names + 1] = name end
	end
	table.sort(names)

	local companion = {}   -- "<stem>.manifest.json" files that belong to a "<stem>.lua"
	for _, name in ipairs(names) do
		local stem = name:match("^(.+)%.lua$")
		if stem and is_file(join(plugins_dir, name)) then companion[stem .. ".manifest.json"] = true end
	end

	for _, name in ipairs(names) do
		local full = join(plugins_dir, name)
		local entry, manifest_path, default_name
		local stem = name:match("^(.+)%.lua$")
		if stem and is_file(full) then
			entry = { name = name, kind = "file", companions = {} }
			manifest_path = join(plugins_dir, stem .. ".manifest.json")
			if is_file(manifest_path) then entry.companions[1] = stem .. ".manifest.json" end
			default_name = stem
		elseif is_dir(full) and is_file(join(full, "init.lua")) then
			entry = { name = name, kind = "dir", companions = {} }
			manifest_path = join(full, "manifest.json")
			default_name = name
		elseif not companion[name] and name:sub(1, 1) ~= "." then
			support[#support + 1] = name
		end

		if entry then
			local manifest, err = Manifest.load(manifest_path, {
				id = Manifest.defaultId(default_name), name = default_name,
			})
			if not manifest then
				skipped[#skipped + 1] = { source = name, reason = tostring(err) }
			elseif not Manifest.supports(manifest, os_name) then
				skipped[#skipped + 1] = { source = name, reason = "needs " .. table.concat(manifest.platforms, " or ") }
			elseif (manifest.host_api or 1) > host_api then
				skipped[#skipped + 1] = { source = name, reason = "needs a newer Lunar (host API " .. manifest.host_api .. ")" }
			elseif seen[manifest.id] then
				skipped[#skipped + 1] = { source = name, reason = "id '" .. manifest.id .. "' is already used by " .. seen[manifest.id] }
			else
				seen[manifest.id] = name
				exts[#exts + 1] = info_from_manifest(manifest, entry)
			end
		end
	end

	table.sort(exts, function(a, b)
		local an, bn = a.name:lower(), b.name:lower()
		if an ~= bn then return an < bn end
		return a.id < b.id
	end)
	return exts, skipped, support
end

--- Read the extension list `build.ps1` wrote into a Windows payload.
-- Each entry: `{ id, name, version, description, feature }` where `feature` is the
-- MSI feature that installs it.
-- @tparam string path `payload.json`
-- @treturn[1] table payload info (`version`, `msi`, `extensions`)
-- @treturn[2] nil
-- @treturn[2] string why.
function M.read_payload(path)
	local info, err = M.read_json(path)
	if not info then return nil, err end
	if type(info) ~= "table" then return nil, path .. ": not a JSON object" end
	local exts = {}
	for _, e in ipairs(info.extensions or {}) do
		if type(e) == "table" and type(e.id) == "string" and e.id ~= "" then
			exts[#exts + 1] = {
				id = e.id,
				name = (type(e.name) == "string" and e.name ~= "") and e.name or e.id,
				version = type(e.version) == "string" and e.version or "",
				description = type(e.description) == "string" and e.description or "",
				feature = e.feature,
			}
		end
	end
	info.extensions = exts
	return info
end

--- Which extensions to preselect.
-- With no earlier install every extension is on. With one, the ones the user chose
-- then stay on, and extensions that did not exist then (new in this payload) are on
-- too, so an upgrade doesn't silently hide something new.
-- @tparam table exts from `scan_extensions` / `read_payload`.
-- @tparam[opt] table previous `{ extensions = {ids}, available = {ids} }`.
-- @treturn table `{ [id] = boolean }`
function M.defaults(exts, previous)
	local out = {}
	if not previous then
		for _, e in ipairs(exts) do out[e.id] = true end
		return out
	end
	local chosen, available = {}, {}
	for _, id in ipairs(previous.extensions or {}) do chosen[id] = true end
	for _, id in ipairs(previous.available or {}) do available[id] = true end
	for _, e in ipairs(exts) do
		out[e.id] = chosen[e.id] == true or not available[e.id]
	end
	return out
end

--- The extensions named by `wanted`.
-- @tparam table exts
-- @tparam table|string wanted a list of ids, `"all"` or `"none"`.
-- @treturn table the chosen extensions, in `exts` order.
-- @treturn table ids that match no extension.
function M.select(exts, wanted)
	if wanted == "all" or wanted == nil then return exts, {} end
	if wanted == "none" then return {}, {} end
	local want, known, picked, unknown = {}, {}, {}, {}
	for _, id in ipairs(wanted) do want[id] = true end
	for _, e in ipairs(exts) do
		known[e.id] = true
		if want[e.id] then picked[#picked + 1] = e end
	end
	for _, id in ipairs(wanted) do
		if not known[id] then unknown[#unknown + 1] = id end
	end
	return picked, unknown
end

--- Every folder and file under `root`, as paths relative to it (`/` separated),
-- parents before children. A symbolic link anywhere in the tree is refused: an
-- installer that runs as root must not be talked into copying a file from elsewhere.
-- @tparam string root
-- @treturn[1] table dirs
-- @treturn[1] table files
-- @treturn[2] nil
-- @treturn[2] string why.
function M.list_tree(root)
	local dirs, files = {}, {}
	local function walk(rel)
		local full = rel == "" and root or join(root, rel)
		local names = {}
		for name in lfs.dir(full) do
			if name ~= "." and name ~= ".." then names[#names + 1] = name end
		end
		table.sort(names)
		for _, name in ipairs(names) do
			local r = rel == "" and name or join(rel, name)
			local path = join(root, r)
			local mode = lfs.symlinkattributes(path, "mode")
			if mode == "link" then
				return nil, "refusing symbolic link in the payload: " .. path
			elseif mode == "directory" then
				dirs[#dirs + 1] = r
				local ok, err = walk(r)
				if not ok then return nil, err end
			elseif mode == "file" then
				files[#files + 1] = r
			else
				return nil, "unexpected entry in the payload: " .. path
			end
		end
		return true
	end
	if lfs.symlinkattributes(root, "mode") ~= "directory" or
		(platform.secure_parent and not platform.secure_parent(root)) then
		return nil, "not a folder or symbolic link in the payload: " .. tostring(root)
	end
	local ok, err = walk("")
	if not ok then return nil, err end
	return dirs, files
end

--- Parse the installer's command line (`arg[1..]`).
--
--   * `--quiet`       no window: install with the options below and exit
--   * `--uninstall`   remove an existing install (Linux)
--   * `--type T`      `user` (Just for me) or `system` (Everyone)
--   * `--extensions L` `all`, `none` or a comma-separated list of extension ids
--   * `--no-launch`   don't offer to start Lunar at the end
--   * `--root DIR`    install under DIR instead of `/` (Linux system installs, testing)
--   * `--home DIR`    treat DIR as the home folder (Linux user installs, testing)
--
-- @tparam table args
-- @treturn[1] table options
-- @treturn[2] nil
-- @treturn[2] string what was wrong.
function M.parse_args(args)
	local opts = { quiet = false, uninstall = false, launch = true }
	local i = 1
	while i <= #args do
		local a = args[i]
		local function value()
			i = i + 1
			return args[i]
		end
		if a == "--quiet" or a == "-q" then opts.quiet = true
		elseif a == "--uninstall" then opts.uninstall = true
		elseif a == "--no-launch" then opts.launch = false
		elseif a == "--type" then
			local v = value()
			if v ~= "user" and v ~= "system" then return nil, "--type must be user or system" end
			opts.type = v
		elseif a == "--extensions" then
			local v = value()
			if not v then return nil, "--extensions needs a value" end
			if v == "all" or v == "none" then opts.extensions = v
			else
				opts.extensions = {}
				for id in v:gmatch("[^,]+") do opts.extensions[#opts.extensions + 1] = id end
			end
		elseif a == "--root" then
			opts.root = value()
			if not opts.root then return nil, "--root needs a folder" end
		elseif a == "--home" then
			opts.home = value()
			if not opts.home then return nil, "--home needs a folder" end
		else
			return nil, "unknown option " .. tostring(a)
		end
		i = i + 1
	end
	return opts
end

return M

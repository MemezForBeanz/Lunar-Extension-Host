--- Read-only, file-based secret store for the headless host on Linux servers,
-- where there is no desktop keyring.
--
-- An administrator provisions secrets as files; the service only reads them:
--
--     <dir>/                      root, not group/world writable (e.g. 0755)
--       <extension id>/           root:<service group>, 0750
--         <secret name>           root:<service group>, 0640, the value
--
-- Every component must be a real directory or file (no symlinks), owned by root,
-- with no group or world write bit (the `admin_only` rule), and a secret file
-- must not be world-readable. Anything else is refused with the reason, never
-- read: a secret the service account could replace is not a secret it can trust.
-- One trailing newline is stripped (so `echo token > file` works).
--
-- `secret_set` / `secret_delete` refuse: the service never writes its own
-- credentials. The returned table has the `core.platform` secret API, so
-- `HostAPI` uses it in place of the keyring (`opts.secret_store`).
-- @module core.lib.FileSecrets

local M = {}

local MAX_BYTES = 65536
local PREFIX = "Lunar Extension Host/"

-- `attrs` and `link_mode` are lfs-shaped; tests pass fakes.
local function check(attrs, link_mode, path, want)
	if link_mode(path) == "link" then return false, path .. " is a symlink" end
	local a = attrs(path)
	if type(a) ~= "table" or a.mode ~= want then
		return false, path .. (a and (" is not a " .. want) or " not found"), not a
	end
	local ok, why = M.admin_only_attrs(a)
	if not ok then return false, path .. ": " .. why end
	if want == "file" and a.permissions:sub(7, 7) == "r" then
		return false, path .. ": anyone can read it"
	end
	return true
end

--- The `admin_only` rule (see `core.platform.posix.admin_only_attrs`), repeated
-- here so the store works (and is tested) without the posix backend loaded.
-- @local
function M.admin_only_attrs(a)
	local perms = a.permissions
	if type(perms) ~= "string" or #perms ~= 9 then return false, "cannot read permissions" end
	if a.uid ~= 0 then return false, "owned by uid " .. tostring(a.uid) .. ", not root" end
	if perms:sub(8, 8) == "w" then return false, "anyone can modify it" end
	if perms:sub(5, 5) == "w" then return false, "its group can modify it" end
	return true
end

--- Create a store rooted at `dir`.
-- @tparam string dir the secrets folder
-- @tparam[opt] table deps for tests: `{ attrs = fn(path), link_mode = fn(path), read = fn(path) }`
-- @treturn table `{ secret_get, secret_set, secret_delete, dir }`
function M.new(dir, deps)
	assert(type(dir) == "string" and dir ~= "", "FileSecrets.new: dir required")
	deps = deps or {}
	local lfs = (deps.attrs and deps.link_mode) and {} or require("lfs")
	local attrs = deps.attrs or function(p) return lfs.attributes(p) end
	local link_mode = deps.link_mode or function(p)
		return lfs.symlinkattributes and lfs.symlinkattributes(p, "mode")
	end
	local read = deps.read or function(p)
		local f, err = io.open(p, "rb")
		if not f then return nil, err end
		local data = f:read(MAX_BYTES + 1)
		f:close()
		return data or ""
	end
	dir = dir:gsub("/+$", "")

	local store = { dir = dir }

	--- Look up `target` ("Lunar Extension Host/<id>/<name>").
	function store.secret_get(target)
		if type(target) ~= "string" or target:sub(1, #PREFIX) ~= PREFIX then return nil, "bad target" end
		local id, name = target:sub(#PREFIX + 1):match("^([^/]+)/([^/]+)$")
		if not id or id == "." or id == ".." or name == "." or name == ".." then return nil, "bad target" end
		local ok, why = check(attrs, link_mode, dir, "directory")
		if not ok then return nil, "secret store " .. why end
		local ext_dir = dir .. "/" .. id
		local missing
		ok, why, missing = check(attrs, link_mode, ext_dir, "directory")
		if missing then return nil, "not found" end
		if not ok then return nil, "secret store " .. why end
		local file = ext_dir .. "/" .. name
		ok, why, missing = check(attrs, link_mode, file, "file")
		if missing then return nil, "not found" end
		if not ok then return nil, "secret store " .. why end
		local value, err = read(file)
		if not value then return nil, "cannot read " .. file .. ": " .. tostring(err) end
		if #value > MAX_BYTES then return nil, file .. " is larger than 64 KiB" end
		value = value:gsub("\r?\n$", "")
		if value == "" then return nil, "not found" end
		return value
	end

	function store.secret_set()
		return nil, "the secret store at " .. dir .. " is read-only; an administrator provisions it"
	end

	function store.secret_delete()
		return nil, "the secret store at " .. dir .. " is read-only; an administrator provisions it"
	end

	return store
end

return M

--- Owned local databases. This is lifecycle management, not a sandbox.
-- @module core.classes.host.Database
local lfs = require("lfs")
local platform = require("core.platform")
local Manifest = require("core.lib.ExtensionManifest")
local M = {}

function M.defaultStateDir()
	local xdg = os.getenv("XDG_STATE_HOME")
	if xdg and xdg ~= "" then return platform.path:join(xdg, "lunar") end
	local home = os.getenv("HOME") or os.getenv("USERPROFILE")
	if home and home ~= "" then return platform.path:join(home, ".local", "state", "lunar") end
	return nil, "set --state-dir (no home or XDG_STATE_HOME)"
end

local function directory(path)
	local mode = lfs.symlinkattributes(path, "mode")
	if mode then
		if mode ~= "directory" then return nil, "state path is not a directory: " .. path end
		return true
	end
	local parent = path:match("^(.*)[/\\][^/\\]+$")
	if parent and parent ~= "" and parent ~= path and not parent:match("^%a:$") then
		local ok, err = directory(parent)
		if not ok then return nil, err end
	end
	local ok, err = lfs.mkdir(path)
	if not ok then return nil, err end
	return true
end

local function local_filesystem(path)
	local ffi = require("ffi")
	if ffi.os ~= "Linux" then return true end
	pcall(ffi.cdef, "int statfs(const char *, void *);") -- may already be declared
	-- Linux statfs starts with a native long f_type. Overallocate the remaining
	-- structure without depending on its architecture-specific layout.
	local buffer = ffi.new("long[64]")
	if ffi.C.statfs(path, buffer) ~= 0 then return nil, "cannot inspect state filesystem" end
	local kind = tonumber(ffi.cast("uint32_t", buffer[0]))
	if kind == 0xff534d42 or kind == 0xfe534d42 or kind == 0x6969 or kind == 0x517b then
		return nil, "SQLite state must be on a local filesystem, not CIFS/SMB/NFS"
	end
	return true
end

function M.openDatabase(self, name, owner)
	local manifest = self._manifest_by_owner[owner]
	if not manifest or not Manifest.hasCapability(manifest, "database") then
		return nil, "openDatabase requires a registered owner with database capability"
	end
	if type(name) ~= "string" or not name:match("^[%w][%w_-]*$") then
		return nil, "database name must contain only letters, digits, '_' or '-'"
	end
	local rec = self:_record(owner)
	rec.databases = rec.databases or {}
	if rec.databases[name] then return rec.databases[name] end
	if self._stopping then return nil, "host is stopping" end
	local root, err = self._state_dir
	if not root then root, err = M.defaultStateDir() end
	if not root then return nil, err end
	local dir = platform.path:join(root, manifest.id)
	local ok, why = directory(dir)
	if not ok then return nil, why end
	ok, why = local_filesystem(dir)
	if not ok then return nil, why end
	local path = platform.path:join(dir, name .. ".sqlite3")
	for _, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do
		local mode = lfs.symlinkattributes(path .. suffix, "mode")
		if mode and mode ~= "file" then return nil, "database path must be a regular file" end
	end
	local db, problem = (self._sqlite or require("core.lib.sqlite")).open(path, { busy_timeout_ms = 0 })
	if not db then return nil, problem end
	rec.databases[name] = db
	return db
end

function M.closeOwned(self, owner)
	local rec = self._owners[owner]
	local first_error
	for name, db in pairs(rec and rec.databases or {}) do
		local ok, err = db:close()
		if not ok then first_error = first_error or err else rec.databases[name] = nil end
	end
	if first_error then return nil, first_error end
	return true
end

function M.closeAll(self)
	local first_error
	for owner in pairs(self._owners) do
		local _, err = M.closeOwned(self, owner)
		first_error = first_error or err
	end
	if first_error then return nil, first_error end
	return true
end

return M

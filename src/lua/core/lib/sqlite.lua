--- Small synchronous SQLite binding. All failures return nil, string.
-- Calls perform disk I/O on the calling thread; keep transactions short.
-- @module core.lib.sqlite
local ffi = require("ffi")
-- pcall: a module reload must not fail on "attempt to redefine".
pcall(ffi.cdef, [[
typedef struct sqlite3 sqlite3;
typedef struct sqlite3_stmt sqlite3_stmt;
int sqlite3_open_v2(const char *, sqlite3 **, int, const char *);
int sqlite3_close(sqlite3 *);
const char *sqlite3_errmsg(sqlite3 *);
int sqlite3_busy_timeout(sqlite3 *, int);
int sqlite3_exec(sqlite3 *, const char *, void *, void *, char **);
int sqlite3_prepare_v2(sqlite3 *, const char *, int, sqlite3_stmt **, const char **);
int sqlite3_bind_null(sqlite3_stmt *, int);
int sqlite3_bind_double(sqlite3_stmt *, int, double);
int sqlite3_bind_int64(sqlite3_stmt *, int, int64_t);
int sqlite3_bind_text(sqlite3_stmt *, int, const char *, int, void (*)(void *));
int sqlite3_bind_parameter_count(sqlite3_stmt *);
int sqlite3_step(sqlite3_stmt *);
int sqlite3_finalize(sqlite3_stmt *);
int sqlite3_reset(sqlite3_stmt *);
int sqlite3_clear_bindings(sqlite3_stmt *);
int sqlite3_column_count(sqlite3_stmt *);
const char *sqlite3_column_name(sqlite3_stmt *, int);
int sqlite3_column_type(sqlite3_stmt *, int);
int64_t sqlite3_column_int64(sqlite3_stmt *, int);
double sqlite3_column_double(sqlite3_stmt *, int);
const void *sqlite3_column_blob(sqlite3_stmt *, int);
int sqlite3_column_bytes(sqlite3_stmt *, int);
]])

local M = { NULL = {} }
local lib
-- winsqlite3.dll ships with Windows and needs nothing else. A MinGW build drags in
-- whichever libgcc/libwinpthread the PATH holds, which can crash on the first call.
local candidates = ffi.os == "Windows"
	and { "winsqlite3", "libsqlite3-0.dll", "sqlite3", "C:/msys64/mingw64/bin/libsqlite3-0.dll" }
	or { "libsqlite3.so.0" }
for _, name in ipairs(candidates) do
	local ok, loaded = pcall(ffi.load, name)
	if ok then lib = loaded break end
end
M.available = lib ~= nil
M.unavailable_reason = not lib and "SQLite shared library unavailable" or nil
local DB, Stmt = {}, {}
DB.__index, Stmt.__index = DB, Stmt
local transient = ffi.cast("void (*)(void *)", -1)

local function failure(db, rc)
	return nil, "sqlite (" .. tostring(rc) .. "): " .. ffi.string(lib.sqlite3_errmsg(db._ptr))
end
local function sql_valid(sql)
	return type(sql) == "string" and sql ~= "" and not sql:find("\0", 1, true)
end

function DB:exec(sql)
	if not self._ptr then return nil, "database closed" end
	if not sql_valid(sql) then return nil, "SQL must be a non-empty string without NUL" end
	local rc = lib.sqlite3_exec(self._ptr, sql, nil, nil, nil)
	if rc ~= 0 then return failure(self, rc) end
	return true
end

function DB:prepare(sql)
	if not self._ptr then return nil, "database closed" end
	if not sql_valid(sql) then return nil, "SQL must be a non-empty string without NUL" end
	local out, tail = ffi.new("sqlite3_stmt *[1]"), ffi.new("const char *[1]")
	local rc = lib.sqlite3_prepare_v2(self._ptr, sql, #sql + 1, out, tail)
	if rc ~= 0 then return failure(self, rc) end
	if out[0] == nil then return nil, "SQL contains no statement" end
	if tail[0] ~= nil and ffi.string(tail[0]):match("%S") then
		lib.sqlite3_finalize(out[0])
		return nil, "prepare accepts exactly one statement"
	end
	local stmt = setmetatable({ _db = self, _ptr = ffi.gc(out[0], lib.sqlite3_finalize) }, Stmt)
	self._statements[stmt] = true
	return stmt
end

function Stmt:bind(index, value)
	if not self._ptr then return nil, "statement finalized" end
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1
		or index > lib.sqlite3_bind_parameter_count(self._ptr) then return nil, "invalid bind index" end
	local rc
	if value == M.NULL or value == nil then rc = lib.sqlite3_bind_null(self._ptr, index)
	elseif type(value) == "string" then
		rc = lib.sqlite3_bind_text(self._ptr, index, value, #value, transient)
	elseif type(value) == "boolean" then rc = lib.sqlite3_bind_int64(self._ptr, index, value and 1 or 0)
	elseif type(value) == "cdata" and ffi.istype("int64_t", value) then
		rc = lib.sqlite3_bind_int64(self._ptr, index, value)
	elseif type(value) == "number" and value == value and math.abs(value) < math.huge then
		rc = lib.sqlite3_bind_double(self._ptr, index, value)
	else return nil, "unsupported bind value" end
	if rc ~= 0 then return failure(self._db, rc) end
	return true
end

function Stmt:step()
	if not self._ptr then return nil, "statement finalized" end
	if self._done then return false end
	local rc = lib.sqlite3_step(self._ptr)
	if rc == 101 then self._done = true return false end
	if rc ~= 100 then return failure(self._db, rc) end
	local row = {}
	for i = 0, lib.sqlite3_column_count(self._ptr) - 1 do
		local kind = lib.sqlite3_column_type(self._ptr, i)
		local value
		if kind == 5 then value = M.NULL
		elseif kind == 1 then
			value = lib.sqlite3_column_int64(self._ptr, i)
			local n = tonumber(value)
			if math.abs(n) <= 9007199254740991 then value = n end
		elseif kind == 2 then value = lib.sqlite3_column_double(self._ptr, i)
		else
			local size = lib.sqlite3_column_bytes(self._ptr, i)
			value = size == 0 and "" or ffi.string(lib.sqlite3_column_blob(self._ptr, i), size)
		end
		row[ffi.string(lib.sqlite3_column_name(self._ptr, i))] = value
	end
	return row
end

function Stmt:reset()
	if not self._ptr then return nil, "statement finalized" end
	local rc = lib.sqlite3_reset(self._ptr)
	lib.sqlite3_clear_bindings(self._ptr)
	self._done = false
	if rc ~= 0 then return failure(self._db, rc) end
	return true
end

function Stmt:finalize()
	if not self._ptr then return true end
	local rc = lib.sqlite3_finalize(ffi.gc(self._ptr, nil))
	self._ptr = nil
	self._db._statements[self] = nil
	if rc ~= 0 then return failure(self._db, rc) end
	return true
end

function DB:close()
	if not self._ptr then return true end
	if self._transaction then return nil, "cannot close during transaction" end
	local first_error
	for stmt in pairs(self._statements) do
		local _, err = stmt:finalize()
		first_error = first_error or err
	end
	local rc = lib.sqlite3_close(self._ptr)
	if rc ~= 0 then return failure(self, rc) end
	ffi.gc(self._ptr, nil)
	self._ptr = nil
	if first_error then return nil, first_error end
	return true
end

-- Callback receives db. Returning nil,error or false,error aborts, as does
-- throwing or yielding. No nested transactions. Other callback returns succeed.
function DB:transaction(fn)
	if type(fn) ~= "function" then return nil, "transaction callback required" end
	if self._transaction then return nil, "nested transaction unsupported" end
	local begun, err = self:exec("BEGIN IMMEDIATE")
	if not begun then return nil, err end
	self._transaction = true
	local thread = coroutine.create(fn)
	local ok, result, why = coroutine.resume(thread, self)
	self._transaction = nil
	if not ok or coroutine.status(thread) ~= "dead" or result == false or (result == nil and why ~= nil) then
		local _, rollback_error = self:exec("ROLLBACK")
		return nil, tostring(not ok and result or (coroutine.status(thread) ~= "dead" and "transaction callback yielded")
			or why or "transaction aborted") .. (rollback_error and ("; " .. rollback_error) or "")
	end
	local committed, cerr = self:exec("COMMIT")
	if not committed then self:exec("ROLLBACK") return nil, cerr end
	return true
end

-- Runs fn(db, old_version) once when upgrading; downgrade is an error.
function DB:migrate(version, fn)
	if type(version) ~= "number" or version < 0 or version > 2147483647 or version % 1 ~= 0 then
		return nil, "invalid schema version"
	end
	if type(fn) ~= "function" then return nil, "migration callback required" end
	return self:transaction(function(db)
		local stmt, err = db:prepare("PRAGMA user_version")
		if not stmt then return nil, err end
		local row, serr = stmt:step()
		stmt:finalize()
		if not row then return nil, serr end
		if row.user_version > version then return nil, "schema downgrade refused" end
		if row.user_version == version then return true end
		local ok, why = fn(db, row.user_version)
		if ok == false or (ok == nil and why ~= nil) then return nil, why or "migration aborted" end
		return db:exec("PRAGMA user_version=" .. version)
	end)
end

function M.open(path, opts)
	if not lib then return nil, M.unavailable_reason end
	if not sql_valid(path) then return nil, "database path required" end
	opts = opts or {}
	if type(opts) ~= "table" then return nil, "options must be a table" end
	local timeout = opts.busy_timeout_ms or 0
	if type(timeout) ~= "number" or timeout < 0 or timeout > 2147483647 or timeout % 1 ~= 0 then
		return nil, "invalid busy_timeout_ms"
	end
	local out = ffi.new("sqlite3 *[1]")
	local rc = lib.sqlite3_open_v2(path, out, 6, nil) -- READWRITE | CREATE, no URI interpretation
	local db = setmetatable({ _ptr = out[0], _statements = {} }, DB)
	if rc ~= 0 then
		local err = out[0] ~= nil and ffi.string(lib.sqlite3_errmsg(out[0])) or "SQLite allocation failed"
		if out[0] ~= nil then lib.sqlite3_close(out[0]) end
		return nil, err
	end
	db._ptr = ffi.gc(db._ptr, lib.sqlite3_close)
	lib.sqlite3_busy_timeout(db._ptr, timeout)
	local stmt, err = db:prepare("PRAGMA journal_mode=WAL")
	if not stmt then db:close() return nil, err end
	local row, serr = stmt:step()
	stmt:finalize()
	if not row or (row.journal_mode ~= "wal" and path ~= ":memory:") then
		db:close() return nil, serr or "database does not support WAL"
	end
	local ok, perr = db:exec("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")
	if not ok then db:close() return nil, perr end
	return db
end

return M

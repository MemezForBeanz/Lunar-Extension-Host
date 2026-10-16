--- Central application logging built on LuaLogging.
-- Uses `date` for ISO-8601 timestamps and `serpent` for readable
-- table/argument formatting.
--
-- Logging across the host and plugins is level-filtered and namespaced.
-- A single call fans out to a console sink (stderr) and, optionally, a
-- size-rotated log file. Messages accept mixed arguments; any table
-- argument is pretty-printed with serpent.
--
-- **Defensive loading**: LuaLogging, `date`, and `serpent` are embedded
-- in the shipped exe and available in the dev tree, but ad-hoc scripts
-- may run without them. Every dependency is loaded with `pcall`; if
-- LuaLogging is missing the loggers fall back to writing formatted
-- lines to stderr so logging never hard-fails.
-- @module core.lib.log
-- @usage
-- local log = require("core.lib.log")
-- log.configure{ level = "INFO", file = cfg_dir .. "\\lunar.log" }
-- local l = log.get("hello")
-- l:info("build finished", record)     -- record table is serpent-formatted
-- l:dump("settings", settings_table)   -- multi-line debug dump

local ok_logging, logging = pcall(require, "logging")
local ok_console = ok_logging and pcall(require, "logging.console") or false
local ok_rolling = ok_logging and pcall(require, "logging.rolling_file") or false
local ok_date, date = pcall(require, "date")
local ok_serpent, serpent = pcall(require, "serpent")

local M = {
	--- `true` when LuaLogging is present and real sinks are active.
	available = ok_logging and true or false,
}

-- Ordinal per level, used for the stderr fallback's own filtering.
local LEVEL_ORDER = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4, FATAL = 5 }

-- Shared root configuration, resolved lazily on first use.
local root = {
	level = "INFO",
	sinks = {},     -- list of LuaLogging loggers to fan out to
	configured = false,
}

local function iso_now()
	if ok_date then
		return date():fmt("%Y-%m-%dT%H:%M:%S")
	end
	return os.date("%Y-%m-%dT%H:%M:%S")
end
--- Return the current local time as an ISO-8601 string.
-- Falls back to `os.date` when the `date` library is unavailable.
-- @treturn string ISO-8601 local timestamp, e.g. `"2024-01-15T09:30:00"`.
M.now_iso = iso_now

local function stringify(...)
	local n = select("#", ...)
	local parts = {}
	for i = 1, n do
		local v = select(i, ...)
		if type(v) == "table" then
			parts[i] = ok_serpent and serpent.line(v, { comment = false, nocode = true })
				or "<table>"
		else
			parts[i] = tostring(v)
		end
	end
	return table.concat(parts, " ")
end
--- Serialize one or more values to a single space-joined string.
-- Table arguments are rendered compactly with serpent (no code, no comment
-- markers). All other values are converted with `tostring`.
-- @param ... any values to serialize; table arguments are serpent-formatted.
-- @treturn string space-joined representation of all arguments.
M.stringify = stringify

--- (Re-)build the shared log sinks.
-- Can be called multiple times; each call tears down existing sinks before
-- constructing new ones. Calling `get` before `configure` is safe -- sinks
-- are created on first use with default options.
--
-- Timestamp, level, and namespace are rendered by this module, so the sinks
-- use a bare `"%message"` pattern to avoid double-stamping.
-- @tparam[opt] table opts configuration table.
-- @tparam[opt="INFO"] string opts.level minimum level: `"DEBUG"`, `"INFO"`, `"WARN"`, `"ERROR"`, or `"FATAL"`.
-- @tparam[opt] string opts.file path for a size-rotated file sink; omit to disable file logging.
-- @tparam[opt=524288] number opts.max_file_size bytes before the file sink rotates (default 512 KiB).
-- @tparam[opt=3] number opts.max_backup number of rotated backup files to retain.
-- @tparam[opt=true] boolean opts.console set `false` to suppress the stderr sink.
-- @treturn table the `core.lib.log` module (for chaining).
function M.configure(opts)
	opts = opts or {}
	root.level = opts.level or root.level
	root.sinks = {}

	if ok_logging and ok_console and opts.console ~= false then
		root.sinks[#root.sinks + 1] = logging.console {
			logPattern = "%message\n",
			logLevel = root.level,
		}
	end

	if ok_logging and ok_rolling and opts.file then
		local ok, file_logger = pcall(logging.rolling_file, {
			filename = opts.file,
			maxFileSize = opts.max_file_size or (512 * 1024),
			maxBackupIndex = opts.max_backup or 3,
			logPattern = "%message\n",
			logLevel = root.level,
		})
		if ok then
			root.sinks[#root.sinks + 1] = file_logger
		end
	end

	root.configured = true
	return M
end

--- Adjust the minimum log level on all existing sinks.
-- Has no effect when LuaLogging is unavailable.
-- @tparam string level new minimum level: `"DEBUG"`, `"INFO"`, `"WARN"`, `"ERROR"`, or `"FATAL"`.
function M.setLevel(level)
	if not level then
		return
	end
	root.level = level
	for _, sink in ipairs(root.sinks) do
		if type(sink.setLevel) == "function" then
			sink:setLevel(level)
		end
	end
end

--- A namespaced logger instance returned by `log.get`.
-- @type Logger
local Logger = {}
Logger.__index = Logger

local function emit(self, levelname, ...)
	if not root.configured then
		M.configure()
	end
	local line = string.format("%s %-5s [%s] %s",
		iso_now(), levelname, self.name, stringify(...))

	if #root.sinks == 0 then
		-- Fallback path when LuaLogging is unavailable: filter by level ourselves
		-- and write to stderr so diagnostics are never silently lost.
		if (LEVEL_ORDER[levelname] or 2) >= (LEVEL_ORDER[root.level] or 2) then
			io.stderr:write(line, "\n")
		end
		return
	end

	for _, sink in ipairs(root.sinks) do
		sink:log(levelname, line)
	end
end

--- Log a message at DEBUG level.
-- @param ... values to log; table arguments are serpent-formatted.
function Logger:debug(...) emit(self, "DEBUG", ...) end
--- Log a message at INFO level.
-- @param ... values to log; table arguments are serpent-formatted.
function Logger:info(...) emit(self, "INFO", ...) end
--- Log a message at WARN level.
-- @param ... values to log; table arguments are serpent-formatted.
function Logger:warn(...) emit(self, "WARN", ...) end
--- Log a message at ERROR level.
-- @param ... values to log; table arguments are serpent-formatted.
function Logger:error(...) emit(self, "ERROR", ...) end

--- Emit a DEBUG-level multi-line dump of a value via serpent.
-- Handy for inspecting decoded records, settings, or middleclass instances.
-- @tparam string label label prefix printed before the dump body.
-- @param value the value to dump; any Lua type is accepted.
function Logger:dump(label, value)
	local body
	if ok_serpent then
		body = serpent.block(value, { comment = false, nocode = true })
	else
		body = tostring(value)
	end
	emit(self, "DEBUG", (label or "dump") .. " =\n" .. body)
end

--- Get a namespaced Logger instance.
-- Names appear in each log line as `[name]`.
-- If `configure` has not been called yet, defaults are applied on first use.
-- @tparam[opt="app"] string name logger namespace identifier.
-- @treturn Logger the namespaced logger.
-- @usage
-- local log = require("core.lib.log")
-- local l = log.get("myplugin")
-- l:info("plugin loaded")
function M.get(name)
	return setmetatable({ name = name or "app" }, Logger)
end

return M

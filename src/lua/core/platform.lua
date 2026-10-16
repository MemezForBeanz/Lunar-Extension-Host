--- The one place Lunar asks the operating system for anything.
--
-- Everything outside `core.platform*` should use this module instead of
-- `os.getenv("APPDATA")`, hardcoded `\\` joins, `.dll` suffixes or Win32 FFI, so
-- the same code runs on Windows and Linux.
--
--   * `platform.os` - `"windows"`, `"linux"` or `"macos"`
--   * `platform.path` - path helper for this OS (see `core.platform.path`)
--   * folders - `config_dir()`, `cache_dir()`, `system_dir()`, `exe_dir()`,
--     `temp_dir()`, `home_dir()`
--   * `platform.clock` - `now()`, `begin_high_resolution()`,
--     `end_high_resolution()`, `reduced_motion()`
--   * `dns_domain()`, `replace_file(src, dst)`, `open(target)`, `admin_only(dir)`,
--     `register_font(path)`, `mkdirs(dir)`, `lib_ext`
--
-- Window and rendering services (overlay, redraw batching, window placement)
-- are still Win32-only and arrive with the GTK work.
--
-- @module core.platform

local is_windows = package.config:sub(1, 1) == "\\"
local backend = require(is_windows and "core.platform.win32" or "core.platform.posix")
local path = require("core.platform.path").new({ windows = is_windows })

local M = {}

local jit_os = (type(jit) == "table" and jit.os) or (is_windows and "Windows" or "Linux")

--- `"windows"`, `"linux"` or `"macos"`.
M.os = is_windows and "windows" or (jit_os == "OSX" and "macos" or "linux")
--- True on Windows.
M.is_windows = is_windows
--- Path helper for this OS.
M.path = path
--- Path separator.
M.sep = path.sep
--- File extension of native Lua modules (`"dll"` or `"so"`).
M.lib_ext = is_windows and "dll" or "so"
--- Monotonic clock and motion preferences (see the backend modules).
M.clock = backend.clock

--- Name of Lunar's folders under the per-user and system roots.
M.APP_DIR_NAME = is_windows and "Lunar Extension Host" or "lunar"

--- Per-user settings folder (`%APPDATA%\Lunar Extension Host`,
-- `~/.config/lunar`). Not created here.
-- @treturn string
function M.config_dir()
	return path:join(backend.user_config_root() or ".", M.APP_DIR_NAME)
end

--- Per-user cache folder (`%LOCALAPPDATA%\Lunar Extension Host`, `~/.cache/lunar`).
-- @treturn string
function M.cache_dir()
	return path:join(backend.user_cache_root() or M.temp_dir(), M.APP_DIR_NAME)
end

--- Machine-wide folder administrators control (`%ProgramData%\Lunar Extension
-- Host`, `/etc/lunar`), or nil when the OS won't say where it is.
-- @treturn string|nil
function M.system_dir()
	local root = backend.system_data_root()
	return root and path:join(root, M.APP_DIR_NAME) or nil
end

--- Folder holding the running executable.
-- @treturn string
function M.exe_dir()
	if type(LUNAR_EXE_DIR) == "string" and LUNAR_EXE_DIR ~= "" then return LUNAR_EXE_DIR end
	local ok, lfs = pcall(require, "lfs")
	return ok and lfs.currentdir() or "."
end

--- Create `dir` and any missing parents (like `mkdir -p`).
-- @tparam string dir
-- @treturn boolean `true` when the folder exists afterwards.
-- @treturn string|nil The failure, when it doesn't.
function M.mkdirs(dir)
	local lfs = require("lfs")
	if lfs.attributes(dir, "mode") == "directory" then return true end
	local parent = path:dirname(dir)
	if parent ~= dir and parent ~= "." and not lfs.attributes(parent) then
		local ok, err = M.mkdirs(parent)
		if not ok then return false, err end
	end
	local ok, err = lfs.mkdir(dir)
	if ok or lfs.attributes(dir, "mode") == "directory" then return true end
	return false, tostring(err)
end

M.temp_dir = backend.temp_dir
M.home_dir = backend.home_dir
M.dns_domain = backend.dns_domain
M.replace_file = backend.replace_file
M.open = backend.open
M.register_font = backend.register_font
--- `admin_only(dir)`: true when only administrators (root) can change `dir`;
-- otherwise false and the reason. Org policy is only trusted from such folders.
M.admin_only = backend.admin_only
--- Secrets in the OS store (Windows Credential Manager; the desktop keyring
-- through libsecret on Linux), for this user: `secret_get(target)` returns the
-- value or nil and "not found" / why; `secret_set(target, value)` and
-- `secret_delete(target)` return true or nil and why. There is no plaintext
-- fallback: without a store these fail. Extensions use `HostAPI:getSecret`.
M.secret_get = backend.secret_get
M.secret_set = backend.secret_set
M.secret_delete = backend.secret_delete
--- `network_login(server, user, password, remember)`: sign in to a file server
-- with an account other than the desktop login, so `\\server\...` paths work for
-- every program (Windows; on Linux the share is mounted instead and this says
-- so). `network_logout(server)` forgets it.
M.network_login = backend.network_login
M.network_logout = backend.network_logout
--- `probe_dir(path)`: `"ok"`, `"denied"`, `"missing"` or `"unreachable"`, for
-- telling a folder this account may not read from one that isn't there.
M.probe_dir = backend.probe_dir

return M

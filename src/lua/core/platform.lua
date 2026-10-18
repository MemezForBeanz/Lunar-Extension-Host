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
--   * `move_window(iup, dlg, x, y)` - move a mapped dialog without resizing,
--     activating or restacking it
--
-- Rendering services (the compositor, redraw batching) live in `core.lib.Compositor`
-- and the native `compositor` module.
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

--- Folder holding the running executable (`LUNAR_EXE_DIR` from the C host).
-- A packaged GUI build that doesn't know it raises an error rather than
-- returning the working directory; dev builds and the CLI fall back to the cwd.
-- @treturn string
function M.exe_dir()
	if type(LUNAR_EXE_DIR) == "string" and LUNAR_EXE_DIR ~= "" then return LUNAR_EXE_DIR end
	if LUNAR_DEV_BUILD == false then
		error("the executable's folder is unknown (LUNAR_EXE_DIR not set)", 2)
	end
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
--- `apply_native_style([css])`: bring the toolkit's native widgets (GTK menu bar,
-- text entries) to the density Lunar's layout expects. Call once after IupOpen,
-- before building windows. Returns false and why where there is nothing to do.
M.apply_native_style = backend.apply_native_style
--- `set_app_icon(dir)`: make lunar-<size>.png in `dir` every window's icon where
-- the toolkit needs that at runtime (GTK); Windows uses the exe's icon resource.
M.set_app_icon = backend.set_app_icon
--- `system_dark()`: true when the OS is in dark mode, false in light mode, nil
-- when it can't tell (Windows app mode; the desktop's color scheme on Linux).
M.system_dark = backend.system_dark
--- `system_dark_probe()`: the same question without blocking, where asking means
-- running programs (Linux): a probe with `poll() -> done, dark` and `cancel()`.
-- nil on platforms where `system_dark` is already instant (Windows).
M.system_dark_probe = backend.system_dark_probe
--- `move_window(iup, dlg, x, y)`: move a mapped dialog to screen position
-- `x, y` without resizing, activating or restacking it. True when the window
-- was asked to move; false where the platform can't (native Wayland, no FFI).
M.move_window = backend.move_window

-- Directory-relative installer I/O (POSIX). Parent components and opened files
-- reject symlinks; temporary files use exclusive creation.
M.secure_mkdir = backend.secure_mkdir
M.secure_read = backend.secure_read
M.secure_write = backend.secure_write
M.secure_remove = backend.secure_remove
M.secure_symlink = backend.secure_symlink
M.secure_parent = backend.secure_parent

--- `set_mode(file, mode)`: set a file's permission bits (`tonumber("755", 8)`).
-- POSIX only; Windows has no such bits and reports success without doing anything.
-- @treturn boolean
-- @treturn string|nil Why not.
function M.set_mode(file, mode)
	if backend.set_mode then return backend.set_mode(file, mode) end
	return true
end

--- `launch(path)`: start the program at `path` detached, so it keeps running
-- after Lunar exits. Unlike `spawn`, nothing ties its lifetime to ours.
-- @treturn boolean
-- @treturn string|nil Why not.
M.launch = backend.launch

--- Start a program (an argv array, never a shell string) as a background job.
-- @tparam table argv program and arguments.
-- @tparam[opt] table opts `cwd`, `env` (see the native `process` module).
-- @treturn[1] table job with `poll()` (exit code once finished, else nil; also
--   drains the output), `output()` (the tail of stdout and stderr so far) and
--   `close()` (ends it if still running).
-- @treturn[2] nil
-- @treturn[2] string why it couldn't start.
function M.spawn(argv, opts)
	local ok_mod, process = pcall(require, "process")
	if not ok_mod then return nil, "process module unavailable" end
	opts = opts or {}
	local proc, err = process.spawn({ argv = argv, cwd = opts.cwd, env = opts.env })
	if not proc then return nil, err end
	local tail = ""
	local open = { stdout = true, stderr = true }
	local function drain()
		for name in pairs(open) do
			local data = proc:read(name, 8192)
			if data == nil then open[name] = nil
			elseif #data > 0 then
				tail = (tail .. data):sub(-16384)
			end
		end
	end
	return {
		poll = function()
			drain()
			local code = proc:poll()
			if code ~= nil then drain() end
			return code
		end,
		output = function() return tail end,
		close = function() proc:close() end,
	}
end

--- Run `argv` with administrator rights (UAC on Windows, polkit's `pkexec` on
-- Linux). Returns the same kind of job as `spawn`; declining the prompt gives nil
-- and `"cancelled"`.
-- @tparam table argv program and arguments.
function M.elevate(argv)
	if backend.elevate then return backend.elevate(argv) end
	-- pkexec exits 126 when the user dismisses the dialog, 127 when not authorized.
	return M.spawn(backend.elevate_argv(argv))
end

--- `msi_installed_features(upgrade_code, features)`: Windows Installer features of
-- the product family that are installed locally, `{ [id] = true }`, or nil when
-- the product isn't installed (always nil off Windows).
function M.msi_installed_features(upgrade_code, features)
	if backend.msi_installed_features then return backend.msi_installed_features(upgrade_code, features) end
	return nil
end

--- The folder 64-bit programs install under on Windows; nil elsewhere.
function M.program_files_dir()
	if backend.program_files_dir then return backend.program_files_dir() end
	return nil
end

return M

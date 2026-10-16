--- Linux/POSIX backend for `core.platform`. Use `core.platform`, not this module.
--
-- Folders follow the XDG base directory spec. Calls that need the C library go
-- through LuaJIT FFI and are guarded.
--
-- @module core.platform.posix

local M = {}

local ok_ffi, ffi = pcall(require, "ffi")
if not ok_ffi then ffi = nil end

if ffi then
	pcall(ffi.cdef, [[
		typedef struct { long tv_sec; long tv_nsec; } lunar_timespec;
		int clock_gettime(int clk_id, lunar_timespec *tp);
	]])
end

local function env(name)
	local v = os.getenv(name)
	if v and v ~= "" then return v end
	return nil
end

function M.home_dir()
	return env("HOME") or "/tmp"
end

--- `$XDG_CONFIG_HOME`, or `~/.config`.
function M.user_config_root()
	return env("XDG_CONFIG_HOME") or (M.home_dir() .. "/.config")
end

--- `$XDG_CACHE_HOME`, or `~/.cache`.
function M.user_cache_root()
	return env("XDG_CACHE_HOME") or (M.home_dir() .. "/.cache")
end

--- Machine-wide config root (`/etc`). Org policy lives under it.
function M.system_data_root()
	return "/etc"
end

function M.temp_dir()
	return env("TMPDIR") or "/tmp"
end

--- The local domain from /etc/resolv.conf, or nil. `domain` and `search` are
-- mutually exclusive and the last one in the file wins (resolv.conf(5)); for
-- `search` the first listed domain is the local one.
function M.dns_domain()
	local f = io.open("/etc/resolv.conf", "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	return M.parse_resolv_domain(text)
end

--- The local domain named by resolv.conf `text` (see `dns_domain`), or nil.
-- @tparam string text
-- @treturn string|nil
function M.parse_resolv_domain(text)
	local found
	for line in (text or ""):gmatch("[^\n]+") do
		found = line:match("^%s*domain%s+([^%s#;]+)")
			or line:match("^%s*search%s+([^%s#;]+)")
			or found
	end
	return found
end

--- Process-private font registration. Not implemented yet on Linux (it needs
-- fontconfig, done with the GTK work); fonts installed system-wide still work.
function M.register_font(_path)
	return false, "font registration is not supported on this platform yet"
end

--- The `admin_only` rule on `lfs.attributes` output (separate so specs can test it
-- on any OS): owned by root, not a symlink, and with no group or world write bit.
-- Group write is refused even for group root: with an extended ACL those bits
-- are the ACL mask, which can let a named user write.
-- @tparam table attrs `{ mode, uid, gid, permissions }` from `lfs.attributes`.
-- @treturn boolean
-- @treturn string|nil Why not.
function M.admin_only_attrs(attrs)
	if type(attrs) ~= "table" or (attrs.mode ~= "directory" and attrs.mode ~= "file") then
		return false, "not found"
	end
	local perms = attrs.permissions
	if type(perms) ~= "string" or #perms ~= 9 then return false, "cannot read permissions" end
	if attrs.uid ~= 0 then return false, "owned by uid " .. tostring(attrs.uid) .. ", not root" end
	if perms:sub(8, 8) == "w" then return false, "anyone can modify it" end
	if perms:sub(5, 5) == "w" then return false, "its group can modify it" end
	return true
end

--- Is the folder or file `dir` protected so only root can change it? See
-- `admin_only_attrs`.
-- @tparam string dir
-- @treturn boolean
-- @treturn string|nil Why not.
function M.admin_only(dir)
	local ok, lfs = pcall(require, "lfs")
	if not ok then return false, "lfs unavailable" end
	local link = lfs.symlinkattributes and lfs.symlinkattributes(dir, "mode")
	if link == "link" then return false, "is a symlink" end
	return M.admin_only_attrs(lfs.attributes(dir))
end

--- Replace `dst` with `src` atomically (rename(2) replaces in one step).
function M.replace_file(src, dst)
	return os.rename(src, dst) and true or false
end

-- Quote one argument for /bin/sh.
local function shq(s)
	return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Open a file, folder or URL with the desktop's default application.
function M.open(target)
	local ok = os.execute("xdg-open " .. shq(target) .. " >/dev/null 2>&1 &")
	if ok == 0 or ok == true then return true end
	return false, "could not open " .. tostring(target)
end

-- ---------------------------------------------------------------------------
-- Secrets: the desktop keyring through libsecret's secret-tool. The value goes
-- through stdin/stdout only, never the command line. Without secret-tool there
-- is no store; nothing falls back to a plaintext file.
-- ---------------------------------------------------------------------------

local function secret_tool()
	local p = io.popen("command -v secret-tool 2>/dev/null")
	local found = p and p:read("*l")
	if p then p:close() end
	return found and found ~= ""
end

local function secret_attrs(target)
	return "service lunar target " .. shq(target)
end

function M.secret_get(target)
	if not secret_tool() then return nil, "no keyring (install libsecret-tools)" end
	local p = io.popen("secret-tool lookup " .. secret_attrs(target) .. " 2>/dev/null")
	if not p then return nil, "secret-tool failed" end
	local value = p:read("*a")
	p:close()
	if not value or value == "" then return nil, "not found" end
	return value
end

function M.secret_set(target, value)
	if not secret_tool() then return nil, "no keyring (install libsecret-tools)" end
	local p = io.popen("secret-tool store --label=" .. shq("Lunar: " .. target) .. " "
		.. secret_attrs(target) .. " >/dev/null 2>&1", "w")
	if not p then return nil, "secret-tool failed" end
	p:write(value)
	p:close()
	-- popen can't report the exit status in Lua 5.1: confirm by reading it back.
	if M.secret_get(target) ~= value then return nil, "the keyring did not store the secret" end
	return true
end

function M.secret_delete(target)
	if not secret_tool() then return nil, "no keyring (install libsecret-tools)" end
	os.execute("secret-tool clear " .. secret_attrs(target) .. " >/dev/null 2>&1")
	return true
end

--- Network shares are mounted by the system on Linux (fstab, gio mount, autofs);
-- Lunar then reads the mounted folder like any other.
function M.network_login(server)
	return nil, "on Linux, mount //" .. tostring(server) .. " (e.g. with gio mount or /etc/fstab) "
		.. "and choose the mounted folder"
end

function M.network_logout()
	return true
end

--- Can this folder be listed? `"ok"`, `"denied"` or `"missing"`.
function M.probe_dir(path)
	local ok, err = pcall(function()
		local iter, state = require("lfs").dir(path)
		iter(state)   -- reading one entry is enough to know it can be listed
	end)
	if ok then return "ok" end
	if tostring(err):find("ermission denied") then return "denied" end
	return "missing"
end

-- ---------------------------------------------------------------------------
-- Clock
-- ---------------------------------------------------------------------------

local clock = {}
M.clock = clock

local ts = ffi and ffi.new("lunar_timespec")
local CLOCK_MONOTONIC = (ffi and ffi.os == "OSX") and 6 or 1
-- The symbol lookup happens inside the closure: indexing ffi.C for a missing
-- symbol raises, and must not escape when this module loads somewhere odd.
clock.precise = ts ~= nil and pcall(function() return ffi.C.clock_gettime(CLOCK_MONOTONIC, ts) end)

local origin
--- Monotonic seconds since an arbitrary origin (clock_gettime MONOTONIC).
function clock.now()
	if clock.precise and ffi.C.clock_gettime(CLOCK_MONOTONIC, ts) == 0 then
		local t = tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) / 1e9
		if not origin then origin = t end
		return t - origin
	end
	return os.time()
end

-- Linux timers are already fine-grained; nothing to request.
function clock.begin_high_resolution() return true end
function clock.end_high_resolution() end

local reduced_cache, reduced_at

--- GNOME's `enable-animations` setting, inverted. nil when unknown.
-- Read through gsettings and cached for a few seconds, since the motion driver
-- asks before every animation; the GTK backend will replace this.
function clock.reduced_motion()
	local t = clock.now()
	if reduced_at and t - reduced_at < 5 then return reduced_cache end
	reduced_at = t
	reduced_cache = nil
	local p = io.popen("gsettings get org.gnome.desktop.interface enable-animations 2>/dev/null")
	if not p then return nil end
	local out = p:read("*a") or ""
	p:close()
	if out:match("false") then reduced_cache = true
	elseif out:match("true") then reduced_cache = false end
	return reduced_cache
end

return M

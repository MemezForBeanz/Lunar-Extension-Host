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
		int chmod(const char *path, unsigned int mode);
		int open(const char *path, int flags, ...);
		int openat(int dirfd, const char *path, int flags, ...);
		int mkdirat(int dirfd, const char *path, unsigned int mode);
		int unlinkat(int dirfd, const char *path, int flags);
		int renameat(int olddirfd, const char *oldpath, int newdirfd, const char *newpath);
		int renameat2(int olddirfd, const char *oldpath, int newdirfd, const char *newpath, unsigned int flags);
		int symlinkat(const char *target, int dirfd, const char *linkpath);
		int fchmod(int fd, unsigned int mode);
		long read(int fd, void *buf, unsigned long count);
		long write(int fd, const void *buf, unsigned long count);
		int close(int fd);
	]])
end

-- Installer operations hold a descriptor for every parent lookup. O_NOFOLLOW
-- prevents a substituted directory or leaf from redirecting privileged I/O.
local O_RDONLY, O_WRONLY, O_CREAT, O_EXCL = 0, 1, 64, 128
local O_DIRECTORY, O_NOFOLLOW, AT_REMOVEDIR = 65536, 131072, 512
local function fs_error(path)
	return tostring(path) .. ": " .. (ffi and ffi.string(ffi.C.strerror(ffi.errno())) or "filesystem error")
end
if ffi then pcall(ffi.cdef, "char *strerror(int errnum);") end

local function parent_fd(path, create, made)
	if not ffi or type(path) ~= "string" or path:sub(1, 1) ~= "/" or
		path:find("//", 1, true) or path:find("[%c]") then return nil, nil, "invalid absolute path" end
	local parts = {}
	for part in path:gmatch("[^/]+") do
		if part == "." or part == ".." then return nil, nil, "invalid path component" end
		parts[#parts + 1] = part
	end
	if #parts == 0 then return nil, nil, "invalid path" end
	local fd = ffi.C.open("/", O_RDONLY + O_DIRECTORY + O_NOFOLLOW)
	if fd < 0 then return nil, nil, fs_error("/") end
	local current = ""
	for i = 1, #parts - 1 do
		local part = parts[i]
		current = current .. "/" .. part
		local nextfd = ffi.C.openat(fd, part, O_RDONLY + O_DIRECTORY + O_NOFOLLOW)
		if nextfd < 0 and create then
			if ffi.C.mkdirat(fd, part, tonumber("755", 8)) == 0 then
				if made then made[#made + 1] = current end
			end
			nextfd = ffi.C.openat(fd, part, O_RDONLY + O_DIRECTORY + O_NOFOLLOW)
		end
		ffi.C.close(fd)
		if nextfd < 0 then return nil, nil, fs_error(current) end
		fd = nextfd
	end
	return fd, parts[#parts]
end

function M.secure_mkdir(path, made)
	local fd, leaf, err = parent_fd(path, true, made)
	if not fd then return nil, err end
	local dir = ffi.C.openat(fd, leaf, O_RDONLY + O_DIRECTORY + O_NOFOLLOW)
	if dir < 0 then
		if ffi.C.mkdirat(fd, leaf, tonumber("755", 8)) == 0 then
			if made then made[#made + 1] = path end
		end
		dir = ffi.C.openat(fd, leaf, O_RDONLY + O_DIRECTORY + O_NOFOLLOW)
	end
	ffi.C.close(fd)
	if dir < 0 then return nil, fs_error(path) end
	ffi.C.close(dir)
	return true
end

function M.secure_read(path)
	local fd, leaf, err = parent_fd(path)
	if not fd then return nil, err end
	local input = ffi.C.openat(fd, leaf, O_RDONLY + O_NOFOLLOW)
	ffi.C.close(fd)
	if input < 0 then return nil, fs_error(path) end
	local chunks, buf = {}, ffi.new("uint8_t[65536]")
	while true do
		local n = ffi.C.read(input, buf, 65536)
		if n < 0 then ffi.C.close(input) return nil, fs_error(path) end
		if n == 0 then break end
		chunks[#chunks + 1] = ffi.string(buf, tonumber(n))
	end
	ffi.C.close(input)
	return table.concat(chunks)
end

function M.secure_write(path, content, source, mode, replace)
	local fd, leaf, err = parent_fd(path)
	if not fd then return nil, err end
	local tmp = leaf .. ".lunar-new"
	local out = ffi.C.openat(fd, tmp, O_WRONLY + O_CREAT + O_EXCL + O_NOFOLLOW, tonumber("600", 8))
	if out < 0 then ffi.C.close(fd) return nil, fs_error(path .. ".lunar-new") end
	local function fail(why)
		ffi.C.close(out)
		ffi.C.unlinkat(fd, tmp, 0)
		ffi.C.close(fd)
		return nil, why
	end
	if source then
		content, err = M.secure_read(source)
		if not content then return fail(err) end
	end
	content = content or ""
	local offset = 0
	while offset < #content do
		local n = ffi.C.write(out, content:sub(offset + 1), #content - offset)
		if n <= 0 then return fail(fs_error(path)) end
		offset = offset + tonumber(n)
	end
	if ffi.C.fchmod(out, mode or tonumber("644", 8)) ~= 0 then return fail(fs_error(path)) end
	ffi.C.close(out)
	local rc = replace and ffi.C.renameat(fd, tmp, fd, leaf)
		or ffi.C.renameat2(fd, tmp, fd, leaf, 1)  -- RENAME_NOREPLACE
	if rc ~= 0 then
		ffi.C.unlinkat(fd, tmp, 0)
		ffi.C.close(fd)
		return nil, fs_error(path)
	end
	ffi.C.close(fd)
	return true
end

function M.secure_remove(path, directory)
	local fd, leaf, err = parent_fd(path)
	if not fd then return nil, err end
	local rc = ffi.C.unlinkat(fd, leaf, directory and AT_REMOVEDIR or 0)
	local why = rc ~= 0 and fs_error(path) or nil
	ffi.C.close(fd)
	return rc == 0 or nil, why
end

function M.secure_symlink(target, path)
	local fd, leaf, err = parent_fd(path)
	if not fd then return nil, err end
	local rc = ffi.C.symlinkat(target, fd, leaf)
	local why = rc ~= 0 and fs_error(path) or nil
	ffi.C.close(fd)
	return rc == 0 or nil, why
end

function M.secure_parent(path)
	local fd, _, err = parent_fd(path)
	if not fd then return nil, err end
	ffi.C.close(fd)
	return true
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

--- Process-private font registration through fontconfig (the host links it).
-- The font is added to this process's fontconfig configuration only, then
-- Pango is told the configuration changed so widgets can use the family at
-- once. Fonts the host finds under assets/Themes are registered in C at startup.
-- @tparam string path font file (`.ttf`, `.otf`, `.ttc`)
-- @treturn boolean
-- @treturn string|nil why not
function M.register_font(path)
	if not ffi then return false, "font registration needs LuaJIT FFI" end
	pcall(ffi.cdef, [[
		int FcConfigAppFontAddFile(void *config, const unsigned char *file);
		void *pango_cairo_font_map_get_default(void);
		void pango_fc_font_map_config_changed(void *fcfontmap);
	]])
	-- Symbol lookups stay inside pcall: outside the GUI host (the CLI, specs)
	-- fontconfig and Pango aren't loaded and indexing ffi.C raises.
	local ok, added = pcall(function()
		return ffi.C.FcConfigAppFontAddFile(nil, ffi.cast("const unsigned char *", path))
	end)
	if not ok then return false, "fontconfig unavailable" end
	if added == 0 then return false, "could not load font " .. tostring(path) end
	pcall(function()
		ffi.C.pango_fc_font_map_config_changed(ffi.C.pango_cairo_font_map_get_default())
	end)
	return true
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


--- Set a file's permission bits (`mode` as in chmod(2), e.g. `tonumber("755", 8)`).
function M.set_mode(path, mode)
	if not ffi then return false, "ffi unavailable" end
	local ok, rc = pcall(function() return ffi.C.chmod(path, mode) end)
	if ok and rc == 0 then return true end
	return false, "chmod failed for " .. tostring(path)
end

--- Start the program at `path` detached, so it keeps running after this one exits.
function M.launch(path)
	local ok = os.execute("setsid " .. shq(path) .. " >/dev/null 2>&1 </dev/null &")
	if ok == 0 or ok == true then return true end
	return false, "could not start " .. tostring(path)
end

--- Run `argv` as root through polkit. Returns the argv to spawn.
function M.elevate_argv(argv)
	local out = { "pkexec" }
	for _, a in ipairs(argv) do out[#out + 1] = a end
	return out
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
-- Light or dark desktop
-- ---------------------------------------------------------------------------

--- Decide dark/light from what the desktop reports (separate so specs can test
-- it): the XDG portal's `org.freedesktop.appearance color-scheme` (1 dark, 2
-- light, 0 no preference), then GNOME's `color-scheme`, then whether the GTK
-- theme's name says "dark". nil when nothing says.
-- @tparam string portal gdbus output, e.g. "(<uint32 1>,)" or "(<<uint32 1>>,)"
-- @tparam string scheme gsettings output, e.g. "'prefer-dark'"
-- @tparam string gtk_theme gsettings output, e.g. "'Mint-Y-Dark-Red'"
-- @treturn boolean|nil
function M.parse_dark(portal, scheme, gtk_theme)
	local v = tostring(portal or ""):match("uint32 (%d+)")
	if v == "1" then return true elseif v == "2" then return false end
	scheme = tostring(scheme or "")
	if scheme:find("prefer%-dark") then return true end
	if scheme:find("prefer%-light") then return false end
	gtk_theme = tostring(gtk_theme or ""):gsub("^%s*'?", ""):gsub("'?%s*$", "")
	if gtk_theme ~= "" then return gtk_theme:lower():find("dark", 1, true) ~= nil end
	return nil
end

local PORTAL = { "gdbus", "call", "--session", "--timeout", "1",
	"--dest", "org.freedesktop.portal.Desktop",
	"--object-path", "/org/freedesktop/portal/desktop" }

-- The questions, in order; the first that gets an answer wins.
local function dark_steps()
	local function portal(method)
		local argv = {}
		for i, v in ipairs(PORTAL) do argv[i] = v end
		for _, v in ipairs({ "--method", "org.freedesktop.portal.Settings." .. method,
			"org.freedesktop.appearance", "color-scheme" }) do argv[#argv + 1] = v end
		return { argv = argv, parse = function(out) return M.parse_dark(out, nil, nil) end }
	end
	return {
		portal("ReadOne"),
		portal("Read"),     -- portals older than version 2
		{ argv = { "gsettings", "get", "org.gnome.desktop.interface", "color-scheme" },
			parse = function(out) return M.parse_dark(nil, out, nil) end },
		{ argv = { "gsettings", "get", "org.gnome.desktop.interface", "gtk-theme" },
			parse = function(out) return M.parse_dark(nil, nil, out) end },
	}
end

--- Ask the desktop whether it is dark, without blocking: a probe that runs the
-- sources `parse_dark` describes one after another as child processes (argv,
-- no shell) and is advanced by calling `poll()` from a timer. The whole probe
-- has one deadline; a source that hangs (an unresponsive portal) is killed then
-- and the answer is nil.
-- @tparam[opt] table opts `{ timeout = 2, process = <module>, now = fn }` (specs inject these)
-- @treturn table|nil probe with `poll() -> done, dark` and `cancel()`; nil without
--   the process module
function M.system_dark_probe(opts)
	opts = opts or {}
	local proc = opts.process
	if not proc then
		local ok, mod = pcall(require, "process")
		if not ok then return nil end
		proc = mod
	end
	local now = opts.now or function() return M.clock.now() end
	local deadline = now() + (opts.timeout or 2)
	local steps, i = dark_steps(), 0
	local current, out
	local probe = { done = false }

	local function finish(value)
		if current then pcall(current.close, current) end
		current = nil
		probe.done, probe.value = true, value
	end

	local function start_next()
		while true do
			i = i + 1
			if not steps[i] then return finish(nil) end
			local ok, p = pcall(proc.spawn, { argv = steps[i].argv })
			if ok and p then current, out = p, {} return end
			-- Not installed: on to the next source.
		end
	end

	function probe.poll()
		if probe.done then return true, probe.value end
		if now() > deadline then
			if current then pcall(current.kill, current) end
			finish(nil)
			return true, nil
		end
		if not current then start_next() if probe.done then return true, nil end end
		-- Drain stdout (stderr is read and dropped so the child never blocks on it).
		while true do
			local chunk = current:read("stdout")
			if chunk == nil or chunk == "" then break end
			out[#out + 1] = chunk
		end
		while (current:read("stderr") or "") ~= "" do end
		if current:poll() == nil then return false end
		local rest = current:read("stdout")
		if rest and rest ~= "" then out[#out + 1] = rest end
		local found = steps[i].parse(table.concat(out))
		pcall(current.close, current)
		current = nil
		if found ~= nil then finish(found) return true, found end
		start_next()
		return probe.done, probe.value
	end

	function probe.cancel()
		if current then pcall(current.kill, current) end
		finish(nil)
	end

	return probe
end

if ffi then pcall(ffi.cdef, "int poll(void *fds, unsigned long nfds, int timeout);") end

--- Is the desktop in dark mode? `system_dark_probe` run to completion, so it
-- blocks for at most its deadline (startup and the Settings toggle use this;
-- the "Match system theme" timer polls the probe instead).
-- @treturn boolean|nil
function M.system_dark()
	local probe = M.system_dark_probe()
	if not probe then return nil end
	while true do
		local done, dark = probe.poll()
		if done then return dark end
		if ffi then pcall(function() ffi.C.poll(nil, 0, 5) end) end
	end
end

-- ---------------------------------------------------------------------------
-- Native widget style (GTK)
-- ---------------------------------------------------------------------------

--- Lunar's base stylesheet for the few native GTK widgets IUP uses (menu bar,
-- text entries). Desktop themes pad these for touch-friendly sizes: Mint-Y's
-- entries are 34px+ tall and its menu bar taller than IUP lays out for, which
-- made the Settings search field a 62px row and pushed the header under the
-- menu bar. This brings them to the density the layout is designed for (the
-- same as Windows); colours stay the desktop theme's for now.
M.BASE_CSS = [[
menubar { padding: 0; min-height: 0; }
menubar > menuitem { padding: 3px 8px; min-height: 0; }
entry { min-height: 0; padding: 2px 4px; }
]]

--- Install `css` (default `M.BASE_CSS`) for every GTK widget in this process, at
-- application priority so it beats the desktop theme. Call after IupOpen and
-- before the windows are built. No-op (false + why) outside a GTK host.
-- @tparam[opt] string css
-- @treturn boolean
-- @treturn string|nil why not
function M.apply_native_style(css)
	if not ffi then return false, "needs LuaJIT FFI" end
	css = css or M.BASE_CSS
	pcall(ffi.cdef, [[
		void *gtk_css_provider_new(void);
		int gtk_css_provider_load_from_data(void *provider, const char *data, long length, void **error);
		void *gdk_screen_get_default(void);
		void gtk_style_context_add_provider_for_screen(void *screen, void *provider, unsigned int priority);
		void g_object_unref(void *object);
	]])
	-- Inside pcall: outside the GUI host GTK isn't loaded and indexing ffi.C raises.
	local ok, err = pcall(function()
		local screen = ffi.C.gdk_screen_get_default()
		if screen == nil then error("no GDK screen") end
		local provider = ffi.C.gtk_css_provider_new()
		local loaded = ffi.C.gtk_css_provider_load_from_data(provider, css, #css, nil) ~= 0
		if loaded then
			ffi.C.gtk_style_context_add_provider_for_screen(screen, provider, 600)   -- APPLICATION
		end
		-- The screen holds its own reference to an installed provider.
		ffi.C.g_object_unref(provider)
		if not loaded then error("stylesheet rejected") end
	end)
	if not ok then return false, tostring(err) end
	return true
end

-- The PNG sizes `set_app_icon` looks for (assets/app-icon/lunar-<size>.png).
M.APP_ICON_SIZES = { 16, 24, 32, 48, 64, 128, 256 }

--- Give every window the Lunar icon: GTK's default icon list, which a window
-- without its own icon uses for its title bar, the taskbar/panel and Alt+Tab
-- (`_NET_WM_ICON`). IUP's `ICON="IUP"` names a Windows resource and is ignored
-- on GTK, so this is what puts the icon on Linux windows. Call after IupOpen and
-- before the windows are shown.
-- @tparam string dir folder holding lunar-<size>.png
-- @treturn boolean
-- @treturn string|nil why not
function M.set_app_icon(dir)
	if not ffi then return false, "needs LuaJIT FFI" end
	pcall(ffi.cdef, [[
		typedef struct _LunarGList { void *data; struct _LunarGList *next, *prev; } LunarGList;
		void *gdk_pixbuf_new_from_file(const char *filename, void **error);
		LunarGList *g_list_append(LunarGList *list, void *data);
		void g_list_free(LunarGList *list);
		void gtk_window_set_default_icon_list(LunarGList *list);
	]])
	pcall(ffi.cdef, "void g_object_unref(void *object);")   -- may already be declared
	local ok, err = pcall(function()
		local list, pixbufs = nil, {}
		for _, size in ipairs(M.APP_ICON_SIZES) do
			local path = dir .. "/lunar-" .. size .. ".png"
			local f = io.open(path, "rb")
			if f then
				f:close()
				local pb = ffi.C.gdk_pixbuf_new_from_file(path, nil)
				if pb ~= nil then
					pixbufs[#pixbufs + 1] = pb
					list = ffi.C.g_list_append(list, pb)
				end
			end
		end
		if #pixbufs == 0 then error("no icons in " .. tostring(dir)) end
		ffi.C.gtk_window_set_default_icon_list(list)   -- GTK takes its own references
		ffi.C.g_list_free(list)
		for _, pb in ipairs(pixbufs) do ffi.C.g_object_unref(pb) end
	end)
	if not ok then return false, tostring(err) end
	return true
end

--- Move a mapped dialog (GtkWindow) without resizing it. A no-op returning false
-- on native Wayland, where clients can't place their own windows.
-- @param iup the IUP binding (unused here)
-- @param dlg IUP dialog handle
-- @tparam number x screen x
-- @tparam number y screen y
-- @treturn boolean
function M.move_window(iup, dlg, x, y)
	if not ffi then return false end
	local ok_iupffi, IupFFI = pcall(require, "core.classes.IupFFI")
	if not (ok_iupffi and IupFFI.available) then return false end
	pcall(ffi.cdef, "void gtk_window_move(void *window, int x, int y);")
	local ok, moved = pcall(function()
		if os.getenv("WAYLAND_DISPLAY") and not os.getenv("DISPLAY") then return false end
		local p = IupFFI.ptr(dlg)
		if p == nil then return false end
		local window = IupFFI.getptr(p, "WID")   -- the GtkWindow of a dialog
		if window == nil then return false end
		ffi.C.gtk_window_move(window, x, y)
		return true
	end)
	return ok and moved or false
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

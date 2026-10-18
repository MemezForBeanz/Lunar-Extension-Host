--- The Linux installer: copies the app folder, a launcher link, a menu entry and
-- icons, and records exactly what it put where so it can upgrade and uninstall.
--
-- Two install types:
--
--   * `user` ("Just for me"): `~/.local/opt/lunar`, `~/.local/bin/lunar`,
--     `~/.local/share/applications`, `~/.local/share/icons`.
--   * `system` ("Everyone"): `/opt/lunar`, `/usr/local/bin/lunar`,
--     `/usr/share/applications`, `/usr/share/icons`. Needs root: the installer
--     starts `setup/root_helper.lua` through `pkexec` (an argv array, no shell).
--     The helper never trusts a plan from outside; it is told the payload folder and
--     the extension ids and rebuilds the plan itself with `build_plan`.
--
-- Everything is a list of steps (`Executor`), so a window can run a few per timer
-- tick and show progress, and a test can run them all at once into a temp folder
-- (`opts.root` for system installs, `opts.home` for user installs).
--
-- The install record `<app>/install.json` lists every file, link and folder the
-- installer made. Uninstall removes exactly those, and only when they sit under the
-- recorded install locations.
--
-- @module installer.linux

local lfs = require("lfs")
local plan_mod = require("installer.plan")
local platform = require("core.platform")

local M = {}

M.ICON_SIZES = { 16, 24, 32, 48, 64, 128, 256 }
M.RECORD = "install.json"
local function join(a, b) return a .. "/" .. b end

local function exists(path) return lfs.symlinkattributes(path, "mode") ~= nil end

-- Single-quote one word for /bin/sh.
local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

-- One argument of a .desktop Exec line (Desktop Entry spec: double-quoted, with
-- ", `, $ and \ backslash-escaped, and % doubled).
local function desktop_arg(s)
	return '"' .. tostring(s):gsub('([\\"`$])', "\\%1"):gsub("%%", "%%%%") .. '"'
end

-- A path is safe to put in generated files if it has no control characters.
local function printable(path) return not tostring(path):find("[%c]") end

--- Where each install type puts things.
-- @tparam string mode `"user"` or `"system"`.
-- @tparam[opt] table opts `home` (user installs; default the real home folder),
--   `root` (prefix for system installs, default none).
-- @treturn table `{ mode, app, bin, apps, icons }`.
function M.targets(mode, opts)
	opts = opts or {}
	if mode == "system" then
		local r = (opts.root or ""):gsub("/+$", "")
		return { mode = "system", app = r .. "/opt/lunar", bin = r .. "/usr/local/bin",
			apps = r .. "/usr/share/applications", icons = r .. "/usr/share/icons" }
	end
	local home = (opts.home or platform.home_dir()):gsub("/+$", "")
	return { mode = "user", app = home .. "/.local/opt/lunar", bin = home .. "/.local/bin",
		apps = home .. "/.local/share/applications", icons = home .. "/.local/share/icons" }
end

--- The install record of `mode`, if Lunar is installed that way.
-- @treturn table|nil
function M.read_record(mode, opts)
	local t = M.targets(mode, opts)
	local rec = plan_mod.read_json(join(t.app, M.RECORD), platform.secure_read)
	if type(rec) == "table" and rec.mode == mode then return rec end
	return nil
end

--- The existing install to upgrade: a per-user one wins over a system one.
-- @treturn table|nil record
function M.find_install(opts)
	return M.read_record("user", opts) or M.read_record("system", opts)
end

local function tree_entries(payload, rel_dir, dst_dir, out, mode_fn)
	local dirs, files = plan_mod.list_tree(join(payload, rel_dir))
	if not dirs then return nil, files end
	out.dirs[#out.dirs + 1] = dst_dir
	for _, d in ipairs(dirs) do out.dirs[#out.dirs + 1] = join(dst_dir, d) end
	for _, f in ipairs(files) do
		out.files[#out.files + 1] = { src = join(join(payload, rel_dir), f), dst = join(dst_dir, f), mode = mode_fn(f) }
	end
	return true
end

local function desktop_entry(template, app)
	local lines = {}
	local saw_exec = false
	for line in (template .. "\n"):gmatch("(.-)\n") do
		if line:match("^Exec=") then
			lines[#lines + 1] = "Exec=" .. desktop_arg(join(app, "lunar"))
			saw_exec = true
		elseif line ~= "" or #lines > 0 then
			lines[#lines + 1] = line
		end
	end
	assert(saw_exec, "the menu entry template has no Exec line")
	while lines[#lines] == "" do lines[#lines] = nil end
	return table.concat(lines, "\n") .. "\n"
end

--- Work out what installing the payload with the chosen extensions would do.
--
-- @tparam string payload the folder holding `lunar`, `assets/`, `certs/`,
--   `plugins/` and `setup/`.
-- @tparam table ids extension ids to install.
-- @tparam string mode `"user"` or `"system"`.
-- @tparam[opt] table opts as `targets`, plus `version`.
-- @treturn[1] table plan `{ targets, extensions, available, dirs, files, links, version, mode }`
--   where `files` are `{ dst, src | content, mode }`.
-- @treturn[2] nil
-- @treturn[2] string why.
function M.build_plan(payload, ids, mode, opts)
	opts = opts or {}
	if lfs.symlinkattributes(payload, "mode") ~= "directory" or
		(platform.secure_parent and not platform.secure_parent(payload)) then
		return nil, "refusing symbolic link in the payload: " .. tostring(payload)
	end
	local checked, check_err = plan_mod.list_tree(payload)
	if not checked then return nil, check_err end
	local t = M.targets(mode, opts)
	for _, p in pairs(t) do
		if not printable(p) then return nil, "install path has control characters: " .. p end
	end

	local exts, _, support = plan_mod.scan_extensions(join(payload, "plugins"), { os = "linux" })
	local picked, unknown = plan_mod.select(exts, ids)
	if #unknown > 0 then return nil, "no such extension: " .. table.concat(unknown, ", ") end

	local out = { mode = mode, targets = t, dirs = {}, files = {}, links = {}, version = opts.version or "" }
	out.extensions, out.available = {}, {}
	for _, e in ipairs(picked) do out.extensions[#out.extensions + 1] = e.id end
	for _, e in ipairs(exts) do out.available[#out.available + 1] = e.id end

	local exe = join(payload, "lunar")
	if lfs.symlinkattributes(exe, "mode") ~= "file" then return nil, "the payload has no lunar executable" end
	local function plain(_) return tonumber("644", 8) end
	local function script_mode(f) return f == "lunar-cli" and tonumber("755", 8) or tonumber("644", 8) end

	out.dirs[#out.dirs + 1] = t.app
	out.files[#out.files + 1] = { src = exe, dst = join(t.app, "lunar"), mode = tonumber("755", 8) }

	for _, name in ipairs({ "assets", "certs" }) do
		local ok, err = tree_entries(payload, name, join(t.app, name), out, plain)
		if not ok then return nil, err end
	end

	-- plugins/: the folder, what isn't an extension, and each chosen extension.
	out.dirs[#out.dirs + 1] = join(t.app, "plugins")
	local function add_entry(name)
		local src, dst = join(join(payload, "plugins"), name), join(join(t.app, "plugins"), name)
		local mode_ = lfs.symlinkattributes(src, "mode")
		if mode_ == "link" then return nil, "refusing symbolic link in the payload: " .. src end
		if mode_ == "directory" then
			return tree_entries(join(payload, "plugins"), name, dst, out, plain)
		end
		out.files[#out.files + 1] = { src = src, dst = dst, mode = tonumber("644", 8) }
		return true
	end
	for _, name in ipairs(support) do
		local ok, err = add_entry(name)
		if not ok then return nil, err end
	end
	for _, e in ipairs(picked) do
		local ok, err = add_entry(e.source)
		if not ok then return nil, err end
		for _, c in ipairs(e.companions or {}) do
			ok, err = add_entry(c)
			if not ok then return nil, err end
		end
	end

	-- setup/: what uninstalling (and the root helper) needs, kept with the app.
	local setup = join(payload, "setup")
	out.dirs[#out.dirs + 1] = join(t.app, "setup")
	for _, f in ipairs({ "lunar-cli", "root_helper.lua", "uninstall.lua" }) do
		if lfs.symlinkattributes(join(setup, f), "mode") ~= "file" then
			return nil, "the payload is missing setup/" .. f
		end
		out.files[#out.files + 1] = { src = join(setup, f), dst = join(join(t.app, "setup"), f), mode = script_mode(f) }
	end
	local ok, err = tree_entries(setup, "lua", join(join(t.app, "setup"), "lua"), out, plain)
	if not ok then return nil, err end
	if lfs.symlinkattributes(join(setup, "LICENSE"), "mode") == "file" then
		out.files[#out.files + 1] = { src = join(setup, "LICENSE"), dst = join(t.app, "LICENSE"), mode = tonumber("644", 8) }
	end

	-- The uninstall command, a menu entry for it, and the launcher entry.
	out.files[#out.files + 1] = {
		dst = join(t.app, "lunar-uninstall"), mode = tonumber("755", 8),
		content = "#!/bin/sh\n# Removes Lunar. Written by the Lunar setup program.\nexec "
			.. shq(join(t.app, "lunar")) .. " " .. shq(join(join(t.app, "setup"), "uninstall.lua")) .. ' "$@"\n',
	}
	out.dirs[#out.dirs + 1] = t.bin
	out.links[#out.links + 1] = { link = join(t.bin, "lunar"), target = join(t.app, "lunar") }
	out.links[#out.links + 1] = { link = join(t.bin, "lunar-uninstall"), target = join(t.app, "lunar-uninstall") }

	out.dirs[#out.dirs + 1] = t.apps
	local template = platform.secure_read(join(setup, "lunar.desktop"))
	if not template then return nil, "the payload is missing setup/lunar.desktop" end
	out.files[#out.files + 1] = { dst = join(t.apps, "lunar.desktop"), mode = tonumber("644", 8),
		content = desktop_entry(template, t.app) }
	out.files[#out.files + 1] = { dst = join(t.apps, "lunar-uninstall.desktop"), mode = tonumber("644", 8),
		content = table.concat({
			"[Desktop Entry]", "Type=Application", "Name=Uninstall Lunar",
			"Comment=Remove Lunar from this computer",
			"Exec=" .. desktop_arg(join(t.app, "lunar-uninstall")), "Icon=lunar", "Terminal=false",
			"Categories=Utility;", "StartupNotify=true", "",
		}, "\n") }

	for _, s in ipairs(M.ICON_SIZES) do
		local src = join(join(setup, "icons"), "lunar-" .. s .. ".png")
		if lfs.symlinkattributes(src, "mode") ~= "file" then return nil, "the payload is missing " .. src end
		local d = join(t.icons, "hicolor/" .. s .. "x" .. s .. "/apps")
		out.dirs[#out.dirs + 1] = join(t.icons, "hicolor")
		out.dirs[#out.dirs + 1] = join(t.icons, "hicolor/" .. s .. "x" .. s)
		out.dirs[#out.dirs + 1] = d
		out.files[#out.files + 1] = { src = src, dst = join(d, "lunar.png"), mode = tonumber("644", 8) }
	end
	out.dirs[#out.dirs + 1] = t.icons   -- parents before children is restored below
	-- Order folders so parents come first, once each.
	local seen, ordered = {}, {}
	local function add_dir(d)
		if seen[d] then return end
		seen[d] = true
		ordered[#ordered + 1] = d
	end
	table.sort(out.dirs, function(a, b)
		local _, da = a:gsub("/", "")
		local _, db = b:gsub("/", "")
		if da ~= db then return da < db end
		return a < b
	end)
	for _, d in ipairs(out.dirs) do add_dir(d) end
	out.dirs = ordered
	return out
end

-- ---------------------------------------------------------------------------
-- Executing a plan
-- ---------------------------------------------------------------------------

local function which(name)
	for dir in (os.getenv("PATH") or ""):gmatch("[^:]+") do
		local p = join(dir, name)
		if lfs.attributes(p, "mode") == "file" then return p end
	end
	return nil
end

-- Run a program to completion; failures only matter to the caller's warning list.
local function run_wait(argv, timeout)
	local job, err = platform.spawn(argv)
	if not job then return nil, err end
	local deadline = os.time() + (timeout or 30)
	local code = job.poll()
	while code == nil and os.time() < deadline do
		local ok, socket = pcall(require, "socket")
		if ok then socket.sleep(0.02) end
		code = job.poll()
	end
	if code == nil then job.close() return nil, "timed out" end
	job.close()
	return code
end

local function refresh_caches(t, runner, generated)
	runner = runner or run_wait
	local warnings = {}
	local function track(dir, names, command)
		local absent = {}
		for _, name in ipairs(names) do
			local path = join(dir, name)
			if lfs.symlinkattributes(path, "mode") == "link" then
				return nil, "refusing symbolic link: " .. path
			end
			absent[path] = not exists(path)
		end
		local code, err = runner(command)
		if generated then
			for path, was_absent in pairs(absent) do
				if was_absent and lfs.symlinkattributes(path, "mode") == "file" then generated[path] = true end
			end
		end
		return code, err
	end
	local cache = which("gtk-update-icon-cache")
	if cache and lfs.symlinkattributes(join(t.icons, "hicolor"), "mode") == "directory"
		and platform.secure_parent(join(t.icons, "hicolor")) then
		local dir = join(t.icons, "hicolor")
		local code, err = track(dir, { "icon-theme.cache" }, { cache, "-q", "-t", "-f", dir })
		if code ~= 0 then warnings[#warnings + 1] = "icon cache: " .. tostring(err or ("exit " .. tostring(code))) end
	end
	local db = which("update-desktop-database")
	if db and lfs.symlinkattributes(t.apps, "mode") == "directory" and platform.secure_parent(t.apps) then
		local code, err = track(t.apps, { "mimeinfo.cache", "desktop.cache" }, { db, "-q", t.apps })
		if code ~= 0 then warnings[#warnings + 1] = "desktop database: " .. tostring(err or ("exit " .. tostring(code))) end
	end
	return warnings
end

-- Create `path` and any missing parents; the folders actually made are appended
-- to `made` (they are what an uninstall may remove again).
local function remove_dir_if_unused(dir)
	if lfs.symlinkattributes(dir, "mode") ~= "directory" then return end
	return platform.secure_remove(dir, true)
end

local function make_dirs(path, made)
	return platform.secure_mkdir(path, made)
end

local function copy_file(file, replace)
	return platform.secure_write(file.dst, file.content, file.src, file.mode, replace)
end

local Executor = {}
Executor.__index = Executor
M.Executor = Executor

--- Steps run one at a time with `step()`; `progress()` says how far along.
-- @tparam table steps `{ { text = "...", run = function() -> true | nil, err } }`.
function Executor.new(steps, finish)
	return setmetatable({ steps = steps, index = 0, finish = finish, warnings = {}, text = "" }, Executor)
end

--- Run the next step.
-- @treturn boolean|nil `true` when everything is done, `false` when more remains,
--   nil and why on failure (the executor stops).
function Executor:step()
	if self.failed then return nil, self.failed end
	if self.index >= #self.steps then return true end
	self.index = self.index + 1
	local s = self.steps[self.index]
	self.text = s.text
	local ok, err = s.run()
	if not ok then
		self.failed = err or ("failed: " .. tostring(s.text))
		return nil, self.failed
	end
	if self.index >= #self.steps then
		if self.finish then self.finish(self) end
		return true
	end
	return false
end

--- @treturn number fraction done, 0..1
--- @treturn string what the last step did
function Executor:progress()
	return #self.steps == 0 and 1 or self.index / #self.steps, self.text
end

--- Run every remaining step.
-- @treturn[1] boolean true
-- @treturn[2] nil
-- @treturn[2] string why.
function Executor:run_all()
	while true do
		local done, err = self:step()
		if done == nil then return nil, err end
		if done then return true end
	end
end

local function set_of(list)
	local s = {}
	for _, v in ipairs(list or {}) do s[v] = true end
	return s
end

-- Is `p` inside one of the install locations?
-- With `ancestors`, also a folder above one (a parent the install had to create).
local function within(p, t, ancestors)
	if p:find("/%.%./", 1) or p:find("/%.%.$") or p:find("[%c]") or p:sub(1, 1) ~= "/" then return false end
	for _, root in ipairs({ t.app, t.bin, t.apps, t.icons }) do
		if p == root or p:sub(1, #root + 1) == root .. "/" then return true end
		if ancestors and root:sub(1, #p + 1) == p .. "/" then return true end
	end
	return false
end

local function remove_stale(old, plan, owned_files, owned_links, created, persist)
	local steps = {}
	local keep_files, keep_links, keep_dirs = {}, {}, set_of(plan.dirs)
	for _, f in ipairs(plan.files) do keep_files[f.dst] = true end
	for _, l in ipairs(plan.links) do keep_links[l.link] = true end
	local t = plan.targets
	for _, p in ipairs(old.files or {}) do
		if not keep_files[p] and within(p, t) then
			steps[#steps + 1] = { text = "Removing " .. p, run = function()
				local ok, err = platform.secure_parent(p)
				if not ok then return nil, err end
				if exists(p) then ok, err = platform.secure_remove(p)
					if not ok then return nil, err end end
				owned_files[p] = nil
				return persist()
			end }
		end
	end
	for _, p in ipairs(old.links or {}) do
		if not keep_links[p] and within(p, t) then
			steps[#steps + 1] = { text = "Removing " .. p, run = function()
				local ok, err = platform.secure_parent(p)
				if not ok then return nil, err end
				if lfs.symlinkattributes(p, "mode") == "link" then
					ok, err = platform.secure_remove(p)
					if not ok then return nil, err end
				end
				owned_links[p] = nil
				return persist()
			end }
		end
	end
	-- Folders the old install made that the new one no longer has: deepest first,
	-- and only when empty.
	local olddirs = {}
	for _, d in ipairs(old.dirs or {}) do
		if not keep_dirs[d] and within(d, t, true) then olddirs[#olddirs + 1] = d end
	end
	table.sort(olddirs, function(a, b) return #a > #b end)
	for _, d in ipairs(olddirs) do
		steps[#steps + 1] = { text = "Removing " .. d, run = function()
			local ok, err = platform.secure_parent(d)
			if not ok then return nil, err end
			if remove_dir_if_unused(d) then created[d] = nil end
			return persist()
		end }
	end
	return steps
end

--- Install: the steps that carry out `plan`, upgrading over an earlier install.
-- @tparam table plan from `build_plan`.
-- @tparam[opt] table opts `runner(argv) -> exit code` for the cache refresh (tests).
-- @treturn Executor
function M.install_executor(plan, opts)
	opts = opts or {}
	local t = plan.targets
	local old = M.read_record(plan.mode, opts)
	local old_links = set_of(old and old.links)
	local old_files = set_of(old and old.files)
	local created = set_of(old and old.dirs)
	local owned_files, owned_links = set_of(old and old.files), set_of(old and old.links)
	local generated = set_of(old and old.generated)
	local steps = {}
	local warnings = {}
	local record_owned = old ~= nil

	-- Start with the old ownership. Add each new path only after its operation
	-- succeeds, and persist after every change so a failed install remains safe.
	local function record()
		local dirs, files, links, caches = {}, {}, {}, {}
		for d in pairs(created) do dirs[#dirs + 1] = d end
		table.sort(dirs)
		for p in pairs(owned_files) do files[#files + 1] = p end
		for p in pairs(owned_links) do links[#links + 1] = p end
		for p in pairs(generated) do caches[#caches + 1] = p end
		table.sort(files); table.sort(links); table.sort(caches)
		return { schema = 1, version = plan.version, mode = plan.mode, targets = t,
			extensions = plan.extensions, available = plan.available,
			dirs = dirs, files = files, links = links, generated = caches,
			installed_at = os.date("!%Y-%m-%dT%H:%M:%SZ") }
	end
	local function write_record(rec)
		local path = join(t.app, M.RECORD)
		local ok, err = platform.secure_write(path, plan_mod.encode_json(rec), nil,
			tonumber("644", 8), record_owned)
		if ok then record_owned = true end
		return ok, err
	end
	local function persist() return write_record(record()) end

	for _, d in ipairs(plan.dirs) do
		steps[#steps + 1] = { text = "Creating " .. d, run = function()
			local made = {}
			local ok, err = make_dirs(d, made)
			for _, m in ipairs(made) do created[m] = true end
			if not ok then return nil, err end
			if created[t.app] then return persist() end
			return true
		end }
		if d == t.app then
			steps[#steps + 1] = { text = "Recording the install", run = function()
				return persist()
			end }
		end
	end
	for _, file in ipairs(plan.files) do
		steps[#steps + 1] = { text = "Installing " .. file.dst:match("[^/]+$"), run = function()
			local ok, err = platform.secure_parent(file.dst)
			if not ok then return nil, err end
			local mode = lfs.symlinkattributes(file.dst, "mode")
			if mode and not old_files[file.dst] then return nil, file.dst .. " already exists and is not owned" end
			if mode == "link" or mode == "directory" then return nil, file.dst .. " is a symbolic link or folder" end
			ok, err = copy_file(file, old_files[file.dst])
			if not ok then return nil, err end
			owned_files[file.dst] = true
			ok, err = persist()
			if not ok and not old_files[file.dst] then
				platform.secure_remove(file.dst)
				owned_files[file.dst] = nil
			end
			return ok, err
		end }
	end
	for _, l in ipairs(plan.links) do
		steps[#steps + 1] = { text = "Linking " .. l.link, run = function()
			local mode = lfs.symlinkattributes(l.link, "mode")
			local ok, err = platform.secure_parent(l.link)
			if not ok then return nil, err end
			if mode and not old_links[l.link] and not old_files[l.link] then
				return nil, l.link .. " already exists and is not owned"
			end
			if mode == "directory" then return nil, l.link .. " is a folder" end
			if mode then
				ok, err = platform.secure_remove(l.link)
				if not ok then return nil, err end
				owned_links[l.link] = nil
				owned_files[l.link] = nil
				ok, err = persist()
				if not ok then return nil, err end
			end
			ok, err = platform.secure_symlink(l.target, l.link)
			if not ok then return nil, "cannot link " .. l.link .. ": " .. tostring(err) end
			owned_links[l.link] = true
			ok, err = persist()
			if not ok then
				platform.secure_remove(l.link)
				owned_links[l.link] = nil
			end
			return ok, err
		end }
	end
	if old then
		for _, s in ipairs(remove_stale(old, plan, owned_files, owned_links, created, persist)) do steps[#steps + 1] = s end
	end
	steps[#steps + 1] = { text = "Finishing", run = function()
		for _, w in ipairs(refresh_caches(t, opts.runner, generated)) do warnings[#warnings + 1] = w end
		return persist()
	end }

	local ex = Executor.new(steps)
	ex.warnings = warnings
	return ex
end

--- Remove an install: its recorded files and links, then the folders it made that
-- are empty. Nothing outside the recorded install locations is touched.
-- @tparam table record from `read_record`.
-- @tparam[opt] table opts `runner` (tests).
-- @treturn Executor
function M.uninstall_executor(record, opts)
	opts = opts or {}
	local t = record.targets
	local steps = {}
	if type(t) ~= "table" or type(t.app) ~= "string" then
		steps[1] = { text = "Reading the install record", run = function() return nil, "the install record is damaged" end }
		return Executor.new(steps)
	end
	local function remove_file(p, only_link)
		steps[#steps + 1] = { text = "Removing " .. p, run = function()
			if not within(p, t) then return nil, "refusing to remove " .. tostring(p) .. " (outside the install)" end
			local safe, why = platform.secure_parent(p)
			if not safe then return nil, "refusing to remove " .. p .. ": " .. tostring(why) end
			local mode = lfs.symlinkattributes(p, "mode")
			if mode == "directory" then return nil, p .. " is a folder" end
			if mode and (not only_link or mode == "link") then
				local ok, err = platform.secure_remove(p)
				if not ok then return nil, "cannot remove " .. p .. ": " .. tostring(err) end
			end
			return true
		end }
	end
	for _, p in ipairs(record.links or {}) do remove_file(p, true) end
	for _, p in ipairs(record.files or {}) do remove_file(p, false) end
	local allowed_generated = {
		[join(join(t.icons, "hicolor"), "icon-theme.cache")] = true,
		[join(t.apps, "mimeinfo.cache")] = true,
		[join(t.apps, "desktop.cache")] = true,
	}
	for _, p in ipairs(record.generated or {}) do
		if allowed_generated[p] then remove_file(p, false) end
	end
	remove_file(join(t.app, M.RECORD), false)
	local dirs = {}
	for _, d in ipairs(record.dirs or {}) do dirs[#dirs + 1] = d end
	table.sort(dirs, function(a, b) return #a > #b end)
	for _, d in ipairs(dirs) do
		steps[#steps + 1] = { text = "Removing " .. d, run = function()
			if not within(d, t, true) then return nil, "refusing to remove " .. tostring(d) end
			local ok, why = platform.secure_parent(d)
			if not ok then return nil, "refusing to remove " .. d .. ": " .. tostring(why) end
			remove_dir_if_unused(d)
			return true
		end }
	end
	return Executor.new(steps, function(self)
		for _, w in ipairs(refresh_caches(t, opts.runner)) do self.warnings[#self.warnings + 1] = w end
	end)
end

-- ---------------------------------------------------------------------------
-- Root helper (system installs)
-- ---------------------------------------------------------------------------

--- Start the root helper through pkexec.
-- @tparam table argv what the helper should do: `{ "install", payload, ids }` or
--   `{ "uninstall" }`.
-- @tparam string setup_dir folder holding `lunar-cli` and `root_helper.lua`.
-- @treturn[1] table a platform job (`poll`, `output`, `close`)
-- @treturn[2] nil
-- @treturn[2] string why.
function M.start_helper(setup_dir, argv)
	local cmd = { join(setup_dir, "lunar-cli"), join(setup_dir, "root_helper.lua") }
	for _, a in ipairs(argv) do cmd[#cmd + 1] = a end
	return platform.elevate(cmd)
end

--- What the helper prints: `STEP <i> <n> <text>` lines. The latest, parsed.
-- @treturn number|nil fraction
-- @treturn string|nil text
function M.parse_helper_output(text)
	local i, n, msg
	for a, b, c in tostring(text):gmatch("STEP (%d+) (%d+) ([^\n]*)") do i, n, msg = tonumber(a), tonumber(b), c end
	if i and n and n > 0 then return i / n, msg end
	return nil, nil
end

--- The root helper's entry point. `args` is the helper's command line:
-- `install <payload> <ids>` (`ids` is a comma-separated list, `-` for none) or
-- `uninstall`. Only ever the fixed system locations.
-- @treturn number exit code
function M.helper_main(args, out, err)
	out, err = out or io.stdout, err or io.stderr
	local verb = args[1]
	local ex
	if verb == "install" then
		local payload, ids_text = args[2], args[3]
		if not payload or payload:sub(1, 1) ~= "/" or not ids_text then
			err:write("usage: install <absolute payload folder> <ids|->\n")
			return 2
		end
		local ids = {}
		if ids_text ~= "-" then for id in ids_text:gmatch("[^,]+") do ids[#ids + 1] = id end end
		local info = plan_mod.read_json(join(join(payload, "setup"), "payload.json"), platform.secure_read) or {}
		local plan, perr = M.build_plan(payload, ids, "system", { version = info.version })
		if not plan then err:write(perr, "\n") return 1 end
		ex = M.install_executor(plan)
	elseif verb == "uninstall" then
		local rec = M.read_record("system")
		if not rec then err:write("Lunar is not installed for everyone.\n") return 1 end
		local want = M.targets("system")
		for k, v in pairs(want) do
			if rec.targets == nil or rec.targets[k] ~= v then
				err:write("the install record does not match the system install locations\n")
				return 1
			end
		end
		ex = M.uninstall_executor(rec)
	else
		err:write("usage: root_helper.lua install|uninstall ...\n")
		return 2
	end
	while true do
		local done, serr = ex:step()
		if done == nil then err:write(serr, "\n") return 1 end
		out:write(string.format("STEP %d %d %s\n", ex.index, #ex.steps, (ex.text:gsub("[\r\n]", " "))))
		out:flush()
		if done then break end
	end
	for _, w in ipairs(ex.warnings) do err:write("warning: ", w, "\n") end
	return 0
end

return M

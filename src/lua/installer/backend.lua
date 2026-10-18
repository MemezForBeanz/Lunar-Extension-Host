--- Adapters between the installer window (`installer.ui`) and each OS's installer.
--
-- A backend is a table the window reads (`title`, `types`, `extensions`, ...) with a
-- `start(choices)` that returns a job. See `installer.ui` for the shape.
--
-- @module installer.backend

local plan_mod = require("installer.plan")
local linux = require("installer.linux")
local windows = require("installer.windows")
local platform = require("core.platform")

local M = {}

local function read_file(path)
	local f = io.open(path, "rb")
	if not f then return nil end
	local text = f:read("*a")
	f:close()
	return text
end

-- A finished job's result.
local function result(status, message, detail) return { status = status, message = message, detail = detail } end

-- A job that wraps a step executor (installing or uninstalling into the user's own
-- folders, or into a test root).
local function executor_job(ex, finish)
	local job = {}
	function job:tick()
		local deadline = os.clock() + 0.03
		repeat
			local done, err = ex:step()
			if done == nil then return result("error", "Setup could not finish.", err) end
			if done then return finish(ex) end
		until os.clock() >= deadline
		return nil
	end
	function job:progress() return ex:progress() end
	return job
end

-- A job that wraps a platform job running the root helper.
local function helper_job(pjob, installing, finish)
	local job = {}
	function job:tick()
		local code = pjob.poll()
		if code == nil then return nil end
		pjob.close()
		if code == 0 then return finish() end
		if code == 126 or code == 127 then
			return result("cancelled", "Administrator permission was not given, so nothing was changed.")
		end
		-- Keep what the helper complained about: drop its progress lines and the console
		-- executable's banner.
		local out = pjob.output():gsub("STEP [^\n]*\n?", ""):gsub("=== [^\n]*\n?", ""):gsub("Loading script:[^\n]*\n?", "")
		out = out:gsub("^%s+", ""):gsub("%s+$", "")
		return result("error", installing and "Setup could not finish." or "Lunar could not be removed.",
			out ~= "" and out or ("The helper exited with code " .. tostring(code) .. "."))
	end
	function job:progress()
		return linux.parse_helper_output(pjob.output())
	end
	return job
end

local function csv(ids)
	if #ids == 0 then return "-" end
	return table.concat(ids, ",")
end

--- Backend for installing on Linux.
-- @tparam table o `payload` (folder with `lunar`, `plugins/`, `setup/`), `root`,
--   `home` (tests / dry runs).
function M.linux_install(o)
	local setup = o.payload .. "/setup"
	local info = plan_mod.read_json(setup .. "/payload.json") or {}
	local version = info.version or "?"
	local exts, skipped = plan_mod.scan_extensions(o.payload .. "/plugins", { os = "linux" })
	local existing = linux.find_install(o)
	local b = {
		kind = "install", title = "Lunar Setup", version = version,
		license = read_file(setup .. "/LICENSE") or "",
		types = {
			{ id = "user", label = "Just for me",
				description = "Installs in your home folder (~/.local). No administrator password needed." },
			{ id = "system", label = "Everyone on this computer",
				description = "Installs in /opt/lunar for all users. Asks for an administrator password." },
		},
		default_type = existing and existing.mode or "user",
		extensions = exts, skipped = skipped,
		defaults = plan_mod.defaults(exts, existing),
		icon_dir = setup .. "/icons",
	}
	if existing then
		b.notice = "Lunar " .. tostring(existing.version or "") .. " is already installed"
			.. (existing.mode == "system" and " for everyone" or " for you")
			.. ". Setup will upgrade it."
	end

	function b.start(choices)
		local ids = choices.ids
		local mode = choices.type
		local plan, err = linux.build_plan(o.payload, ids, mode, { version = version, home = o.home, root = o.root })
		if not plan then return nil, err end
		local function done(ex)
			local detail = ex and #ex.warnings > 0 and table.concat(ex.warnings, "\n") or nil
			return result("ok", "Lunar " .. version .. " is installed in " .. plan.targets.app .. ".", detail)
		end
		if mode == "system" and not o.root then
			local pjob, perr = linux.start_helper(setup, { "install", o.payload, csv(ids) })
			if not pjob then
				return nil, "pkexec could not be started (" .. tostring(perr) .. "). Install polkit, or choose Just for me."
			end
			return helper_job(pjob, true, function() return done(nil) end)
		end
		return executor_job(linux.install_executor(plan, o), done)
	end
	function b.launch(choices)
		local t = linux.targets(choices.type, o)
		return platform.launch(t.app .. "/lunar")
	end
	return b
end

--- Backend for removing a Linux install.
-- @tparam table o `record` (from `linux.read_record`), `setup_dir`, `root`.
function M.linux_uninstall(o)
	local rec = o.record
	local app = rec.targets and rec.targets.app or "Lunar"
	local b = {
		kind = "uninstall", title = "Uninstall Lunar", version = rec.version, launchable = false,
		confirm_text = "Lunar " .. tostring(rec.version or "") .. " will be removed from " .. app
			.. ".\n\nOnly the files setup installed are removed. Your settings in ~/.config/lunar are kept.",
		icon_dir = app .. "/setup/icons",
	}
	function b.start()
		local function done(ex)
			local detail = ex and #ex.warnings > 0 and table.concat(ex.warnings, "\n") or nil
			return result("ok", "Everything setup installed has been removed.", detail)
		end
		if rec.mode == "system" and not o.root then
			local pjob, perr = linux.start_helper(o.setup_dir, { "uninstall" })
			if not pjob then return nil, "pkexec could not be started (" .. tostring(perr) .. ")." end
			return helper_job(pjob, false, function() return done(nil) end)
		end
		return executor_job(linux.uninstall_executor(rec, o), done)
	end
	return b
end

--- Backend for installing on Windows through the MSI.
-- @tparam table o `dir` (the payload folder), `elevate`, `query` (tests).
function M.windows_install(o)
	local state, err = windows.load(o.dir)
	if not state then return nil, err end
	local defaults, installed = windows.defaults(state.extensions, o.query)
	local b = {
		kind = "install", title = "Lunar Setup", version = state.version,
		license = read_file(platform.path:join(o.dir, "LICENSE")) or "",
		types = {
			{ id = "system", label = "Everyone who uses this computer",
				description = "Installs in " .. platform.path:join(platform.program_files_dir() or "C:\\Program Files",
					windows.INSTALL_DIR) .. " for all users. Windows will ask for administrator permission." },
		},
		default_type = "system",
		type_note = "Lunar's Windows package installs for the whole computer, so there is no \"just for me\" choice. "
			.. "IT departments can deploy the .msi directly.",
		extensions = state.extensions, skipped = {}, defaults = defaults,
	}
	if installed then b.notice = "Lunar is already installed on this computer. Setup will upgrade it." end

	function b.start(choices)
		local exts = plan_mod.select(state.extensions, choices.ids)
		local pjob, log = windows.start(state, exts, o)
		if not pjob then return nil, log end
		local job = {}
		function job:tick()
			local code = pjob.poll()
			if code == nil then return nil end
			pjob.close()
			local r = windows.map_exit(code)
			if r.status == "error" then r.detail = "Details are in " .. log end
			return r
		end
		function job:progress() return nil, "Installing Lunar..." end
		return job
	end
	function b.launch()
		return platform.launch(windows.installed_exe())
	end
	return b
end

--- Run a job to completion without a window.
-- @treturn table the job's result
function M.run_blocking(job, sleep)
	local ok, socket = pcall(require, "socket")
	sleep = sleep or (ok and socket.sleep) or function(seconds) os.execute("sleep " .. seconds) end
	while true do
		local r = job:tick()
		if r then return r end
		sleep(ok and 0.02 or 0.1)
	end
end

return M

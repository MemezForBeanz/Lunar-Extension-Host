--- The Windows installer: the MSI does the installing, this drives it.
--
-- `Lunar-Setup-<version>.exe` carries `LunarExtensionHost-<version>.msi` (the same
-- package IT deploys silently and the in-app updater uses) and runs this program.
-- The wizard turns the user's choices into `ADDLOCAL=<features>` and starts
-- `msiexec /i ... /qn` elevated (one UAC prompt), then reports what msiexec said.
--
-- There is one install type: **Everyone**. The MSI is per-machine (Program Files,
-- ProgramData, an all-users Start menu entry). A "Just for me" install would need a
-- different package, so it is not offered.
--
-- @module installer.windows

local plan_mod = require("installer.plan")
local platform = require("core.platform")

local M = {}

--- The MSI's UpgradeCode (`scripts/build.ps1`); finds an installed Lunar.
M.UPGRADE_CODE = "{5C145DA3-FBAC-420D-B9F0-EE19AFEA76EA}"
--- The MSI feature for the application itself (always installed).
M.CORE_FEATURE = "Ft_Core"
--- Name of Lunar's folder under Program Files (`INSTALLFOLDER` in the MSI).
M.INSTALL_DIR = "Lunar Extension Host"
M.EXE = "Lunar.exe"

--- The MSI features for the chosen extensions: the core, then one per extension.
-- @tparam table exts chosen extensions (each with `feature`).
-- @treturn table feature ids
function M.features(exts)
	local out = { M.CORE_FEATURE }
	for _, e in ipairs(exts) do
		if e.feature then out[#out + 1] = e.feature end
	end
	return out
end

--- The extension features the user did not choose.
-- Installing over an installed product only adds what ADDLOCAL names, so a feature
-- that was installed and is now unchecked has to be named in REMOVE as well.
-- @tparam table all every extension in the package.
-- @tparam table chosen the chosen ones.
-- @treturn table feature ids
function M.unchosen_features(all, chosen)
	local keep, out = {}, {}
	for _, e in ipairs(chosen) do keep[e.id] = true end
	for _, e in ipairs(all) do
		if not keep[e.id] and e.feature then out[#out + 1] = e.feature end
	end
	return out
end

--- The msiexec command line (an argv array: the elevated launcher quotes it).
-- @tparam string msi path to the package.
-- @tparam table features from `features`.
-- @tparam string log path of the verbose log.
-- @tparam[opt] string msiexec path of msiexec.exe (default: the system's).
-- @tparam[opt] table remove features for `REMOVE=` (see `unchosen_features`).
function M.msiexec_argv(msi, features, log, msiexec, remove)
	local argv = {
		msiexec or M.msiexec_path(),
		"/i", msi,
		"ADDLOCAL=" .. table.concat(features, ","),
	}
	if remove and #remove > 0 then argv[#argv + 1] = "REMOVE=" .. table.concat(remove, ",") end
	for _, a in ipairs({ "/qn", "/norestart", "/l*v", log }) do argv[#argv + 1] = a end
	return argv
end

--- Full path of msiexec.exe, so an elevated launch never searches PATH.
function M.msiexec_path()
	local root = os.getenv("SystemRoot") or os.getenv("windir") or "C:\\Windows"
	return root .. "\\System32\\msiexec.exe"
end

--- What an msiexec exit code means.
-- @tparam number code
-- @treturn table `{ status = "ok"|"reboot"|"cancelled"|"error", message }`
function M.map_exit(code)
	if code == 0 then return { status = "ok", message = "Lunar is installed." } end
	if code == 3010 or code == 1641 then
		return { status = "reboot", message = "Lunar is installed. Restart Windows to finish." }
	end
	if code == 1602 then return { status = "cancelled", message = "The installation was cancelled." } end
	if code == 1223 then return { status = "cancelled", message = "Administrator permission was not given, so nothing was installed." } end
	if code == 1618 then
		return { status = "error", message = "Another installation is already running. Wait for it to finish, then run setup again." }
	end
	if code == 1638 then
		return { status = "error", message = "A newer version of Lunar is already installed." }
	end
	if code == 1619 or code == 1620 then
		return { status = "error", message = "The installer package could not be opened. Download the setup program again." }
	end
	if code == 1625 then
		return { status = "error", message = "This installation is blocked by a policy on this computer." }
	end
	return { status = "error", message = "The installation failed (error " .. tostring(code) .. ")." }
end

--- Where the log of a run goes.
function M.log_path(version)
	return platform.path:join(platform.temp_dir(), "Lunar-Setup-" .. tostring(version) .. ".log")
end

--- Read what the payload carries.
-- @tparam string dir folder holding `payload.json`, the MSI and `LICENSE`.
-- @treturn[1] table `{ version, msi (path), extensions, dir }`
-- @treturn[2] nil
-- @treturn[2] string why.
function M.load(dir)
	local info, err = plan_mod.read_payload(platform.path:join(dir, "payload.json"))
	if not info then return nil, err end
	if type(info.msi) ~= "string" or info.msi == "" then return nil, "payload.json names no MSI" end
	info.dir = dir
	info.msi_path = platform.path:join(dir, info.msi)
	return info
end

--- Extensions to preselect: those installed now, else all.
-- @tparam table exts payload extensions.
-- @tparam[opt] function query `fn(upgrade_code, features) -> {[feature]=true}|nil`
--   (default: Windows Installer through `core.platform`).
-- @treturn table `{ [id] = boolean }`
-- @treturn boolean whether Lunar is installed already.
function M.defaults(exts, query)
	query = query or platform.msi_installed_features
	local features = { M.CORE_FEATURE }
	for _, e in ipairs(exts) do features[#features + 1] = e.feature end
	local installed = query(M.UPGRADE_CODE, features)
	local out = {}
	if not installed then
		for _, e in ipairs(exts) do out[e.id] = true end
		return out, false
	end
	for _, e in ipairs(exts) do out[e.id] = installed[e.feature] == true end
	return out, true
end

--- Where Lunar.exe ends up.
function M.installed_exe()
	local root = platform.program_files_dir() or "C:\\Program Files"
	return platform.path:join(root, M.INSTALL_DIR, M.EXE)
end

--- Start the install.
-- @tparam table state from `load`.
-- @tparam table exts the chosen extensions.
-- @tparam[opt] table opts `elevate` (a function like `platform.elevate`), `msiexec`.
-- @treturn[1] table a platform job
-- @treturn[1] string log path
-- @treturn[2] nil
-- @treturn[2] string why (`"cancelled"` when the user declined the prompt).
function M.start(state, exts, opts)
	opts = opts or {}
	local log = M.log_path(state.version)
	local argv = M.msiexec_argv(state.msi_path, M.features(exts), log, opts.msiexec,
		M.unchosen_features(state.extensions, exts))
	local job, err = (opts.elevate or platform.elevate)(argv)
	if not job then return nil, err end
	return job, log
end

return M

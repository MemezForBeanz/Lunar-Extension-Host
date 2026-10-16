--- Update checks against a release share, and the relauncher that installs one.
--
-- The share (the `update_share` setting, from an org profile) holds what
-- `scripts/build.ps1 -HostRoot` publishes:
--
--     <root>\manifest.json                              { latest = "1.9.9", ... }
--     <root>\releases\<version>\release.json            { extensions = {{ name, version }} }
--     <root>\releases\<version>\LunarExtensionHost-<version>.msi
--
-- Everything read from the share is untrusted text. Versions must be plain
-- dotted numbers before they are used in a path, the installer path is built
-- here rather than taken from the manifest, and every path that goes into the
-- relauncher script is refused if cmd or PowerShell would interpret any of it.
--
-- This does not authenticate the installer: whoever can write the share can
-- still publish an MSI. Checking a signing identity before installing is the
-- remaining step (it needs the org's code-signing certificate).
--
-- Pure functions over an injectable `read(path)`, so the logic is testable
-- without a share; `core.main` owns the UI and the launch.
--
-- @module core.lib.Updater

local cjson = require("cjson")

local M = {}

local MAX_PARTS, MAX_DIGITS = 4, 5

--- Parse a strict dotted version (`"1.9.8"`): 1-4 numeric parts, nothing else.
-- @tparam string s
-- @treturn table|nil the numeric parts
function M.parse_version(s)
	if type(s) ~= "string" or not s:match("^%d+[%d%.]*$") or s:find("..", 1, true) or s:sub(-1) == "." then
		return nil
	end
	local parts = {}
	for p in s:gmatch("%d+") do
		if #p > MAX_DIGITS then return nil end
		parts[#parts + 1] = tonumber(p)
	end
	if #parts > MAX_PARTS then return nil end
	return parts
end

--- Compare two strict versions: -1, 0 or 1, or nil if either is invalid.
function M.compare(a, b)
	local pa, pb = M.parse_version(a), M.parse_version(b)
	if not pa or not pb then return nil end
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then return x < y and -1 or 1 end
	end
	return 0
end

-- Characters cmd.exe or PowerShell would act on inside the relauncher, plus
-- control characters. A path with any of them is refused, not escaped.
local UNSAFE = "[\"%%!%^&|<>`'%c]"

--- Is `p` an absolute Windows path (drive or UNC) safe to put in the relauncher?
-- @tparam string p
-- @treturn boolean
function M.safe_path(p)
	if type(p) ~= "string" or p == "" or p:find(UNSAFE) then return false end
	if not (p:match("^%a:\\") or p:match("^\\\\[^\\]+\\[^\\]+")) then return false end
	-- No relative components anywhere in it.
	for part in p:gmatch("[^\\/]+") do
		if part == "." or part == ".." then return false end
	end
	return true
end

local function read_json(read, path)
	local text = read(path)
	if not text then return nil end
	local ok, data = pcall(cjson.decode, text)
	if ok and type(data) == "table" then return data end
	return nil
end

--- The installer for `version` on the share. Built from the version, never
-- read from the manifest.
function M.installer_path(root, version)
	return string.format("%s\\releases\\%s\\LunarExtensionHost-%s.msi", root, version, version)
end

--- Check the share for a newer app or newer versions of installed extensions.
-- @tparam table opts
-- @tparam string opts.root the share root (no trailing separator)
-- @tparam string opts.app_version this build's version
-- @tparam[opt] table opts.installed `{ [lowercase name] = version }` of loaded extensions
-- @tparam function opts.read `read(path)` returning the file's text or nil
-- @treturn table `{ status = "current"|"available"|"unavailable", latest,
--   app_update = bool, extensions = { "name (1.0 -> 1.1)", ... }, error }`
function M.check(opts)
	if not M.safe_path(opts.root) then
		return { status = "unavailable", error = "the update share path is not usable" }
	end
	local manifest = read_json(opts.read, opts.root .. "\\manifest.json")
	if not manifest then
		return { status = "unavailable", error = "no readable manifest.json on the update share" }
	end
	local latest = manifest.latest
	if not M.parse_version(latest) then
		return { status = "unavailable", error = "manifest.json has no valid latest version" }
	end

	local cmp = M.compare(opts.app_version, latest)
	local result = { status = "current", latest = latest, app_update = cmp ~= nil and cmp < 0, extensions = {} }

	local release = read_json(opts.read, string.format("%s\\releases\\%s\\release.json", opts.root, latest))
	if release and type(release.extensions) == "table" then
		for _, e in ipairs(release.extensions) do
			local name = type(e) == "table" and e.name
			local have = type(name) == "string" and opts.installed and opts.installed[name:lower()]
			local c = have and M.compare(have, e.version)
			if c and c < 0 then
				result.extensions[#result.extensions + 1] = string.format("%s (%s -> %s)", name, have, e.version)
			end
		end
	end
	if result.app_update or #result.extensions > 0 then result.status = "available" end
	return result
end

--- Text of the .bat that waits for this process to exit, installs `msi`
-- elevated, and relaunches `exe`.
--
-- The host can't install over itself while running, and anything started with
-- subprocess.start dies with it (kill-on-close job), so this runs detached.
-- The app is relaunched whether or not the install succeeded, so a cancelled
-- UAC prompt or a failed install still leaves the user with a working app.
-- @tparam table opts `{ msi = path, exe = path, pid = number }`
-- @treturn[1] string the script (CRLF line endings)
-- @treturn[2] nil
-- @treturn[2] string why it was refused
function M.relauncher_script(opts)
	for _, key in ipairs({ "msi", "exe" }) do
		if not M.safe_path(opts[key]) then
			return nil, "refusing an unsafe " .. key .. " path: " .. tostring(opts[key])
		end
	end
	local pid = math.floor(tonumber(opts.pid) or 0)
	local lines = { "@echo off", "setlocal" }
	if pid > 0 then
		-- /FI "PID eq n" filters exactly; the find only turns "no rows" into an errorlevel.
		lines[#lines + 1] = ":waitloop"
		lines[#lines + 1] = string.format('tasklist /FI "PID eq %d" /NH 2>nul | find "%d" >nul', pid, pid)
		lines[#lines + 1] = "if not errorlevel 1 ("
		lines[#lines + 1] = "  timeout /t 1 /nobreak >nul"
		lines[#lines + 1] = "  goto waitloop"
		lines[#lines + 1] = ")"
	end
	lines[#lines + 1] = string.format(
		"powershell -NoProfile -Command \"Start-Process msiexec -ArgumentList '/i','\\\"%s\\\"','/qb','/norestart' -Verb RunAs -Wait\"",
		opts.msi)
	lines[#lines + 1] = string.format('start "" "%s"', opts.exe)
	lines[#lines + 1] = 'del "%~f0"'
	return table.concat(lines, "\r\n") .. "\r\n"
end

return M

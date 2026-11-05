--- Published GitHub release discovery and the Windows install relauncher.
-- Metadata comes from the latest published release; installer and checksum URLs
-- are pinned to its validated version, so a release published during a download
-- cannot change the selected payload. All requests use verified HTTPS.
-- @module core.lib.Updater

local cjson = require("cjson")

local M = {}
M.REPOSITORY = "MemezForBeanz/Lunar-Extension-Host"
M.RELEASES = "https://github.com/" .. M.REPOSITORY .. "/releases"
M.LATEST_METADATA = M.RELEASES .. "/latest/download/release.json"

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

local function unavailable(message)
	return { status = "unavailable", error = message }
end

local function get(request, url, app_version)
	local response, err = request({ url = url, method = "GET", verify = "peer", timeout = 20,
		max_bytes = 1024 * 1024, headers = { ["user-agent"] = "Lunar/" .. app_version,
			accept = "application/octet-stream" } })
	if not response then return nil, "Could not reach GitHub: " .. tostring(err) end
	if response.status ~= 200 then return nil, "GitHub returned HTTP " .. tostring(response.status) end
	if type(response.body) ~= "string" then return nil, "GitHub returned an empty response" end
	return response.body
end

--- Read an exact asset's SHA-256 from the release's SHA256SUMS file.
-- Refuse conflicting entries rather than choosing one arbitrarily.
function M.checksum(text, filename)
	local found
	for line in tostring(text):gmatch("[^\r\n]+") do
		local hash, name = line:match("^(%x+)%s+%*?(.+)$")
		if name == filename then
			if #hash ~= 64 then return nil, "Invalid SHA-256 for " .. filename end
			hash = hash:lower()
			if found and found ~= hash then return nil, "Conflicting checksums for " .. filename end
			found = hash
		end
	end
	return found, not found and ("No SHA-256 published for " .. filename) or nil
end

--- Check GitHub's latest published stable release. `request` is injectable for
-- offline tests; the normal transport is the host's cooperative HTTPS client.
-- @tparam table opts `{ app_version, installed, platform, request }`
-- @treturn table `{ status, latest, app_update, extensions, release_url, installer, error }`
function M.check(opts)
	if not M.parse_version(opts.app_version) then return unavailable("The installed version is invalid") end
	local request = opts.request or require("core.lib.http").request
	local text, err = get(request, M.LATEST_METADATA, opts.app_version)
	if not text then return unavailable(err) end
	local ok, release = pcall(cjson.decode, text)
	if not ok or type(release) ~= "table" then return unavailable("GitHub release.json is not a JSON object") end
	local latest = release.version
	if type(latest) ~= "string" or not latest:match("^%d+%.%d+%.%d+$") or not M.parse_version(latest) then
		return unavailable("GitHub release.json has no valid release version")
	end
	local cmp = M.compare(opts.app_version, latest)
	local result = { status = "current", latest = latest, app_update = cmp < 0, extensions = {},
		release_url = M.RELEASES .. "/tag/v" .. latest }
	-- Never offer an older application to update an extension in a newer build.
	if cmp <= 0 and type(release.extensions) == "table" then
		for _, extension in ipairs(release.extensions) do
			local name = type(extension) == "table" and extension.name
			local have = type(name) == "string" and opts.installed and opts.installed[name:lower()]
			local comparison = have and M.compare(have, extension.version)
			if comparison and comparison < 0 then
				result.extensions[#result.extensions + 1] = string.format("%s (%s -> %s)", name, have, extension.version)
			end
		end
	end
	if not result.app_update and #result.extensions == 0 then return result end
	result.status = "available"
	if opts.platform and opts.platform ~= "windows" then return result end
	local name = "LunarExtensionHost-" .. latest .. ".msi"
	if release.msi ~= name then return unavailable("GitHub release.json does not identify the expected Windows installer") end
	local base = M.RELEASES .. "/download/v" .. latest .. "/"
	local sums, sums_error = get(request, base .. "SHA256SUMS", opts.app_version)
	if not sums then return unavailable(sums_error) end
	local hash, hash_error = M.checksum(sums, name)
	if not hash then return unavailable(hash_error) end
	result.installer = { name = name, url = base .. name, sha256 = hash, version = latest }
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

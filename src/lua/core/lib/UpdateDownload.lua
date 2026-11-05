--- Stage a GitHub MSI in the local cache without blocking the UI. The helper
-- streams to disk, validates SHA-256, and never executes the downloaded file.
-- @module core.lib.UpdateDownload
local cjson = require("cjson")
local platform = require("core.platform")
local Updater = require("core.lib.Updater")
local M = {}
local serial = 0

-- PowerShell and .NET ship with supported Windows versions. No gh, curl, extra
-- runtime or GitHub credentials are required on an installed machine.
M.SCRIPT = [=[param([Parameter(Mandatory=$true)][string]$PlanPath)
$ErrorActionPreference = 'Stop'
$response = $null
$client = $null
$handler = $null
$output = $null
$inputStream = $null
$deadline = $null
$partial = $null
try {
    $plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($plan.name -notmatch '^LunarExtensionHost-[0-9]+\.[0-9]+\.[0-9]+\.msi$') { throw 'Invalid installer filename' }
    if ($plan.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Missing SHA-256' }
    $target = Join-Path $PSScriptRoot $plan.name
    $partial = $target + '.part'
    $uri = [Uri]$plan.url
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $handler = New-Object Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $client = New-Object Net.Http.HttpClient($handler)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Lunar-Updater')
    $client.Timeout = [TimeSpan]::FromMinutes(5)
    $deadline = New-Object Threading.CancellationTokenSource
    $deadline.CancelAfter(300000)
    for ($hop = 0; $hop -le 5; $hop++) {
        if ($uri.Scheme -ne 'https') { throw 'Update downloads require HTTPS' }
        $response = $client.GetAsync($uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
        $status = [int]$response.StatusCode
        if ($status -in @(301,302,303,307,308)) {
            if ($hop -eq 5 -or -not $response.Headers.Location) { throw 'Too many redirects or missing download location' }
            $uri = New-Object Uri($uri, $response.Headers.Location)
            $response.Dispose()
            $response = $null
            continue
        }
        [void]$response.EnsureSuccessStatusCode()
        break
    }
    $limit = 536870912
    $total = $response.Content.Headers.ContentLength
    if ($total -and $total -gt $limit) { throw 'Installer exceeds the download limit' }
    @{v=1;type='progress';done=0;total=$total;message='Downloading Lunar update'} | ConvertTo-Json -Compress
    $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $output = [IO.File]::Open($partial, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $buffer = New-Object byte[] 65536
    $received = 0L
    $reported = 0L
    while (($count = $inputStream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -gt 0) {
        $received += $count
        if ($received -gt $limit) { throw 'Installer exceeds the download limit' }
        $output.Write($buffer, 0, $count)
        if ($received - $reported -ge 524288) {
            @{v=1;type='progress';done=$received;total=$total;message='Downloading Lunar update'} | ConvertTo-Json -Compress
            $reported = $received
        }
    }
    $output.Dispose()
    $output = $null
    if ($total -and $received -ne $total) { throw 'Installer download was incomplete' }
    if ((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $plan.sha256) { throw 'Installer SHA-256 does not match the published release' }
    [IO.File]::Move($partial, $target)
    @{v=1;type='result';ok=$true;summary='Lunar update downloaded and verified'} | ConvertTo-Json -Compress
} catch {
    @{v=1;type='result';ok=$false;summary=$_.Exception.Message} | ConvertTo-Json -Compress
    exit 1
} finally {
    if ($output) { $output.Dispose() }
    if ($inputStream) { $inputStream.Dispose() }
    if ($response) { $response.Dispose() }
    if ($client) { $client.Dispose() }
    if ($handler) { $handler.Dispose() }
    if ($deadline) { $deadline.Dispose() }
    if ($partial -and (Test-Path -LiteralPath $partial)) { Remove-Item -LiteralPath $partial -Force }
}
]=]

local function write(path, text)
	local file, err = io.open(path, "wb")
	if not file then return nil, err end
	local ok, why = file:write(text)
	local closed, close_error = file:close()
	return ok and closed, why or close_error
end

--- Start a host-owned download job. `done(path, error)` receives a local MSI
-- path only after the helper has validated the published hash.
-- @tparam table opts `{ host, installer, cache_dir }`
-- @tparam function done completion callback
-- @treturn table|nil job
-- @treturn string|nil immediate failure reason
function M.start(opts, done)
	local asset = opts.installer
	if type(asset) ~= "table" or not Updater.parse_version(asset.version)
		or not asset.version:match("^%d+%.%d+%.%d+$")
		or asset.name ~= "LunarExtensionHost-" .. asset.version .. ".msi"
		or asset.url ~= Updater.RELEASES .. "/download/v" .. asset.version .. "/" .. asset.name
		or type(asset.sha256) ~= "string" or #asset.sha256 ~= 64 or asset.sha256:find("[^%x]") then
		return nil, "Invalid GitHub installer metadata"
	end
	serial = serial + 1
	local root = opts.cache_dir or platform.path:join(platform.cache_dir(), "updates")
	local dir = platform.path:join(root, string.format("%s-%d-%d-%d", asset.version,
		tonumber(rawget(_G, "LUNAR_PID")) or 0, os.time(), serial))
	if not Updater.safe_path(dir) or not dir:match("^%a:\\") then
		return nil, "The update cache must be a local Windows folder"
	end
	local ok, err = platform.mkdirs(dir)
	if not ok then return nil, "Could not create the update cache: " .. tostring(err) end
	local script, plan = platform.path:join(dir, "download.ps1"), platform.path:join(dir, "download.json")
	local function cleanup() os.remove(script); os.remove(plan); os.remove(platform.path:join(dir, asset.name .. ".part")) end
	ok, err = write(script, M.SCRIPT)
	if ok then ok, err = write(plan, cjson.encode(asset)) end
	if not ok then cleanup(); return nil, "Could not prepare the update download: " .. tostring(err) end
	local target = platform.path:join(dir, asset.name)
	local job, why = opts.host:startJob({
		argv = { "powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
			"-File", script, "-PlanPath", plan }, cwd = dir,
		activity = { title = "Download Lunar " .. asset.version, cancel = true },
		on_exit = function(result)
			cleanup()
			if result.status == "ok" then done(target)
			else done(nil, result.summary or result.stderr_tail or "Update download failed") end
		end,
	})
	if not job then cleanup(); return nil, why end
	return job
end

return M

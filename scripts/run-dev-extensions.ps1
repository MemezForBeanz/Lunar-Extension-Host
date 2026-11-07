# Run every project extension in its supported host: desktop plus a private dev server.
[CmdletBinding()]
param([int]$Port = 18421, [switch]$SmokeTest)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $repo 'build/win/bin'
$state = Join-Path $repo 'build/dev-extensions'
foreach ($exe in @('Lunar.exe', 'LunarCLI.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $bin $exe))) { throw 'Build the dev preset first.' }
}
# Fail before starting anything if another session owns this port.
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
try { $listener.Start() } finally { $listener.Stop() }
New-Item -ItemType Directory -Path $state -Force | Out-Null
$bytes = New-Object byte[] 32
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
$token = [Convert]::ToBase64String($bytes)
$tokensFile = Join-Path $state 'tokens'
[IO.File]::WriteAllText($tokensFile, "dev $token`n")
$saved = @{}
foreach ($name in @('LUNAR_DEV_EXTENSIONS', 'LUNAR_MEDIA_SERVER', 'LUNAR_MEDIA_TOKEN', 'LUNAR_MEDIA_DEMO')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$server = $null; $gui = $null
try {
    $env:LUNAR_DEV_EXTENSIONS = '1'
    $env:LUNAR_MEDIA_SERVER = "http://127.0.0.1:$Port"
    $env:LUNAR_MEDIA_TOKEN = $token
    $env:LUNAR_MEDIA_DEMO = '0'
    $serverArgs = @('--headless', '--dev', '--extensions', ('"' + (Join-Path $repo 'extensions') + '"'),
        '--require', 'media-server', '--listen', "127.0.0.1:$Port", '--tokens-file', ('"' + $tokensFile + '"'),
        '--state-dir', ('"' + (Join-Path $state 'state') + '"'))
    $server = Start-Process -FilePath (Join-Path $bin 'LunarCLI.exe') -ArgumentList $serverArgs -WorkingDirectory $bin -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput (Join-Path $state 'server.log') -RedirectStandardError (Join-Path $state 'server-error.log')
    $ready = $false
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        if ($server.HasExited) { throw "Dev server exited. See $state/server-error.log" }
        try {
            $status = Invoke-RestMethod "$env:LUNAR_MEDIA_SERVER/ext/media-server/v1/status" -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 1
            $ready = $null -ne $status; break
        } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ready) { throw "Dev server did not become ready. See $state/server-error.log" }
    Write-Host "Project extensions: $(Join-Path $repo 'extensions')"
    Write-Host "Private dev media server: $env:LUNAR_MEDIA_SERVER (state: $state)"
    $gui = Start-Process -FilePath (Join-Path $bin 'Lunar.exe') -WorkingDirectory $bin -PassThru `
        -RedirectStandardOutput (Join-Path $state 'desktop.log') -RedirectStandardError (Join-Path $state 'desktop-error.log')
    if ($SmokeTest) {
        Start-Sleep -Seconds 5
        if ($gui.HasExited) { throw "Desktop exited early. See $state/desktop-error.log" }
        if ($server.HasExited) { throw 'Dev server exited while the desktop was running.' }
        $errors = Get-Content -LiteralPath (Join-Path $state 'desktop-error.log') -Raw
        if ($errors) { throw $errors }
        Write-Host 'Dev desktop and media server stayed running; no desktop startup errors.'
    } else { $gui.WaitForExit() }
} finally {
    foreach ($process in @($gui, $server)) {
        if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    }
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    # Discard this session's token; the development catalog remains for the next run.
    Remove-Item -LiteralPath $tokensFile -Force -ErrorAction SilentlyContinue
}

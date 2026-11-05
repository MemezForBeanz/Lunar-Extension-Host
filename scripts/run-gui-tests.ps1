# VS Code task launcher. Inputs arrive through the environment, never shell code.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$selection = $env:LUNAR_TEST_SCRIPTS
if (-not [string]::IsNullOrWhiteSpace($env:LUNAR_TEST_OVERRIDE)) {
    $selection = $env:LUNAR_TEST_OVERRIDE
}
if ([string]::IsNullOrWhiteSpace($selection)) { throw 'Choose at least one Lua script.' }
$scripts = @($selection -split '[,;]' | ForEach-Object {
    $name = $_.Trim()
    if (-not $name) { throw 'Empty script name between separators.' }
    if (-not $name.EndsWith('.lua')) { $name += '.lua' }
    if ($name -match '[/\\:]' -or $name -eq '..lua') {
        throw "Use a filename from scripts/, not a path: $name"
    }
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Script not found: $path" }
    $path
})
$bin = Join-Path $repo 'build/win/bin'
$exe = Join-Path $bin 'Lunar.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw 'Build the dev executable first.' }
$env:LUNAR_REPO = $repo
if ($env:LUNAR_TEST_ALL_PACKS -eq 'yes') {
    if (-not (Test-Path -LiteralPath $env:LUNAR_TEST_PACKS_DIR -PathType Container)) {
        throw 'Org packs directory does not exist.'
    }
    $env:LUNAR_PROFILE_DIR = (Resolve-Path -LiteralPath $env:LUNAR_TEST_PACKS_DIR).Path
    $env:LUNAR_PROFILE = '*'
} else {
    Remove-Item Env:LUNAR_PROFILE, Env:LUNAR_PROFILE_DIR -ErrorAction SilentlyContinue
}
$failed = $false
foreach ($script in $scripts) {
    Write-Host "Running $script"
    # Each harness owns its event loop and may call os.exit; isolate each process.
    $process = Start-Process -FilePath $exe -ArgumentList ('"' + $script + '"') -WorkingDirectory $bin -NoNewWindow -PassThru -Wait
    Write-Host "Exited with code $($process.ExitCode)"
    if ($process.ExitCode -ne 0) { $failed = $true }
}
if ($failed) { exit 1 }

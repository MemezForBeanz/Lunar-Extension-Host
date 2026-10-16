# scripts/docs.ps1 — generate the Lunar API reference site with LDoc.
#
# Uses the ldoc installed in the vendored luarocks tree, run through
# scripts\rock-tool.ps1. Restore it first with
# scripts\fetch-deps.ps1 -Dev if it is missing.
#
# The site is generated from config.ld: LDoc doc comments in src\lua\core and
# src\c\libs plus the hand-written topics under docs\.
#
# Usage:
#   scripts\docs.ps1                  # build to dist\docs
#   scripts\docs.ps1 -Check           # build, then fail on any LDoc warning
#   scripts\docs.ps1 -Serve           # build, then open the site in a browser
#   scripts\docs.ps1 -OutDir out\docs # build somewhere else

param(
	[string]$OutDir = "dist\docs",
	[switch]$Check,
	[switch]$Serve
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

. (Join-Path $PSScriptRoot "rock-tool.ps1")

$outPath = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $repo $OutDir }

# Start from a clean output directory so removed modules/topics don't linger as
# stale pages in a published site.
if (Test-Path $outPath) { Remove-Item $outPath -Recurse -Force }
New-Item -ItemType Directory -Path $outPath -Force | Out-Null

Write-Host "[docs] Generating API reference into $outPath..." -ForegroundColor Cyan

# LDoc evaluates config.ld in a sandbox without `io`/`os`, so the documented
# version cannot be read from the source there. Generate a copy of the config
# beside the original (so every relative path still resolves) with APP_VERSION
# appended.
$mainLua = Get-Content (Join-Path $repo "src\lua\core\main.lua") -Raw
$version = if ($mainLua -match 'local\s+APP_VERSION\s*=\s*"([^"]+)"') { $Matches[1] } else { "dev" }
$generatedConfig = Join-Path $repo "config.generated.ld"
$configText = Get-Content (Join-Path $repo "config.ld") -Raw
# Plain UTF-8 without a BOM: Lua's loader chokes on a leading byte-order mark.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($generatedConfig, $configText + "`nversion = `"$version`"`n", $utf8NoBom)

# LDoc writes warnings to stderr and still exits 0, so capture everything and
# decide the exit status here.
try {
	$output = Invoke-RockTool ldoc --config $generatedConfig --dir $outPath . 2>&1
	$ldocExit = $LASTEXITCODE
} finally {
	Remove-Item $generatedConfig -Force -ErrorAction SilentlyContinue
}
$output | ForEach-Object { Write-Host $_ }

if ($ldocExit -ne 0) {
	Write-Error "ldoc failed with exit code $ldocExit."
	exit $ldocExit
}

$index = Join-Path $outPath "index.html"
if (-not (Test-Path $index)) {
	Write-Error "ldoc produced no index.html in $outPath."
	exit 1
}

# GitHub Pages runs Jekyll by default, which drops files and directories whose
# names begin with an underscore. LDoc does not emit any today, but .nojekyll is
# cheap insurance and also skips a pointless build step on the Pages side.
New-Item -ItemType File -Path (Join-Path $outPath ".nojekyll") -Force | Out-Null

# Site favicon (referenced by config.ld).
$icon = Join-Path $repo "assets\lunar-icon-32.png"
if (Test-Path $icon) {
	Copy-Item $icon (Join-Path $outPath "favicon.png") -Force
}

# The optional drive letter matters: LDoc prints absolute Windows paths ("c:\...:12:"),
# which the old pattern never matched, so those warnings slipped through the gate.
$warnings = @($output | Where-Object { "$_" -match "^(ldoc: )?([A-Za-z]:)?[^:]*:\d+:" -or "$_" -match "(?i)warning" })
if ($warnings.Count -gt 0) {
	Write-Host "[docs] $($warnings.Count) LDoc warning(s)." -ForegroundColor Yellow
	if ($Check) {
		Write-Error "Documentation check failed: resolve the LDoc warnings above."
		exit 1
	}
} else {
	Write-Host "[docs] No LDoc warnings." -ForegroundColor Green
}

Write-Host "[docs] Done: $index" -ForegroundColor Green

if ($Serve) {
	Start-Process $index
}

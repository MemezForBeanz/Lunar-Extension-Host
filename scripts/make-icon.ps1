# scripts/make-icon.ps1 — rebuild assets\lunar.ico and assets\lunar-icon-32.png
# from assets\lunar-icon.svg.
#
# The SVG embeds PNG layers, which nanosvg and other small renderers can't draw,
# so each size is rendered by headless Edge (or Chrome) and packed by
# scripts\make_icon.py. Run it after replacing the SVG, then rebuild so the
# exe picks up the new ICON resource (assets\LunarExtensionHost.rc).
#
# Usage:
#   scripts\make-icon.ps1

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $repo "assets"
$svg = Join-Path $assets "lunar-icon.svg"

$browser = @(
	"${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
	"$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
	"$env:ProgramFiles\Google\Chrome\Application\chrome.exe"
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $browser) { throw "Needs Microsoft Edge or Google Chrome to render the SVG." }

$work = Join-Path ([IO.Path]::GetTempPath()) ("lunar-icon-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $work | Out-Null
try {
	Copy-Item $svg (Join-Path $work "lunar.svg")
	$url = "file:///" + ($work -replace '\\', '/')
	foreach ($size in 16, 20, 24, 32, 40, 48, 64, 128, 256) {
		$page = "<!doctype html><body style='margin:0;background:transparent'>" +
			"<img src='lunar.svg' width='$size' height='$size' style='display:block'></body>"
		[IO.File]::WriteAllText((Join-Path $work "r$size.html"), $page)
		$png = Join-Path $work "lunar-$size.png"
		# The browser reports progress on stderr, which Windows PowerShell turns
		# into an error under "Stop": check for the file instead.
		$ErrorActionPreference = "Continue"
		& $browser --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 `
			--force-device-scale-factor=1 "--window-size=$size,$size" `
			"--screenshot=$png" "$url/r$size.html" 2>&1 | Out-Null
		$ErrorActionPreference = "Stop"
		if (-not (Test-Path $png)) { throw "The browser didn't render $size px." }
	}
	& py -3 (Join-Path $PSScriptRoot "make_icon.py") $work $assets
	if ($LASTEXITCODE -ne 0) { throw "make_icon.py failed." }
} finally {
	Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}

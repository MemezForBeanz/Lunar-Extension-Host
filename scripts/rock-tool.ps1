# scripts/rock-tool.ps1 — run a dev-tool rock (busted, luacheck, ldoc) under the
# vendored LuaJIT, without the LuaRocks-generated launchers.
#
# Usage (dot-source it, then call the function):
#   . (Join-Path $PSScriptRoot "rock-tool.ps1")
#   Invoke-RockTool busted --verbose
#   exit $LASTEXITCODE        # the tool's exit code, as with any native command
#
# Why not vendor\luarocks-tree\bin\*.bat: LuaRocks bakes absolute paths into
# those launchers at install time, so they break as soon as the checkout moves
# (a different user, a different folder, a CI workspace). This resolves the
# interpreter, the rock tree and the tool's entry script relative to the repo on
# every call, so a moved checkout keeps working with no reinstall.
#
# Unlike scripts\lua-env.ps1 this needs no MinGW toolchain: running tools only
# needs LuaJIT and the already-installed rock tree. Restore the tree with
# scripts\fetch-deps.ps1 -Dev if a tool is missing.

# Rock versions installed by scripts\fetch-deps.ps1 -Dev. Keep the two in sync:
# pinning here (rather than picking the "newest" directory) avoids reimplementing
# LuaRocks' version ordering and makes a stale tree fail loudly.
$script:RockToolVersions = @{
	busted   = "2.3.0-1"
	luacheck = "1.2.0-1"
	ldoc     = "1.5.0-1"
}

# Deliberately a plain function reading $args (no param block): an advanced
# function would swallow tool flags such as -v or -e as PowerShell common
# parameters (-Verbose, -ErrorAction) instead of passing them through.
function Invoke-RockTool {
	if ($args.Count -lt 1) {
		Write-Error "Usage: Invoke-RockTool <tool> [args...]"
		$global:LASTEXITCODE = 1; return
	}
	$Tool = [string]$args[0]
	$ToolArgs = @($args | Select-Object -Skip 1)

	$repo = Split-Path -Parent $PSScriptRoot
	$tree = Join-Path $repo "vendor/luarocks-tree"
	$isWin = [System.IO.Path]::DirectorySeparatorChar -eq '\'

	$luajit = Join-Path $repo ("vendor/luajit/bin/" + $(if ($isWin) { "luajit.exe" } else { "luajit" }))
	if (-not (Test-Path $luajit)) {
		$onPath = Get-Command luajit -ErrorAction SilentlyContinue
		if (-not $onPath) {
			Write-Error "LuaJIT not found at $luajit or on PATH. Run scripts\fetch-deps.ps1 first."
			$global:LASTEXITCODE = 1; return
		}
		$luajit = $onPath.Source
	}

	$version = $script:RockToolVersions[$Tool]
	if (-not $version) {
		Write-Error "Unknown rock tool '$Tool' (known: $($script:RockToolVersions.Keys -join ', '))."
		$global:LASTEXITCODE = 1; return
	}
	$entry = Join-Path $tree "lib/luarocks/rocks-5.1/$Tool/$version/bin/$Tool"
	if (-not (Test-Path $entry)) {
		Write-Error "$Tool $version is not installed in $tree. Run scripts\fetch-deps.ps1 -Dev first."
		$global:LASTEXITCODE = 1; return
	}

	$ext = if ($isWin) { "dll" } else { "so" }
	$share = Join-Path $tree "share/lua/5.1"
	$lib = Join-Path $tree "lib/lua/5.1"
	$savedPath, $savedCpath = $env:LUA_PATH, $env:LUA_CPATH
	$env:LUA_PATH = "$share/?.lua;$share/?/init.lua;;"
	$env:LUA_CPATH = "$lib/?.$ext;;"
	if (-not $env:LUNAR_REPO) { $env:LUNAR_REPO = $repo }
	# Callers run under ErrorActionPreference=Stop, and Windows PowerShell 5.1
	# turns any stderr line from a native tool into a terminating error once it is
	# redirected (docs.ps1 captures 2>&1 to count LDoc warnings). The exit code is
	# the tool's verdict, so relax the preference for the call only.
	$savedEap = $ErrorActionPreference
	$ErrorActionPreference = "Continue"
	try {
		& $luajit $entry @ToolArgs
	} finally {
		$ErrorActionPreference = $savedEap
		$env:LUA_PATH, $env:LUA_CPATH = $savedPath, $savedCpath
	}
}

# scripts/lint.ps1 — run luacheck over the Lunar Lua sources.
#
# Uses the luacheck installed in the vendored luarocks tree, run through
# scripts\rock-tool.ps1. Restore it first with
# scripts\fetch-deps.ps1 if it is missing.
#
# Usage:
#   scripts\lint.ps1            # lint src/lua, plugins, scripts
#   scripts\lint.ps1 -Paths a,b # lint specific paths

param(
	[string[]]$Paths = @("src/lua", "plugins", "scripts")
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

. (Join-Path $PSScriptRoot "rock-tool.ps1")

Invoke-RockTool luacheck @Paths
exit $LASTEXITCODE

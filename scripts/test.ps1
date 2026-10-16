# scripts/test.ps1 — run the busted spec suite for Lunar.
#
# Uses busted from the vendored luarocks tree. Specs live in spec\ and are
# configured by the repo-root .busted file (paths, cpath). Restore the tree with
# scripts\fetch-deps.ps1 if busted is missing.
#
# Usage:
#   scripts\test.ps1                          # run all specs
#   scripts\test.ps1 spec\foo_spec.lua -o TAP  # any busted args pass straight through
#
# Deliberately no param() block: a [Parameter()] attribute makes this an advanced
# script, and PowerShell then claims short busted flags such as -o and -v as its
# own common parameters (-OutVariable, -Verbose). $args forwards them untouched.

$BustedArgs = @($args | Where-Object { $_ -ne "--" })

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

. (Join-Path $PSScriptRoot "rock-tool.ps1")

# LUNAR_REPO lets any spec/module resolve the repo root the same way scripts do.
$env:LUNAR_REPO = $repo

Invoke-RockTool busted @BustedArgs
exit $LASTEXITCODE

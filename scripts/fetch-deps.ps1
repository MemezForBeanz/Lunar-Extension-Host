# scripts/fetch-deps.ps1 — restore the project-local Lua rock tree.
#
# This is the canonical "restore dependencies" step for a fresh checkout. It:
#   1. activates the vendored LuaJIT + LuaRocks environment (scripts\lua-env.ps1),
#   2. installs the runtime dependencies pinned in the rockspec into
#      vendor\luarocks-tree\ (--only-deps),
#   3. builds lua-cjson from the vendored source so the rock matches the copy
#      CMake statically links into the executable,
#   4. curls serpent.lua into the tree (serpent cannot be installed from
#      luarocks.org here because its git+SSL fetch fails), and
#   5. optionally installs the dev tools (luacheck, busted, ldoc) when -Dev is
#      passed.
#
# Everything targets Lua 5.1 (the LuaJIT ABI) — the same runtime the GUI ships
# with, so specs and lint exercise the code exactly as it executes in production.
#
# Usage:
#   scripts\fetch-deps.ps1          # runtime deps + cjson + serpent
#   scripts\fetch-deps.ps1 -Dev     # also install luacheck + busted + ldoc

param(
	[switch]$Dev
)

# LuaRocks writes progress to stderr, which PowerShell surfaces as an error
# record. Under $ErrorActionPreference = "Stop" that becomes a *terminating*
# error and aborts a perfectly successful install, so gate on $LASTEXITCODE
# explicitly instead (every native call below is checked).
$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

# 1. Activate the vendored luajit/luarocks toolchain (puts luarocks on PATH,
#    points LUA_PATH/LUA_CPATH at the local tree, and sets LUNAR_LUA_DIR).
. .\scripts\lua-env.ps1

$tree = Join-Path $repo "vendor\luarocks-tree"
$rockspec = Join-Path $repo "lunarextensionhost-dev-1.rockspec"

# LuaRocks has no persistent per-project config, so every invocation must be told
# which Lua it is building for. Without these it falls back to whatever
# interpreter it finds first and would produce a tree for the wrong ABI.
$lua = @("--lua-version", "5.1", "--lua-dir", $env:LUNAR_LUA_DIR)

# 2. Runtime dependencies (lfs, luasocket, middleclass, argparse, tableshape,
#    date, lualogging). cjson is deliberately absent from the rockspec and is
#    built from vendored source in step 3.
Write-Host "`n[fetch-deps] Installing runtime dependencies..." -ForegroundColor Cyan
luarocks @lua install --tree $tree --only-deps $rockspec
if ($LASTEXITCODE -ne 0) { throw "runtime --only-deps install failed" }

# 3. lua-cjson built from vendor\lua-cjson (the same 2.1devel source CMake
#    compiles into the exe). luarocks.org has no 2.1devel rock for 5.1, and a
#    different cjson in the test tree than in the shipped binary would let
#    encoding differences slip through the suite unnoticed. USE_LUAJIT tells
#    lua_cjson.c that luaL_setfuncs exists despite LUA_VERSION_NUM being 501.
Write-Host "`n[fetch-deps] Building lua-cjson from vendored source..." -ForegroundColor Cyan
Push-Location (Join-Path $repo "vendor\lua-cjson")
try {
	luarocks @lua make --tree $tree .\lua-cjson-2.1devel-1.rockspec CFLAGS="-O2 -DUSE_LUAJIT"
	if ($LASTEXITCODE -ne 0) { throw "lua-cjson build failed" }
} finally {
	# luarocks make builds in place; don't leave objects in the vendor tree.
	Remove-Item .\*.o -Force -ErrorAction SilentlyContinue
	Pop-Location
}

# 4. serpent (debug table serialization) — fetched directly because its rockspec
#    pulls from git over SSL, which fails in this environment.
$serpentDir = Join-Path $tree "share\lua\5.1"
$serpentPath = Join-Path $serpentDir "serpent.lua"
if (Test-Path $serpentPath) {
	Write-Host "[fetch-deps] serpent.lua already present." -ForegroundColor DarkGray
} else {
	Write-Host "[fetch-deps] Fetching serpent.lua..." -ForegroundColor Cyan
	New-Item -ItemType Directory -Path $serpentDir -Force | Out-Null
	# Pinned to a commit (0.303 has no release tag) and checked by hash, so a
	# change upstream can't silently change what gets installed.
	$serpentCommit = "ed98a21db64e9e8f44403394400f84f4daecb60d"
	$serpentSha256 = "E90783BF50A5F6ACE6691C0607B7C5020C2BFFE174D3BE63A1BEE3DD198B5CCD"
	$serpentUrl = "https://raw.githubusercontent.com/pkulchenko/serpent/$serpentCommit/src/serpent.lua"
	# --ssl-no-revoke avoids CRL check failures behind some corporate proxies.
	curl.exe --ssl-no-revoke -fsSL $serpentUrl -o $serpentPath
	if ($LASTEXITCODE -ne 0) { throw "serpent.lua fetch failed" }
	if ((Get-FileHash $serpentPath -Algorithm SHA256).Hash -ne $serpentSha256) {
		Remove-Item $serpentPath
		throw "serpent.lua does not match the pinned SHA-256"
	}
}

# 5. Dev tools (opt-in). busted's luasystem C-rock compiles against the LuaJIT
#    headers/lib, which --lua-dir already supplies.
if ($Dev) {
	Write-Host "`n[fetch-deps] Installing dev tools (luacheck, busted, ldoc)..." -ForegroundColor Cyan
# Versions are pinned again in scripts\rock-tool.ps1 ($RockToolVersions); bump both together.
	luarocks @lua install --tree $tree luacheck 1.2.0
	if ($LASTEXITCODE -ne 0) { throw "luacheck install failed" }
	luarocks @lua install --tree $tree busted 2.3.0
	if ($LASTEXITCODE -ne 0) { throw "busted install failed" }
	# ldoc generates the API reference site (scripts\docs.ps1). It pulls in the
	# pure-Lua `markdown` rock for doc-comment and topic rendering; penlight is
	# already present as an ldoc dependency.
	luarocks @lua install --tree $tree ldoc 1.5.0
	if ($LASTEXITCODE -ne 0) { throw "ldoc install failed" }
}

Write-Host "`n[fetch-deps] Done. Tree: $tree" -ForegroundColor Green

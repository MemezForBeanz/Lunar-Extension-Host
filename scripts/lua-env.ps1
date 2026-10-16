# scripts/lua-env.ps1 — activate the project-local LuaJIT + LuaRocks environment.
#
# Usage (dot-source it):
#   . .\scripts\lua-env.ps1
#
# After sourcing, `luajit` and `luarocks` are on PATH and LUA_PATH/LUA_CPATH
# resolve the project-local rock tree.
#
# Lunar runs LuaJIT 2.1 (Lua 5.1 ABI) everywhere: the shipped GUI, the busted
# spec suite, luacheck, and ldoc. There is deliberately no second Lua version —
# testing on a different VM than we ship on hides real behavioral differences
# (integer division, %d formatting, error-message wording, and the absence of
# `ffi` entirely). See docs/index.md and README.md.
#
# This file replaces the old, untracked vendor\lua-env.ps1. It lives under
# scripts\ so it is version-controlled (vendor\ is gitignored).
#
# LuaRocks needs `--lua-version 5.1 --lua-dir $env:LUNAR_LUA_DIR` on every
# invocation; scripts\fetch-deps.ps1 does this for you.

# This script is dot-sourced, so it executes in the caller's scope and any
# preference it sets would leak. Stop is right for the setup below (a failed
# Copy-Item must not be silently ignored), but leaving it set breaks callers
# that invoke native tools: LuaRocks and git write progress to stderr, which
# PowerShell turns into a *terminating* error under Stop. Restore at the end.
$lunarPrevEap = $ErrorActionPreference
$ErrorActionPreference = "Stop"

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$repo = Split-Path -Parent $scriptDir

# MinGW toolchain (gcc/ar/make) used to build the C rocks. Override with
# LUNAR_MINGW_BIN if MSYS2 lives somewhere else.
$mingwBin = if ($env:LUNAR_MINGW_BIN) { $env:LUNAR_MINGW_BIN } else { "C:\msys64\mingw64\bin" }
if (-not (Test-Path $mingwBin)) {
	throw "MinGW bin directory not found: $mingwBin. Install MSYS2 or set LUNAR_MINGW_BIN."
}

$luaDir      = Join-Path $repo "vendor\luajit"
$luaBinDir   = Join-Path $luaDir "bin"
$luaRocksVer = "3.13.0"
$luaRocksDir = Join-Path $repo "vendor\luarocks-$luaRocksVer-windows-64"
$luaTree     = Join-Path $repo "vendor\luarocks-tree"

# vendor\ is gitignored, so a fresh clone has no LuaRocks at all. Without this
# the script would still "activate" successfully and every later call would fail
# with a bare "'luarocks' is not recognized", which points nowhere useful.
$luaRocksExe = Join-Path $luaRocksDir "luarocks.exe"
if (-not (Test-Path $luaRocksExe)) {
	$zipUrl = "https://luarocks.github.io/luarocks/releases/luarocks-$luaRocksVer-windows-64.zip"
	$zip    = Join-Path $env:TEMP "luarocks-$luaRocksVer-windows-64.zip"
	Write-Host "[lua-env] LuaRocks missing; downloading $luaRocksVer..." -ForegroundColor DarkYellow
	# --ssl-no-revoke avoids CRL check failures behind some corporate proxies.
	curl.exe --ssl-no-revoke -fsSL $zipUrl -o $zip
	if ($LASTEXITCODE -ne 0) { throw "LuaRocks download failed: $zipUrl" }
	# The archive contains a top-level luarocks-<ver>-windows-64\ directory, so
	# expand into vendor\ rather than into the target directory itself.
	Expand-Archive -Path $zip -DestinationPath (Join-Path $repo "vendor") -Force
	Remove-Item $zip -Force -ErrorAction SilentlyContinue
	if (-not (Test-Path $luaRocksExe)) { throw "LuaRocks extraction did not produce $luaRocksExe" }
}

# The interpreter is not part of the prebuilt LuaJIT drop (which ships only
# headers + libluajit-5.1.a), so fall back to the MSYS2 build. Both are the same
# LuaJIT 2.1 release, so the ABI matches the statically linked archive.
$luajitExe = Join-Path $luaBinDir "luajit.exe"
if (-not (Test-Path $luajitExe)) {
	$mingwLuajit = Join-Path $mingwBin "luajit.exe"
	if (-not (Test-Path $mingwLuajit)) {
		throw "No luajit.exe found in $luaBinDir or $mingwBin. Run 'pacman -S mingw-w64-x86_64-luajit' in MSYS2."
	}
	Write-Host "[lua-env] vendor\luajit\bin\luajit.exe missing; seeding it from $mingwBin" -ForegroundColor DarkYellow
	New-Item -ItemType Directory -Force -Path $luaBinDir | Out-Null
	Copy-Item $mingwLuajit $luajitExe -Force
	# lua51.dll is what C rocks link against, so it must sit beside the exe and
	# in lib\ (LuaRocks resolves LUA_LIBDIR_FILE from there).
	Copy-Item (Join-Path $mingwBin "lua51.dll") (Join-Path $luaBinDir "lua51.dll") -Force
	New-Item -ItemType Directory -Force -Path (Join-Path $luaDir "lib") | Out-Null
	Copy-Item (Join-Path $mingwBin "lua51.dll") (Join-Path $luaDir "lib\lua51.dll") -Force
}

# LuaRocks expects <lua-dir>\include\lua.h; the vendored drop puts headers in
# src\, so mirror them once.
$luaIncDir = Join-Path $luaDir "include"
if (-not (Test-Path (Join-Path $luaIncDir "lua.h"))) {
	New-Item -ItemType Directory -Force -Path $luaIncDir | Out-Null
	Copy-Item (Join-Path $luaDir "src\*.h*") $luaIncDir -Force
}

$env:PATH = "$luaRocksDir;$luaBinDir;$mingwBin;" + $env:PATH

# LuaRocks 5.1 tree layout.
$env:LUA_PATH  = "$luaTree\share\lua\5.1\?.lua;$luaTree\share\lua\5.1\?\init.lua;;"
$env:LUA_CPATH = "$luaTree\lib\lua\5.1\?.dll;;"

# Excludes c:\windows\system32 from LuaRocks' external-dependency search, which
# otherwise breaks every C rock link under MinGW. See the file for details.
$env:LUAROCKS_CONFIG = Join-Path $scriptDir "luarocks-config.lua"

# Consumed by scripts\fetch-deps.ps1 (and handy for manual luarocks calls).
$env:LUNAR_LUA_DIR = $luaDir
$env:LUNAR_REPO    = $repo

Write-Host "LuaJIT environment activated:"
Write-Host "  luajit   -> $luajitExe"
Write-Host "  luarocks -> $luaRocksDir\luarocks.exe (use --lua-version 5.1 --lua-dir `$env:LUNAR_LUA_DIR)"
Write-Host "  tree     -> $luaTree"

$ErrorActionPreference = $lunarPrevEap
Remove-Variable lunarPrevEap

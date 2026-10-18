# scripts/bootstrap.ps1 — make a fresh checkout buildable.
#
# vendor\ holds two kinds of dependency:
#
#   Tracked in Git (CMake builds them):
#     luafilesystem, lua-cjson, luasocket, luasec, copas, nanosvg, certs\cacert.pem,
#     subprocess.h. They are kept exactly as Lunar builds them, local fixes included.
#
#   Restored here from pinned sources, each checked against a SHA-256:
#     LuaJIT    one pinned commit, built with MinGW twice: the static library the
#               exe links, and luajit.exe + lua51.dll for busted, luacheck, ldoc and
#               LuaRocks. One LuaJIT everywhere, so tests run what ships.
#     IUP 3.32  the official MinGW static libraries and headers the exe links
#               (libiup.a itself is built from iup-fork\ by CMake).
#     OpenSSL   scripts\build-openssl.ps1 (a trimmed static build; several minutes).
#   then scripts\fetch-deps.ps1 fills the LuaRocks tree.
#
# Each step is skipped when its output is already there; -Force redoes them.
#
# Needs: MSYS2 MinGW-w64 at C:\msys64 (gcc, mingw32-make, perl for OpenSSL), and
# curl.exe and tar.exe, which ship with Windows 10/11.
#
# Usage:
#   scripts\bootstrap.ps1          # everything needed to build
#   scripts\bootstrap.ps1 -Dev     # also busted, luacheck and ldoc
#   scripts\bootstrap.ps1 -Force   # rebuild the restored dependencies

param(
	[switch]$Dev,
	[switch]$Force
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$vendor = Join-Path $repo "vendor"
$cache = Join-Path $vendor ".downloads"
$mingwBin = if ($env:LUNAR_MINGW_BIN) { $env:LUNAR_MINGW_BIN } else { "C:\msys64\mingw64\bin" }
if (-not (Test-Path (Join-Path $mingwBin "mingw32-make.exe"))) {
	throw "MSYS2 MinGW-w64 not found at $mingwBin. Install MSYS2 and 'pacman -S mingw-w64-x86_64-toolchain', or set LUNAR_MINGW_BIN."
}
$env:PATH = "$mingwBin;$env:PATH"

# The pins. Changing one is a dependency update: check the release, then update
# the hash. (GitHub's per-commit archives have been stable, but are not promised
# to be byte-identical forever; if the LuaJIT hash ever fails, re-check the
# commit and re-pin.)
$LuaJIT = @{
	Commit = "1c3b5a4d722598ecbb9219480142eda682e87bb1"   # LuaJIT 2.1.1771261233
	Sha256 = "3e2b93dbb545df2eaa5107c348d6f700404eb5d4e1c04e010abd794b963362d8"
}
$Iup = @(
	@{
		Url = "https://sourceforge.net/projects/iup/files/3.32/Windows%20Libraries/Static/iup-3.32_Win64_mingw6_lib.zip/download"
		File = "iup-3.32_Win64_mingw6_lib.zip"
		Sha256 = "b65b7c56ae084d9d3711f4c2551c8c7dea384459cd27ff599c8dcbec0875d588"
		Libs = @("libiupcontrols.a")
	},
	@{
		Url = "https://sourceforge.net/projects/iup/files/3.32/Windows%20Libraries/Static/Lua51/iup-3.32-Lua51_Win64_mingw6_lib.zip/download"
		File = "iup-3.32-Lua51_Win64_mingw6_lib.zip"
		Sha256 = "cdec0b593b8648ad72ceafecf8f247ee5eee00b82bdebbeaf00e991275c6058e"
		Libs = @("libiuplua51.a", "libiupluacontrols51.a")
	}
)

function Write-Step($m) { Write-Host "`n[bootstrap] $m" -ForegroundColor Cyan }

# Download $url to the cache once and check it against the pinned hash.
function Get-Pinned($url, $file, $sha256) {
	New-Item -ItemType Directory -Force -Path $cache | Out-Null
	$path = Join-Path $cache $file
	if (-not (Test-Path $path) -or (Get-FileHash $path -Algorithm SHA256).Hash.ToLower() -ne $sha256) {
		Write-Host "  downloading $file"
		# --ssl-no-revoke: CRL checks fail behind some corporate proxies.
		curl.exe --ssl-no-revoke -fsSL -o $path $url
		if ($LASTEXITCODE -ne 0) { throw "download failed: $url" }
	}
	$got = (Get-FileHash $path -Algorithm SHA256).Hash.ToLower()
	if ($got -ne $sha256) {
		Remove-Item $path -Force
		throw "$file does not match its pinned SHA-256 (expected $sha256, got $got)"
	}
	return $path
}

# Run a native tool; its stderr chatter must not abort the script (exit codes do).
function Invoke-Native([string]$what, [scriptblock]$cmd) {
	$ErrorActionPreference = "Continue"
	$out = & $cmd 2>&1
	if ($LASTEXITCODE -ne 0) {
		$out | Select-Object -Last 30 | ForEach-Object { Write-Host "  $_" }
		throw "$what failed ($LASTEXITCODE)"
	}
}

# --- LuaJIT ----------------------------------------------------------------------
$lj = Join-Path $vendor "luajit"
if ($Force -or -not (Test-Path (Join-Path $lj "lib\libluajit-5.1.a")) -or -not (Test-Path (Join-Path $lj "bin\luajit.exe"))) {
	Write-Step "LuaJIT $($LuaJIT.Commit.Substring(0, 7))"
	$tgz = Get-Pinned "https://github.com/LuaJIT/LuaJIT/archive/$($LuaJIT.Commit).tar.gz" "luajit-$($LuaJIT.Commit).tar.gz" $LuaJIT.Sha256
	$work = Join-Path $env:TEMP ("lunar-luajit-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
	New-Item -ItemType Directory -Path $work | Out-Null
	try {
		Invoke-Native "extracting LuaJIT" { tar.exe -xzf $tgz -C $work }
		$src = Join-Path $work "LuaJIT-$($LuaJIT.Commit)\src"
		if (Test-Path $lj) { Remove-Item $lj -Recurse -Force }
		foreach ($d in "bin", "lib", "src", "include") { New-Item -ItemType Directory -Force -Path (Join-Path $lj $d) | Out-Null }

		# SHELL=cmd.exe: LuaJIT's Makefile writes cmd syntax when it doesn't detect
		# MSYS, but GNU make on Windows switches to sh whenever one is on PATH (the
		# GitHub runner has Git's), which then fails on the cmd syntax.
		$ljMake = @("SHELL=cmd.exe")

		# Static: the library the exe links.
		Invoke-Native "building LuaJIT (static)" { mingw32-make -C $src @ljMake BUILDMODE=static }
		Copy-Item (Join-Path $src "libluajit.a") (Join-Path $lj "lib\libluajit-5.1.a")
		$headers = "lua.h", "lualib.h", "lauxlib.h", "luaconf.h", "luajit.h", "lua.hpp"
		foreach ($h in $headers) {
			Copy-Item (Join-Path $src $h) (Join-Path $lj "src")
			Copy-Item (Join-Path $src $h) (Join-Path $lj "include")   # where LuaRocks looks
		}

		# Dynamic: the interpreter and lua51.dll that C rocks link against.
		Invoke-Native "cleaning LuaJIT" { mingw32-make -C $src @ljMake clean }
		Invoke-Native "building LuaJIT (dynamic)" { mingw32-make -C $src @ljMake BUILDMODE=dynamic }
		Copy-Item (Join-Path $src "luajit.exe") (Join-Path $lj "bin")
		Copy-Item (Join-Path $src "lua51.dll") (Join-Path $lj "bin")
		Copy-Item (Join-Path $src "lua51.dll") (Join-Path $lj "lib")
		# luajit.exe needs jit\*.lua for -b and the jit.* tools.
		Copy-Item (Join-Path $src "jit") (Join-Path $lj "bin\lua\jit") -Recurse
	} finally {
		Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
	}
	Write-Host "  $(& (Join-Path $lj 'bin\luajit.exe') -v)"
}

# --- IUP ---------------------------------------------------------------------------
$iupDir = Join-Path $vendor "iup"
$iupLibs = $Iup | ForEach-Object { $_.Libs } | ForEach-Object { Join-Path $iupDir $_ }
if ($Force -or ($iupLibs | Where-Object { -not (Test-Path $_) }) -or -not (Test-Path (Join-Path $iupDir "include\iup.h"))) {
	Write-Step "IUP 3.32 libraries"
	New-Item -ItemType Directory -Force -Path (Join-Path $iupDir "include") | Out-Null
	foreach ($pkg in $Iup) {
		$zip = Get-Pinned $pkg.Url $pkg.File $pkg.Sha256
		$work = Join-Path $env:TEMP ("lunar-iup-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
		try {
			Expand-Archive -Path $zip -DestinationPath $work
			foreach ($lib in $pkg.Libs) { Copy-Item (Join-Path $work $lib) $iupDir -Force }
			$inc = Join-Path $work "include"
			if (Test-Path $inc) { Copy-Item (Join-Path $inc "*") (Join-Path $iupDir "include") -Force }
		} finally {
			Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
		}
	}
}

# --- OpenSSL -----------------------------------------------------------------------
$ssl = Join-Path $vendor "openssl"
if ($Force -or -not (Test-Path (Join-Path $ssl "lib\libcrypto.a")) -or -not (Test-Path (Join-Path $ssl "include\openssl\ssl.h"))) {
	Write-Step "OpenSSL (several minutes)"
	& (Join-Path $PSScriptRoot "build-openssl.ps1")
}

# --- LuaRocks tree -------------------------------------------------------------------
Write-Step "LuaRocks tree"
& (Join-Path $PSScriptRoot "fetch-deps.ps1") -Dev:$Dev   # throws on failure

Write-Host "`n[bootstrap] Done. Next: cmake --preset dev; cmake --build --preset dev" -ForegroundColor Green

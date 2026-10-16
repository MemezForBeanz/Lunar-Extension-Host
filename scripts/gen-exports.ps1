<#
.SYNOPSIS
    Regenerates src/LunarExtensionHost.def, the host executable's explicit export list.

.DESCRIPTION
    The host exports symbols for two runtime consumers:

      1. Loadable extension C modules (an extension's native/<name>.dll), which
         bind the statically-linked Lua C API at load time.
      2. LuaJIT FFI code in the app, which resolves symbols out of the running exe
         via ffi.C (VectorIcon.lua needs nsvg*, IupFFI.lua needs Iup*).

    We cannot enumerate these from the shipped Release binary because it is linked
    with -s (stripped). So this script configures a throwaway RelWithDebInfo tree,
    links an unstripped exe, and reads its symbol table with nm -- giving the exact
    set of globals actually present in the binary. Listing a name that is not
    defined is a hard link error, so the harvest must come from a real link.

    Run this after upgrading LuaJIT, IUP or NanoSVG, or after adding FFI cdefs that
    reference new host symbols. Then rebuild and smoke-test the GUI: a missing
    export shows up as "cannot resolve symbol '<name>'" at runtime, not at link time.

.PARAMETER Keep
    Keep the throwaway harvest build tree instead of deleting it.
#>
[CmdletBinding()]
param(
    [switch] $Keep
)

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$HarvestDir = Join-Path $RepoRoot 'build_exportharvest'
$DefPath    = Join-Path $RepoRoot 'src\LunarExtensionHost.def'
$MingwBin   = 'C:\msys64\mingw64\bin'

if (-not (Test-Path $MingwBin)) { throw "MSYS2 mingw64 toolchain not found at $MingwBin" }
$env:PATH = "$MingwBin;$env:PATH"

Write-Host "==> Linking an unstripped harvest binary (this takes a few minutes)" -ForegroundColor Cyan
# Native compiler warnings arrive on stderr, and with $ErrorActionPreference='Stop'
# PowerShell promotes those to terminating errors even when the command succeeds.
# Relax the preference around the native calls and gate on $LASTEXITCODE instead.
& {
    $ErrorActionPreference = 'Continue'

    & cmake -S $RepoRoot -B $HarvestDir -G 'MinGW Makefiles' `
            -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLUNAR_EXPORT_ALL_SYMBOLS=ON 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }

    & cmake --build $HarvestDir -j 4 --target LunarExtensionHost 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($LASTEXITCODE)" }
}

$exe = Join-Path $HarvestDir 'bin\LunarExtensionHost.exe'
if (-not (Test-Path $exe)) { throw "harvest binary not produced: $exe" }

Write-Host "==> Reading symbol table" -ForegroundColor Cyan
$defined = & nm --defined-only --extern-only $exe 2>$null |
    ForEach-Object { ($_ -split '\s+')[-1] }

if (-not $defined -or $defined.Count -eq 0) { throw "nm returned no symbols from $exe" }

$lua  = $defined | Where-Object { $_ -match '^(lua_|luaL_|luaopen_|luaJIT_)' } | Sort-Object -Unique
$nsvg = $defined | Where-Object { $_ -match '^nsvg' }                          | Sort-Object -Unique
$iup  = $defined | Where-Object { $_ -match '^Iup' }                           | Sort-Object -Unique

# Symbols known to be reached only through ffi.C. If one of these disappears the
# failure is a runtime "cannot resolve symbol", so fail loudly here instead.
$required = @(
    'nsvgParseFromFile', 'nsvgRasterize', 'nsvgDelete',
    'nsvgCreateRasterizer', 'nsvgDeleteRasterizer',
    'IupGetAttribute', 'IupSetAttribute', 'IupSetStrAttribute'
)
$all = $lua + $nsvg + $iup
$missing = $required | Where-Object { $all -notcontains $_ }
if ($missing) { throw "FFI-required symbols not found in the binary: $($missing -join ', ')" }

$header = @(
    ';; LunarExtensionHost.def -- explicit export list for the host executable.'
    ';;'
    ';; GENERATED FILE -- do not edit by hand. Regenerate with scripts/gen-exports.ps1.'
    ';;'
    ';; The host exports symbols for two runtime consumers:'
    ';;   1. Loadable extension C modules (an extension's native/<name>.dll), which'
    ';;      bind the statically-linked Lua C API at load time.'
    ';;   2. LuaJIT FFI code in the app itself, which resolves symbols out of the'
    ';;      running exe via ffi.C -- src/lua/core/ui/VectorIcon.lua needs nsvg*, and'
    ';;      src/lua/core/classes/IupFFI.lua needs Iup*.'
    ';;'
    ';; This replaces -Wl,--export-all-symbols, which exported all ~13,700 globals in'
    ';; the binary (OpenSSL, IUP, IM and LuaJIT internals) for 448 KB of .edata. It'
    ';; also made every symbol a --gc-sections root, so trimming the list is what'
    ';; lets dead code actually be collected.'
    ';;'
    ';; Exported names are also GC roots, so anything reachable only from FFI MUST be'
    ';; listed here or --gc-sections will delete it. A name listed here that is not'
    ';; defined is a hard link error, so this list cannot silently drift.'
    ''
    'EXPORTS'
    '    ;; --- Lua / LuaJIT C API (plugin C modules) ---'
) + ($lua | ForEach-Object { "    $_" }) + @(
    ''
    '    ;; --- NanoSVG (VectorIcon.lua via ffi.C) ---'
) + ($nsvg | ForEach-Object { "    $_" }) + @(
    ''
    '    ;; --- IUP public API (IupFFI.lua via ffi.C) ---'
) + ($iup | ForEach-Object { "    $_" })

Set-Content -LiteralPath $DefPath -Value $header -Encoding ASCII

Write-Host ""
Write-Host "Wrote $DefPath" -ForegroundColor Green
Write-Host ("  Lua/LuaJIT : {0}" -f $lua.Count)
Write-Host ("  NanoSVG    : {0}" -f $nsvg.Count)
Write-Host ("  IUP        : {0}" -f $iup.Count)
Write-Host ("  TOTAL      : {0} (of {1} globals in the binary)" -f $all.Count, $defined.Count)

if (-not $Keep) {
    Remove-Item -LiteralPath $HarvestDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "Kept harvest tree: $HarvestDir"
}

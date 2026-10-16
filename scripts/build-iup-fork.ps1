# scripts/build-iup-fork.ps1 - build the core IUP static library (libiup.a) from the
# vendored IUP source under vendor\iup-src\iup, using the MSYS2 mingw64 toolchain.
#
# This is the "fork build": it reproduces the Windows core-library configuration from
# IUP's own src/config.mak (common SRC + win driver + WDL new-draw layer, USE_NEW_DRAW),
# so the resulting archive is a drop-in replacement for vendor\iup\libiup.a. Our gradient
# and rounded-corner patches live entirely in these core sources, so only this archive
# needs rebuilding - the satellite archives (libiupcontrols, libiuplua51, ...) stay as the
# prebuilt 3.32 binaries.
#
# Output: vendor\iup-src\build\libiup.a (CMake links this via ${IUP_FORK_LIB}).
#
# The source tree itself is NOT committed (vendor\* is gitignored and regenerated).
# Instead the fork lives as tracked patch files under iup-fork\patches\*.patch, applied
# on top of a pristine upstream extract. This "prepare" step downloads (if needed) and
# extracts iup-3.32_Sources.tar.gz, then applies the patches, so a clean checkout can
# build the fork with no manual steps. A stamp file records the applied patch set so the
# prepare only re-runs when the patches (or the extracted tree) change.
#
# Usage:
#   scripts\build-iup-fork.ps1            # prepare-if-needed, then incremental build
#   scripts\build-iup-fork.ps1 -Clean     # wipe object cache and rebuild everything
#   scripts\build-iup-fork.ps1 -Fresh     # force re-extract + re-apply patches, full build

param(
    [switch]$Clean,
    [switch]$Fresh
)

$ErrorActionPreference = "Continue"
$repo = Split-Path -Parent $PSScriptRoot
$srcRoot = Join-Path $repo "vendor\iup-src\iup"
$src  = Join-Path $srcRoot "src"
$obj  = Join-Path $repo "vendor\iup-src\build\obj"
$outLib = Join-Path $repo "vendor\iup-src\build\libiup.a"

# --- prepare: pristine upstream + tracked patches ------------------------------------
$patchDir  = Join-Path $repo "iup-fork\patches"
$tarball   = Join-Path $repo "vendor\iup-src\downloads\iup-3.32_Sources.tar.gz"
$extractTo = Join-Path $repo "vendor\iup-src"
$stampFile = Join-Path $repo "vendor\iup-src\.patch-stamp"
$srcUrl    = "https://sourceforge.net/projects/iup/files/3.32/Docs%20and%20Sources/iup-3.32_Sources.tar.gz/download"

$patches = @(Get-ChildItem (Join-Path $patchDir "*.patch") -ErrorAction SilentlyContinue | Sort-Object Name)
if ($patches.Count -eq 0) { throw "No patches found in $patchDir - the fork patch series is missing." }

# stamp = combined hash of all patch files (so edits to any patch retrigger prepare)
$stampInput = ($patches | ForEach-Object { (Get-FileHash $_.FullName -Algorithm SHA256).Hash }) -join ';'
$curStamp   = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new([System.Text.Encoding]::UTF8.GetBytes($stampInput))) -Algorithm SHA256).Hash

$needPrepare = $Fresh -or (-not (Test-Path $src)) -or (-not (Test-Path $stampFile)) -or `
               ((Get-Content $stampFile -Raw -ErrorAction SilentlyContinue).Trim() -ne $curStamp)

if ($needPrepare) {
    Write-Host "Preparing IUP fork source (extract pristine + apply patches)..." -ForegroundColor Cyan
    if (-not (Test-Path $tarball)) {
        Write-Host "  Source tarball missing - downloading from SourceForge..." -ForegroundColor Yellow
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $tarball) | Out-Null
        & curl.exe --ssl-no-revoke -fSL $srcUrl -o $tarball
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $tarball)) { throw "Failed to download IUP sources from $srcUrl" }
    }
    if (Test-Path $srcRoot) { Remove-Item -Recurse -Force $srcRoot }
    New-Item -ItemType Directory -Force -Path $extractTo | Out-Null
    & tar.exe -xzf $tarball -C $extractTo
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $src)) { throw "Failed to extract $tarball" }

    # Apply from the repo root with --directory rather than `git -C $srcRoot apply`.
    # $srcRoot lives inside this repo and under a gitignored path (vendor\*); running
    # `git apply` with the CWD set to that subdir makes git treat the patch's `src/...`
    # paths as repo-root-relative and FILTER THEM OUT ("Skipped patch ...") while still
    # returning exit 0 - a silent no-op that leaves the tree pristine. Running from the
    # repo root and prepending the vendored subdir via --directory applies correctly.
    #
    # core.autocrlf=false is required, not cosmetic: with the usual Windows global
    # autocrlf=true, `git apply` writes every patched file back as CRLF while the rest
    # of the extracted tree stays LF. The compiler doesn't care, but scripts\
    # regen-iup-patch.ps1 then sees whole-file rewrites instead of real edits.
    $srcRel = "vendor/iup-src/iup"
    foreach ($p in $patches) {
        Write-Host "  applying $($p.Name)" -ForegroundColor DarkCyan
        $applyOut = & git -c core.autocrlf=false -C $repo apply -p1 --directory="$srcRel" --whitespace=nowarn --verbose $p.FullName 2>&1
        if ($LASTEXITCODE -ne 0) { $applyOut | ForEach-Object { Write-Host "    $_" }; throw "Patch failed to apply: $($p.Name)" }
        if ($applyOut -match 'Skipped patch') { $applyOut | ForEach-Object { Write-Host "    $_" }; throw "Patch silently skipped (no files changed): $($p.Name)" }
    }
    # Fail loudly if the patch produced no gradient code (guards against a silent no-op
    # leaving a stock tree that would compile into a feature-less "fork" libiup.a).
    $sentinel = Join-Path $src "iup_draw.c"
    if (-not (Test-Path $sentinel) -or -not (Select-String -Path $sentinel -Pattern 'iupFlatDrawGradient' -Quiet)) {
        throw "Patch verification failed: iupFlatDrawGradient not found in $sentinel after applying patches."
    }
    # Same guard for the native-text-scroll work, which lives in different files and was
    # once missing from the patch series entirely (the tree had it, the patches did not,
    # so a -Fresh build silently produced a libiup.a without NATIVETEXTSCROLL and the log
    # parser's themed scrollbar stopped driving the EDIT).
    $scrollSentinel = Join-Path $src "win\iupwin_text.c"
    if (-not (Test-Path $scrollSentinel) -or -not (Select-String -Path $scrollSentinel -Pattern 'FIRSTVISIBLELINE' -Quiet)) {
        throw "Patch verification failed: FIRSTVISIBLELINE not found in $scrollSentinel after applying patches."
    }
    Set-Content -Path $stampFile -Value $curStamp -NoNewline
    $Clean = $true   # sources changed - force a full rebuild
    Write-Host "  fork source ready (patched + verified)." -ForegroundColor Cyan
}

if (-not (Test-Path $src)) { throw "IUP source not found at $src after prepare." }

$gcc = "C:\msys64\mingw64\bin\gcc.exe"
$ar  = "C:\msys64\mingw64\bin\ar.exe"
if (-not (Test-Path $gcc)) { throw "MSYS2 mingw64 gcc not found at $gcc" }

if ($Clean -and (Test-Path $obj)) { Remove-Item -Recurse -Force $obj }
New-Item -ItemType Directory -Force -Path $obj | Out-Null

# --- source list (from vendor\iup-src\iup\src\config.mak, Windows + USE_NEW_DRAW) -------
$common = @(
  'iup_array','iup_callback','iup_dlglist','iup_attrib','iup_focus','iup_font',
  'iup_globalattrib','iup_object','iup_key','iup_layout','iup_ledlex','iup_names',
  'iup_ledparse','iup_predialogs','iup_register','iup_scanf','iup_show','iup_str',
  'iup_func','iup_childtree','iup','iup_classattrib','iup_dialog','iup_assert',
  'iup_messagedlg','iup_timer','iup_image','iup_label','iup_fill','iup_zbox',
  'iup_colordlg','iup_fontdlg','iup_filedlg','iup_strmessage','iup_menu','iup_frame',
  'iup_user','iup_button','iup_radio','iup_toggle','iup_progressbar','iup_text','iup_val',
  'iup_box','iup_hbox','iup_vbox','iup_cbox','iup_class','iup_classbase','iup_maskmatch',
  'iup_mask','iup_maskparse','iup_tabs','iup_spin','iup_list','iup_getparam','iup_link',
  'iup_sbox','iup_scrollbox','iup_normalizer','iup_tree','iup_split','iup_layoutdlg',
  'iup_recplay','iup_progressdlg','iup_expander','iup_open','iup_table','iup_canvas',
  'iup_gridbox','iup_detachbox','iup_backgroundbox','iup_linefile','iup_config',
  'iup_flatbutton','iup_animatedlabel','iup_draw','iup_flatframe','iup_flattabs',
  'iup_flatscrollbar','iup_flatscrollbox','iup_gauge','iup_dial','iup_colorbar',
  'iup_colorbrowser','iup_colorhsi','iup_flatlabel','iup_dropbutton','iup_flattoggle',
  'iup_flatseparator','iup_space','iup_multibox','iup_flatlist','iup_globalsdlg',
  'iup_flatval','iup_loop','iup_thread','iup_classinfo','iup_elempropdlg',
  'iup_export','iup_flattree'
)
$win = @(
  'win/iupwin_common','win/iupwin_brush','win/iupwin_focus','win/iupwin_font',
  'win/iupwin_globalattrib','win/iupwin_handle','win/iupwin_key','win/iupwin_str',
  'win/iupwin_loop','win/iupwin_open','win/iupwin_tips','win/iupwin_info',
  'win/iupwin_dialog','win/iupwin_messagedlg','win/iupwin_timer',
  'win/iupwin_image','win/iupwin_label','win/iupwin_canvas','win/iupwin_frame',
  'win/iupwin_fontdlg','win/iupwin_filedlg','win/iupwin_dragdrop',
  'win/iupwin_button','win/iupwin_draw','win/iupwin_toggle','win/iupwin_clipboard',
  'win/iupwin_progressbar','win/iupwin_text','win/iupwin_val','win/iupwin_touch',
  'win/iupwin_tabs','win/iupwin_menu','win/iupwin_list','win/iupwin_tree',
  'win/iupwin_calendar','win/iupwin_datepick'
)
$newdraw = @('win/iupwin_draw_wdl','win/iupwin_draw_gdi','win/iupwin_image_wdl')
$wdl = @(
  'win/wdl/backend-d2d','win/wdl/backend-dwrite','win/wdl/backend-gdix','win/wdl/backend-wic',
  'win/wdl/bitblt','win/wdl/brush','win/wdl/cachedimage','win/wdl/canvas','win/wdl/draw',
  'win/wdl/fill','win/wdl/font','win/wdl/image','win/wdl/init','win/wdl/memstream',
  'win/wdl/misc','win/wdl/path','win/wdl/string','win/wdl/strokestyle'
)
$winmain = @('win/iupwindows_main','win/iupwindows_help','win/iupwindows_info')

$sources = $common + $win + $newdraw + $wdl + $winmain

$defines = @(
  '-D_WIN32_WINNT=0x0601','-D_WIN32_IE=0x0900','-DWINVER=0x0601',
  '-DNOTREEVIEW','-DUNICODE','-D_UNICODE','-DCOBJMACROS','-DUSE_NEW_DRAW'
)
$includes = @("-I$src\..\include", "-I$src", "-I$src\win", "-I$src\win\wdl")
$cflags = @('-O2','-w',
  '-Wno-error=incompatible-pointer-types','-Wno-error=int-conversion',
  '-Wno-error=implicit-function-declaration','-Wno-error=implicit-int',
  '-Wno-error=discarded-qualifiers'
) + $defines + $includes

# --- compile ---------------------------------------------------------------------------
$objFiles = New-Object System.Collections.Generic.List[string]
$missing  = New-Object System.Collections.Generic.List[string]
$failed   = New-Object System.Collections.Generic.List[string]
$compiled = 0
$skipped  = 0

foreach ($s in $sources) {
    $cpath = Join-Path $src ($s + '.c')
    if (-not (Test-Path $cpath)) { $missing.Add($s + '.c'); continue }
    $oname = ($s -replace '[\\/]', '__') + '.o'
    $opath = Join-Path $obj $oname
    $objFiles.Add($opath)

    if ((-not $Clean) -and (Test-Path $opath) -and ((Get-Item $opath).LastWriteTime -ge (Get-Item $cpath).LastWriteTime)) {
        $skipped++; continue
    }
    $errFile = Join-Path $obj "$oname.err"
    & $gcc @cflags -c $cpath -o $opath 2>$errFile
    if ($LASTEXITCODE -ne 0) {
        $failed.Add($s + '.c')
        Write-Host "FAIL $s.c" -ForegroundColor Red
        Get-Content $errFile | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
    } else {
        $compiled++
        Remove-Item $errFile -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "Compiled: $compiled  Skipped(up-to-date): $skipped  Missing: $($missing.Count)  Failed: $($failed.Count)"
if ($missing.Count -gt 0) { Write-Host "MISSING FILES:" -ForegroundColor Yellow; $missing | ForEach-Object { Write-Host "  $_" } }
if ($failed.Count  -gt 0) { throw "$($failed.Count) source file(s) failed to compile." }

# --- archive ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outLib) | Out-Null
if (($compiled -eq 0) -and (Test-Path $outLib)) {
    Write-Host "libiup.a up-to-date (no objects recompiled) - skipping archive." -ForegroundColor DarkGray
    return
}
if (Test-Path $outLib) { Remove-Item $outLib }
& $ar rcs $outLib @($objFiles)
if ($LASTEXITCODE -ne 0) { throw "ar failed to create $outLib" }

Write-Host "`nBuilt $outLib ($([math]::Round((Get-Item $outLib).Length/1MB,2)) MB) from $($objFiles.Count) objects." -ForegroundColor Green

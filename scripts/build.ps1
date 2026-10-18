#Requires -Version 5.1
<#
.SYNOPSIS
    Build, package, and publish Lunar Extension Host.

.DESCRIPTION
    Single entry point for producing and publishing distributable artifacts.

    Build modes (-Mode):
        portable   Self-contained folder (exe + plugins\) + a .zip. No install.
        installer  A real Windows Installer package (.msi) built with the WiX Toolset,
                   plus Lunar-Setup-<ver>.exe: the graphical installer people download.
                   The app is the required "core" feature; every extension is its own
                   optional feature (MSI feature Ft_ext_<id>). The setup .exe is an
                   IExpress self-extractor carrying Lunar.exe, the installer script and
                   the MSI; its wizard (the same pages as on Linux) runs msiexec with
                   ADDLOCAL for the extensions the user ticked. IT can still deploy the
                   .msi directly (msiexec /i ... /qn). Uninstall is handled natively
                   through Add/Remove Programs.
        all        Both of the above (default).

    Hosting model (GitHub-primary, share mirror):
        * GitHub Releases are the canonical, versioned store. One release per version
          (tag v<semver>) holds Lunar-Setup-<ver>.exe, LunarExtensionHost-<ver>.msi, the portable zip, and a small
          release.json describing the contents.
        * The SMB share is an auto-populated, zero-auth mirror under releases\<ver>\
          plus a manifest.json and a stable LunarExtensionHost-Setup.msi at the share root
          (always the latest version), so end users install with no credential friction
          and no execution-policy hassles (an .msi is not a script).

    Publishing (-Publish / -PublishGitHub / -PublishShare):
        -PublishGitHub  Create/refresh the GitHub release v<ver> and upload assets (gh).
        -PublishShare   Mirror the versioned payload into <HostRoot>\releases\<ver>\,
                        rebuild manifest.json, and refresh the root LunarExtensionHost-Setup.msi.
        -Publish        Both of the above.

    Old versions are preserved: share mirroring only ever writes inside
    releases\<ver>\ (plus the root pointer files), and manifest.json is rebuilt from
    whatever versions are present.

    The WiX Toolset (candle/light/heat) is fetched and cached automatically under
    build\tools\ on first use; no separate install step is required.

.PARAMETER Mode
    portable | installer | all   (default: all)

.PARAMETER Version
    Optional consistency check for the internal app version. Build/publish version is
    always read from src\lua\core\main.lua (APP_VERSION). If -Version is provided and
    does not match APP_VERSION, the script errors.

.PARAMETER HostRoot
    Root of the SMB hosting share. Required with -Publish or -PublishShare; like
    -Repo it has no default, so a build can't publish to the wrong place.

.PARAMETER Repo
    GitHub repository in owner/name form for releases. Required with -Publish or
    -PublishGitHub: there is deliberately no default, so a build can't publish to the
    wrong place.

.PARAMETER Publish
    Publish to BOTH GitHub and the share.

.PARAMETER PublishGitHub
    Publish only to GitHub Releases (requires an authenticated `gh`).

.PARAMETER PublishShare
    Publish only to the SMB share.

.PARAMETER SkipBuild
    Reuse the existing build\bin output instead of invoking cmake.

.PARAMETER Clean
    Delete the dist\ output directory before building.

.PARAMETER ReleaseNotes
    Explicit GitHub release notes text. If omitted during GitHub publishing, the
    script opens a text editor so notes can be written/reviewed before release.

.PARAMETER ReleaseNotesFile
    Path to a text file used as GitHub release notes. If the file contains
    versioned sections (for example: `Version **1.5.1**`), the script extracts
    only the section matching the build version.

.EXAMPLE
    .\scripts\build.ps1 -Mode all -Version 1.0.0 -Publish

.EXAMPLE
    .\scripts\build.ps1 -Mode portable
#>
[CmdletBinding()]
param(
    [ValidateSet('portable', 'installer', 'all')]
    [string] $Mode = 'all',

    [string] $Version,

    [string] $HostRoot,

    [string] $Repo,

    [string] $MingwBin = 'C:\msys64\mingw64\bin',

    [string] $WixUrl = 'https://github.com/wixtoolset/wix3/releases/download/wix3112rtm/wix311-binaries.zip',

    [switch] $Publish,
    [switch] $PublishGitHub,
    [switch] $PublishShare,
    [string] $ReleaseNotes,
    [string] $ReleaseNotesFile,
    [switch] $SkipBuild,
    [switch] $Clean
)

$ErrorActionPreference = 'Stop'
# Set this GLOBALLY: module cmdlets such as Compress-Archive resolve $ProgressPreference
# from the global scope, not the caller's script scope, so a script-scoped assignment
# would not suppress their progress bars.
$global:ProgressPreference = 'SilentlyContinue'
$ProgressPreference        = 'SilentlyContinue'

# --- Paths ----------------------------------------------------------------------
$RepoRoot   = Split-Path -Parent $PSScriptRoot
$BuildDir   = Join-Path $RepoRoot 'build'
# Same folder and settings as the CMake 'release' preset, so a VS Code release build
# and a packaged build are one configuration.
$CompileDir = Join-Path $BuildDir 'rel'
$BinDir     = Join-Path $CompileDir 'bin'
$WorkspaceRoot = Split-Path -Parent $RepoRoot
$ToolsDir   = Join-Path $BuildDir 'tools'
$DistDir    = Join-Path $RepoRoot 'dist'
$AssetsDir  = Join-Path $DistDir 'release-assets'
$AppName    = 'Lunar Extension Host'
$Manufacturer = 'Lunar Extension Host contributors'
$ExeName    = 'Lunar.exe'
# STABLE across versions - do not change. Lunar has its own product identity,
# separate from any org's branded installer, so the two never replace each other.
$UpgradeCode = '5C145DA3-FBAC-420D-B9F0-EE19AFEA76EA'
# STABLE too: the component that creates the admin-only ProgramData folder. A
# component with no key file needs a fixed GUID.
$MachineDataGuid = '7E0C2B9A-4D31-4F6E-9B8A-2C5D1E3F4A60'
$WixDir     = Join-Path $ToolsDir 'wix311'
$LicenseRtf = Join-Path $PSScriptRoot 'installer\wix\License.rtf'

function Write-Step($m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Info($m) { Write-Host "    $m" -ForegroundColor Gray }

function Get-ReleaseAssetsForVersion($ver) {
    $msi = Join-Path $AssetsDir "LunarExtensionHost-$ver.msi"
    if (-not (Test-Path -LiteralPath $msi)) {
        throw "Required release asset missing: $msi. Run -Mode installer or all first."
    }

    $releaseJson = Join-Path $AssetsDir 'release.json'
    if (-not (Test-Path -LiteralPath $releaseJson)) {
        throw "Required release asset missing: $releaseJson. Run -Mode installer or all first."
    }

    $assets = @($msi, $releaseJson)
    $setup = Join-Path $AssetsDir "Lunar-Setup-$ver.exe"
    if (Test-Path -LiteralPath $setup) {
        $assets += $setup
    }
    $portable = Join-Path $AssetsDir "Lunar-portable-$ver.zip"
    if (Test-Path -LiteralPath $portable) {
        $assets += $portable
    }

    return $assets
}

function Get-ReleaseNotesForVersion($text, $ver, $sourcePath) {
    $lines = $text -split "`r?`n"
    $sectionStarts = New-Object System.Collections.ArrayList

    $versionHeaderPatterns = @(
        '^\s*(?:#+\s*)?Version\s+\*\*(?<version>[^*]+)\*\*(?:\s*[-:].*)?$',
        '^\s*##+\s*v?(?<version>\d+\.\d+\.\d+(?:[-+][0-9A-Za-z\.-]+)?)\b.*$'
    )

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        foreach ($pattern in $versionHeaderPatterns) {
            $m = [regex]::Match($line, $pattern)
            if ($m.Success) {
                [void]$sectionStarts.Add([pscustomobject]@{
                    StartLine = $i
                    Version   = $m.Groups['version'].Value.Trim().TrimStart('v', 'V')
                })
                break
            }
        }
    }

    if ($sectionStarts.Count -eq 0) {
        return $text.TrimEnd()
    }

    $normalizedTarget = $ver.Trim().TrimStart('v', 'V')
    $targetIndex = -1

    for ($i = 0; $i -lt $sectionStarts.Count; $i++) {
        if ($sectionStarts[$i].Version -eq $normalizedTarget) {
            $targetIndex = $i
            break
        }
    }

    if ($targetIndex -lt 0) {
        throw "Release notes file '$sourcePath' has versioned sections but no section matching version '$ver'."
    }

    $startLine = [int]$sectionStarts[$targetIndex].StartLine
    $endLine = $lines.Length - 1
    if ($targetIndex -lt ($sectionStarts.Count - 1)) {
        $endLine = [int]$sectionStarts[$targetIndex + 1].StartLine - 1
    }

    $selected = ($lines[$startLine..$endLine] -join "`r`n").Trim()
    if (-not $selected) {
        throw "Release notes section for version '$ver' in '$sourcePath' is empty."
    }

    return $selected
}

function Resolve-ReleaseNotes($ver) {
    if ($ReleaseNotes -and $ReleaseNotes.Trim() -ne '') {
        return $ReleaseNotes.TrimEnd()
    }

    if ($ReleaseNotesFile) {
        if (-not (Test-Path -LiteralPath $ReleaseNotesFile)) {
            throw "Release notes file not found: $ReleaseNotesFile"
        }
        $text = Get-Content -LiteralPath $ReleaseNotesFile -Raw
        if (-not $text -or $text.Trim() -eq '') {
            throw "Release notes file is empty: $ReleaseNotesFile"
        }
        return Get-ReleaseNotesForVersion -text $text -ver $ver -sourcePath $ReleaseNotesFile
    }

    $isHeadless = ($env:CI -eq 'true') -or (-not [Environment]::UserInteractive)
    if ($isHeadless) {
        return "Release of Lunar Extension Host $ver."
    }

    # Best local UX: open VS Code (wait for close) for multiline notes authoring.
    # Fall back to Notepad if VS Code CLI is unavailable.
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("lunar-release-notes-{0}-{1}.md" -f $ver, [Guid]::NewGuid().ToString("N"))
    @(
        "# Lunar Extension Host $ver"
        ""
        "## Highlights"
        "- "
        ""
        "## Notes"
        "- "
    ) | Set-Content -LiteralPath $tmp -Encoding UTF8

    try {
        $code = Get-Command code -ErrorAction SilentlyContinue
        if ($code) {
            & $code.Source '--wait' $tmp | Out-Null
        } else {
            Write-Info "VS Code CLI not found; opening Notepad for release notes."
            Start-Process -FilePath "notepad.exe" -ArgumentList $tmp -Wait
        }

        $notes = Get-Content -LiteralPath $tmp -Raw
        if (-not $notes -or $notes.Trim() -eq '') {
            throw "Release notes were left empty. Provide notes and run again."
        }
        return $notes.TrimEnd()
    }
    finally {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force
        }
    }
}

function Get-InternalAppVersion {
    $mainLua = Join-Path $RepoRoot 'src\lua\core\main.lua'
    if (-not (Test-Path -LiteralPath $mainLua)) {
        throw "Unable to resolve internal version: missing $mainLua"
    }

    $content = Get-Content -LiteralPath $mainLua -Raw
    $m = [regex]::Match($content, 'local\s+APP_VERSION\s*=\s*"([^"]+)"')
    if (-not $m.Success) {
        throw "Unable to resolve APP_VERSION from $mainLua"
    }

    $internal = $m.Groups[1].Value.Trim()
    $v = $null
    if (-not [version]::TryParse($internal, [ref]$v)) {
        throw "APP_VERSION '$internal' in $mainLua is not a valid semantic version."
    }
    return $internal
}

# Resolve package/release version EXCLUSIVELY from internal APP_VERSION.
function Resolve-Version {
    $internal = Get-InternalAppVersion
    if ($Version -and $Version -ne $internal) {
        throw "Provided -Version '$Version' does not match APP_VERSION '$internal' in src\\lua\\core\\main.lua."
    }
    return $internal
}

# Ensure the WiX 3 toolset (candle/light/heat) is available, downloading + caching it
# under build\tools\wix311 on first use. Uses the system web proxy with default
# credentials so it works on the corporate network.
function Ensure-WixToolset {
    $candle = Join-Path $WixDir 'candle.exe'
    if (Test-Path $candle) { return $WixDir }

    Write-Step "Fetching WiX Toolset (one-time): $WixUrl"
    if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }
    $zip = Join-Path $ToolsDir 'wix311-binaries.zip'
    if (-not (Test-Path $zip)) {
        $wc = New-Object System.Net.WebClient
        try {
            $wc.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
            $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        } catch { }
        $wc.DownloadFile($WixUrl, $zip)
    }
    if (Test-Path $WixDir) { Remove-Item $WixDir -Recurse -Force }
    New-Item -ItemType Directory -Path $WixDir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $WixDir)
    if (-not (Test-Path $candle)) { throw "WiX toolset did not extract correctly to $WixDir" }
    Write-Info "WiX cached at $WixDir"
    return $WixDir
}

# Turn an arbitrary string into a safe WiX identifier (letters, digits, underscore).
function Get-WixId($s) {
    $id = ($s -replace '[^A-Za-z0-9_]', '_')
    if ($id -notmatch '^[A-Za-z_]') { $id = "_$id" }
    return $id
}

# Escape a string for use in an XML attribute value.
function ConvertTo-XmlAttr($s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
}

# MSI ProductVersion must be purely numeric (x.x.x[.x]); strip any pre-release suffix.
function Get-MsiVersion($ver) {
    $core = ($ver -split '[-+]')[0]
    $v = $null
    if (-not [version]::TryParse($core, [ref]$v)) { throw "Version '$ver' is not a valid numeric MSI version." }
    return $core
}

# --- 1. Compile -----------------------------------------------------------------
function Invoke-Build {
    if ($SkipBuild) {
        Write-Step "Skipping compile (-SkipBuild); using existing build\rel\bin"
        return
    }
    Write-Step "Configuring + building (cmake / MinGW Makefiles)"
    # Windows PowerShell turns a native tool's stderr (compiler warnings) into a
    # terminating error under "Stop"; exit codes are checked below instead.
    # (Function scope: the rest of the script keeps "Stop".)
    $ErrorActionPreference = 'Continue'
    $env:PATH = "$MingwBin;$env:PATH"
    if (-not (Test-Path $CompileDir)) { New-Item -ItemType Directory -Path $CompileDir -Force | Out-Null }

    # LUNAR_DEV_BUILD=OFF: a shipped build loads code only from its own folder and
    # trusted org packs (see main.lua).
    & cmake -S $RepoRoot -B $CompileDir -G 'MinGW Makefiles' -DCMAKE_BUILD_TYPE=Release -DLUNAR_DEV_BUILD=OFF -DCMAKE_EXPORT_COMPILE_COMMANDS=ON | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed ($LASTEXITCODE)" }

    & cmake --build $CompileDir -j 8 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed ($LASTEXITCODE)" }
}

# --- Helpers --------------------------------------------------------------------

# Copy the application files into $dest.
#
# This is an allowlist, deliberately. build\bin is a development tree that also
# accumulates run-time droppings (debug logs, _pid.txt, recent_repos.json, ad-hoc
# _test_*.lua repro scripts) and the CLI harness; a denylist let all of those ship
# in the portable zip and the MSI. Anything genuinely new that needs shipping has
# to be added here explicitly.
function Copy-AppFiles($dest) {
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $include = @('Lunar.exe', 'assets', 'certs')
    foreach ($name in $include) {
        $src = Join-Path $BinDir $name
        if (-not (Test-Path -LiteralPath $src)) {
            throw "Expected payload item not found in build output: $src"
        }
        Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force
    }
}

# Non-runtime files that live in plugins/ for development but must not ship:
# C sources for native modules (the built .dll ships instead), C# sources behind
# bundled helper executables, and plugin-authoring notes.
$script:PluginExcludePatterns = @('*.c', '*.h', '*.cs', 'README.md')

# Copy build\bin\plugins into $dest, minus the development-only files above.
# Both the portable layout and the MSI harvest go through here so the two
# payloads cannot drift apart.
function Copy-PluginFiles($dest) {
    $src = Join-Path $BinDir 'plugins'
    if (-not (Test-Path -LiteralPath $src)) { throw "plugins not found in build output: $src" }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    Copy-Item -LiteralPath $src -Destination $dest -Recurse -Force

    Get-ChildItem -LiteralPath $dest -Recurse -File |
        Where-Object {
            $item = $_
            @($script:PluginExcludePatterns | Where-Object { $item.Name -like $_ }).Count -gt 0
        } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }

    # A plugin whose only files were dev files would leave an empty dir behind and
    # confuse the MSI feature harvest, so prune those too.
    Get-ChildItem -LiteralPath $dest -Recurse -Directory |
        Sort-Object { $_.FullName.Length } -Descending |
        Where-Object { @(Get-ChildItem -LiteralPath $_.FullName -Force).Count -eq 0 } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
}

# An extension's id the way the host derives one (ExtensionManifest.defaultId).
function Get-DefaultExtensionId($s) {
    $v = ([string]$s).ToLowerInvariant()
    $v = [regex]::Replace($v, '[^a-z0-9._-]+', '-')
    $v = [regex]::Replace($v, '-+', '-').Trim('-')
    if ($v -eq '') { $v = 'extension' }
    if ($v -notmatch '^[a-z0-9]') { $v = "ext-$v" }
    return $v
}

# Read an extension's manifest.json (folder extension) or <name>.manifest.json (single
# file) - the same files the host reads at startup and the Linux installer scans - for
# its id, display name, version and description. Falls back to the initialize(...)
# call in the source, then to the file name.
function Get-ExtensionInfo($item, $ver) {
    $name = $item.BaseName
    $version = ''
    $description = ''
    $extId = Get-DefaultExtensionId $item.BaseName
    $manifestPath = $null
    if ($item.PSIsContainer) {
        $entry = 'init.lua'
        $manifestPath = Join-Path $item.FullName 'manifest.json'
        $init = Join-Path $item.FullName 'init.lua'
        if (Test-Path $init) {
            $txt = Get-Content -LiteralPath $init -Raw
            $m = [regex]::Match($txt, 'initialize\s*\(\s*self\s*,\s*"([^"]+)"\s*,\s*"([^"]+)"')
            if ($m.Success) { $name = $m.Groups[1].Value; $version = $m.Groups[2].Value }
        }
        $type = 'folder'
    } else {
        $entry = $item.Name
        $manifestPath = Join-Path $item.DirectoryName ($item.BaseName + '.manifest.json')
        $type = 'file'
    }
    if ($manifestPath -and (Test-Path -LiteralPath $manifestPath)) {
        try {
            $mf = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ($mf.id)          { $extId = [string]$mf.id }
            if ($mf.name)        { $name = [string]$mf.name }
            if ($mf.version)     { $version = [string]$mf.version }
            if ($mf.description) { $description = [string]$mf.description }
        } catch {
            Write-Info "Ignoring unreadable manifest $manifestPath ($($_.Exception.Message))"
        }
    }
    [pscustomobject]@{
        id          = (Get-WixId $item.BaseName)                    # safe WiX identifier (feature Ft_ext_<id>)
        extId       = $extId                                        # the extension's own id (manifest)
        name        = $name                                         # display name (feature title)
        source      = $item.Name                                    # how it appears under plugins\
        type        = $type
        entry       = $entry
        version     = $version
        description = $description
    }
}

# What lives under plugins\ that the MSI turns into features: every folder and file,
# except a <name>.manifest.json that belongs to <name>.lua (it ships with that
# extension's component rather than being an extension of its own).
function Get-ExtensionItems($pluginsDir) {
    $items = @(Get-ChildItem -LiteralPath $pluginsDir -Force)
    $luaStems = @{}
    foreach ($i in $items) {
        if (-not $i.PSIsContainer -and $i.Extension -eq '.lua') { $luaStems[$i.BaseName] = $true }
    }
    foreach ($i in $items) {
        if (-not $i.PSIsContainer -and $i.Name -like '*.manifest.json') {
            $stem = $i.Name.Substring(0, $i.Name.Length - '.manifest.json'.Length)
            if ($luaStems.ContainsKey($stem)) { continue }
        }
        $i
    }
}

# --- 2. Portable ----------------------------------------------------------------
function New-Portable($ver) {
    Write-Step "Packaging PORTABLE build"
    $stageRoot = Join-Path $DistDir 'portable'
    $folder    = "LunarExtensionHost-$ver"
    $stage     = Join-Path $stageRoot $folder
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }

    Copy-AppFiles $stage
    Copy-PluginFiles (Join-Path $stage 'plugins')

    $zip = Join-Path $AssetsDir "Lunar-portable-$ver.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path $stage -DestinationPath $zip -CompressionLevel Optimal

    Write-Info "Folder: $stage"
    Write-Info "Zip:    $zip"
}

# --- 3. Installer (real MSI via WiX) --------------------------------------------
# Builds release-assets\LunarExtensionHost-<ver>.msi plus a release.json manifest.
#
# Layout of the installed product (Program Files\Lunar Extension Host\):
#   Lunar.exe                     -> the required "core" feature
#   plugins\<extension>\ or plugins\<x>.lua -> one optional feature per extension
#
# Each extension is its own MSI Feature, so the standard feature-selection screen
# lets users tick exactly which extensions to install. Uninstall is native.
function New-Msi($ver) {
    Write-Step "Building MSI installer (v$ver)"
    $wix = Ensure-WixToolset
    $ErrorActionPreference = 'Continue'   # as in the compile step: exit codes are checked
    $msiVer = Get-MsiVersion $ver

    $stage   = Join-Path $DistDir 'msi'
    $appSrc  = Join-Path $stage 'app'
    $wxsDir  = Join-Path $stage 'wxs'
    $objDir  = Join-Path $stage 'obj'
    foreach ($d in @($appSrc, $wxsDir, $objDir)) {
        if (Test-Path $d) { Remove-Item $d -Recurse -Force }
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }

    # Stage the application (exe + lua\); plugins are added per-feature below.
    Copy-AppFiles $appSrc

    # Harvest plugins from a cleaned staging copy rather than straight out of
    # build\bin, so the MSI gets the same filtered payload as the portable zip.
    $srcPlugins = Join-Path $stage 'plugins'
    Copy-PluginFiles $srcPlugins

    # Discover extensions and harvest each into its own component group.
    $exts = @()
    Get-ExtensionItems $srcPlugins | ForEach-Object {
        $exts += (Get-ExtensionInfo $_ $ver)
    }
    $script:MsiExtensions = $exts

    # candle preprocessor variables (source roots) + the .wxs files to compile.
    $candleVars = @("-dAppSrc=$appSrc", "-dPluginsSrc=$srcPlugins", "-dLicenseRtf=$LicenseRtf")
    $wxsFiles   = @()

    # Harvest the app payload.
    $appWxs = Join-Path $wxsDir 'AppFiles.wxs'
    & "$wix\heat.exe" dir $appSrc -cg Cg_App -dr INSTALLFOLDER -srd -scom -sreg -ag -g1 `
        -var var.AppSrc -nologo -out $appWxs | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "heat (app) failed ($LASTEXITCODE)" }
    $wxsFiles += $appWxs

    # Build the dynamic pieces of Product.wxs: per-extension directories, file
    # components (for single-file extensions), and features.
    $pluginDirs = ''   # <Directory> entries nested under PLUGINSFOLDER (folder extensions)
    $fileComps  = ''   # <Component> entries for single-file extensions
    $extFeatures = ''  # <Feature> entries (children of the core feature)

    foreach ($e in $exts) {
        $title = ConvertTo-XmlAttr $e.name
        if ($e.type -eq 'folder') {
            $dirRef = "Dir_ext_$($e.id)"
            $cg     = "Cg_ext_$($e.id)"
            $extWxs = Join-Path $wxsDir "Ext_$($e.id).wxs"
            $srcDir = Join-Path $srcPlugins $e.source
            & "$wix\heat.exe" dir $srcDir -cg $cg -dr $dirRef -srd -scom -sreg -ag -g1 `
                -var "var.Ext_$($e.id)" -nologo -out $extWxs | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "heat (extension '$($e.source)') failed ($LASTEXITCODE)" }
            $wxsFiles   += $extWxs
            $candleVars += "-dExt_$($e.id)=$srcDir"
            $pluginDirs += "            <Directory Id=`"$dirRef`" Name=`"$(ConvertTo-XmlAttr $e.source)`" />`r`n"
            $extFeatures += @"
      <Feature Id="Ft_ext_$($e.id)" Title="$title" Level="1" Description="$title extension.">
        <ComponentGroupRef Id="$cg" />
      </Feature>

"@
        }
        else {
            # Single-file extension: a component placed directly under plugins\, plus a
            # second one for its <name>.manifest.json when there is one (an
            # auto-GUID component can hold only one file).
            $cmp = "Cmp_ext_$($e.id)"
            $companionName = [System.IO.Path]::GetFileNameWithoutExtension($e.source) + '.manifest.json'
            $companionComp = ''
            $companionRef = ''
            if (Test-Path -LiteralPath (Join-Path $srcPlugins $companionName)) {
                $companionComp = @"
      <Component Id="${cmp}_manifest" Guid="*">
        <File Id="File_ext_$($e.id)_manifest" Source="`$(var.PluginsSrc)\$(ConvertTo-XmlAttr $companionName)" KeyPath="yes" />
      </Component>

"@
                $companionRef = "        <ComponentRef Id=`"${cmp}_manifest`" />`r`n"
            }
            $fileComps += @"
      <Component Id="$cmp" Guid="*">
        <File Id="File_ext_$($e.id)" Source="`$(var.PluginsSrc)\$(ConvertTo-XmlAttr $e.source)" KeyPath="yes" />
      </Component>

$companionComp
"@
            $extFeatures += @"
      <Feature Id="Ft_ext_$($e.id)" Title="$title" Level="1" Description="$title extension.">
        <ComponentRef Id="$cmp" />
$companionRef      </Feature>

"@
        }
    }

    # Assemble the main authoring file.
    $product = @"
<?xml version="1.0" encoding="utf-8"?>
<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">
  <Product Id="*"
           Name="$AppName"
           Language="1033"
           Version="$msiVer"
           Manufacturer="$Manufacturer"
           UpgradeCode="$UpgradeCode">

    <Package InstallerVersion="500"
             Compressed="yes"
             InstallScope="perMachine"
             Platform="x64"
             Description="$AppName Installer"
             Comments="A desktop host for tool extensions" />

    <MajorUpgrade DowngradeErrorMessage="A newer version of [ProductName] is already installed." />
    <MediaTemplate EmbedCab="yes" />

    <Icon Id="AppIcon.exe" SourceFile="`$(var.AppSrc)\$ExeName" />
    <Property Id="ARPPRODUCTICON" Value="AppIcon.exe" />
    <Property Id="WIXUI_INSTALLDIR" Value="INSTALLFOLDER" />

    <Directory Id="TARGETDIR" Name="SourceDir">
      <Directory Id="ProgramFiles64Folder">
        <Directory Id="INSTALLFOLDER" Name="$AppName">
          <Directory Id="PLUGINSFOLDER" Name="plugins">
$pluginDirs          </Directory>
        </Directory>
      </Directory>
      <Directory Id="ProgramMenuFolder">
        <Directory Id="ApplicationProgramsFolder" Name="$AppName" />
      </Directory>
      <Directory Id="CommonAppDataFolder">
        <Directory Id="MACHINEDATAFOLDER" Name="$AppName" />
      </Directory>
    </Directory>

    <!-- %ProgramData%\Lunar Extension Host holds the org policy and trusted packs.
         ProgramData lets any user create folders, so a folder made later by
         whoever comes first could be planted; Lunar trusts it only when it is
         admin-only (core.platform admin_only). Create it here with the same
         exact, protected DACL as install-pack.ps1 -Harden: Administrators and
         SYSTEM full control, Users read. MsiLockPermissionsEx (Windows
         Installer 5) replaces the whole descriptor, inheritance included. -->
    <DirectoryRef Id="MACHINEDATAFOLDER">
      <Component Id="Cmp_MachineData" Guid="$MachineDataGuid">
        <CreateFolder>
          <PermissionEx Sddl="O:BAG:SYD:PAI(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)" />
        </CreateFolder>
      </Component>
    </DirectoryRef>

    <DirectoryRef Id="ApplicationProgramsFolder">
      <Component Id="Cmp_Shortcut" Guid="*">
        <Shortcut Id="StartMenuShortcut"
                  Name="$AppName"
                  Target="[INSTALLFOLDER]$ExeName"
                  WorkingDirectory="INSTALLFOLDER" />
        <RemoveFolder Id="RemoveApplicationProgramsFolder" On="uninstall" />
        <RegistryValue Root="HKCU"
                       Key="Software\$Manufacturer\$AppName"
                       Name="installed" Type="integer" Value="1" KeyPath="yes" />
      </Component>
    </DirectoryRef>

    <DirectoryRef Id="PLUGINSFOLDER">
$fileComps    </DirectoryRef>

    <Feature Id="Ft_Core" Title="$AppName" Level="1" Absent="disallow"
             Description="The $AppName application (required)." Display="expand"
             ConfigurableDirectory="INSTALLFOLDER">
      <ComponentGroupRef Id="Cg_App" />
      <ComponentRef Id="Cmp_Shortcut" />
      <ComponentRef Id="Cmp_MachineData" />

$extFeatures    </Feature>

    <UIRef Id="WixUI_FeatureTree" />
    <WixVariable Id="WixUILicenseRtf" Value="`$(var.LicenseRtf)" />
  </Product>
</Wix>
"@
    $productWxs = Join-Path $wxsDir 'Product.wxs'
    Set-Content -LiteralPath $productWxs -Value $product -Encoding ASCII
    $wxsFiles += $productWxs

    # Compile + link.
    $candleArgs = @('-nologo', '-arch', 'x64') + $candleVars + @('-ext', 'WixUIExtension', "-out", "$objDir\\") + $wxsFiles
    # (The doubled backslash: a path with spaces gets quoted, and a single trailing
    # backslash would escape the closing quote.)
    & "$wix\candle.exe" @candleArgs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "candle failed ($LASTEXITCODE)" }

    $wixobjs = Get-ChildItem -LiteralPath $objDir -Filter '*.wixobj' | ForEach-Object { $_.FullName }
    $msi = Join-Path $AssetsDir "LunarExtensionHost-$ver.msi"
    if (Test-Path $msi) { Remove-Item $msi -Force }
    & "$wix\light.exe" -nologo -ext WixUIExtension -sice:ICE61 -spdb -out $msi @wixobjs | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "light failed ($LASTEXITCODE)" }

    # A small manifest that travels with the release (drives the share manifest too).
    [pscustomobject]@{
        name       = $AppName
        version    = $ver
        msi        = "LunarExtensionHost-$ver.msi"
        setup      = "Lunar-Setup-$ver.exe"
        portable   = "Lunar-portable-$ver.zip"
        extensions = @($exts | ForEach-Object { [pscustomobject]@{ name = $_.name; source = $_.source; type = $_.type; version = $_.version } })
        builtAt    = (Get-Date).ToString('o')
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $AssetsDir 'release.json') -Encoding ASCII

    Write-Info "Extensions (optional features): $((@($exts) | ForEach-Object name) -join ', ')"
    Write-Info "MSI:            $msi"
    Write-Info "Release assets: $AssetsDir"
}

# --- 3b. Setup program (IExpress self-extractor around the MSI) -------------------
# Builds release-assets\Lunar-Setup-<ver>.exe: the installer people download. IExpress
# (iexpress.exe, part of Windows) packs a flat list of files into a self-extracting exe
# that unpacks them to a temp folder and runs a command there:
#
#   Lunar.exe setup.lua        the wizard (src\lua\installer, embedded in Lunar.exe)
#
# The wizard shows the same pages as the Linux setup and finally runs
# `msiexec /i LunarExtensionHost-<ver>.msi ADDLOCAL=Ft_Core,Ft_ext_<id>,... /qn`
# elevated. payload.json (written here) tells it the version, the MSI's name and the
# extension -> MSI feature mapping, taken from the very list the MSI was built from.
function New-SetupExe($ver) {
    Write-Step "Building setup program (v$ver)"
    if ($null -eq $script:MsiExtensions) { throw 'New-SetupExe needs the extension list New-Msi produced.' }
    $msiName = "LunarExtensionHost-$ver.msi"
    $msi = Join-Path $AssetsDir $msiName
    if (-not (Test-Path -LiteralPath $msi)) { throw "MSI not found: $msi" }

    $iexpress = Join-Path $env:SystemRoot 'System32\iexpress.exe'
    if (-not (Test-Path -LiteralPath $iexpress)) { $iexpress = Join-Path $env:SystemRoot 'SysWOW64\iexpress.exe' }
    if (-not (Test-Path -LiteralPath $iexpress)) { throw 'iexpress.exe not found (it ships with Windows).' }

    $stage = Join-Path $DistDir 'setup'
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    # IExpress packages a flat folder, so everything sits side by side.
    Copy-Item -LiteralPath (Join-Path $BinDir $ExeName) -Destination $stage
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'installer\setup.lua') -Destination $stage
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'LICENSE') -Destination $stage
    Copy-Item -LiteralPath $msi -Destination $stage

    $payload = [ordered]@{
        version    = $ver
        platform   = 'windows'
        msi        = $msiName
        extensions = @($script:MsiExtensions | ForEach-Object {
            [ordered]@{ id = $_.extId; name = $_.name; version = $_.version; description = $_.description
                        feature = "Ft_ext_$($_.id)" }
        })
    }
    $json = $payload | ConvertTo-Json -Depth 6
    # UTF-8 without a BOM (the Lua JSON decoder doesn't skip one).
    [System.IO.File]::WriteAllText((Join-Path $stage 'payload.json'), $json, (New-Object System.Text.UTF8Encoding($false)))

    $files = @(Get-ChildItem -LiteralPath $stage -File | ForEach-Object Name)
    $out = Join-Path $AssetsDir "Lunar-Setup-$ver.exe"
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }

    $strings = New-Object System.Collections.Generic.List[string]
    $sources = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $files.Count; $i++) {
        $strings.Add(('FILE{0}="{1}"' -f $i, $files[$i]))
        $sources.Add("%FILE$i%=")
    }
    $sed = @"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=1
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$out
FriendlyName=Lunar Setup $ver
AppLaunched=$ExeName setup.lua
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
$($strings -join "`r`n")
[SourceFiles]
SourceFiles0=$stage\
[SourceFiles0]
$($sources -join "`r`n")
"@
    $sedPath = Join-Path $DistDir 'setup.sed'
    Set-Content -LiteralPath $sedPath -Value $sed -Encoding ASCII

    # /N: no wizard, /Q: quiet. The .SED is named relative to the working folder: a
    # quoted absolute path makes iexpress exit 1 without a message. It can also return
    # before the exe is complete on some Windows versions, so wait for the output as
    # well as the process.
    $p = Start-Process -FilePath $iexpress -ArgumentList @('/N', '/Q', (Split-Path -Leaf $sedPath)) `
        -WorkingDirectory (Split-Path -Parent $sedPath) -Wait -PassThru
    $deadline = (Get-Date).AddSeconds(120)
    while (-not (Test-Path -LiteralPath $out) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-Path -LiteralPath $out)) { throw "iexpress did not produce $out (exit $($p.ExitCode)); see $sedPath" }
    # Let it finish writing.
    Start-Sleep -Seconds 1
    Write-Info "Setup:          $out ($([math]::Round((Get-Item -LiteralPath $out).Length / 1MB, 1)) MB)"
}

# --- 4a. Publish to the SMB share (versioned mirror) ----------------------------
# Copies this version's MSI + portable zip + release.json into releases\<ver>\,
# rebuilds manifest.json, and refreshes a stable LunarExtensionHost-Setup.msi at the
# share root that always points at the latest version. Users double-click either the
# root setup or a specific release MSI - no credentials or execution-policy changes.
function Publish-Share($ver) {
    if (-not $HostRoot) { throw 'Publishing to a share needs -HostRoot \\server\share\path.' }
    Write-Step "Publishing to share: $HostRoot (releases\$ver)"
    if (-not (Test-Path -LiteralPath $HostRoot)) {
        throw "Host root not reachable: '$HostRoot'. Connect to the network/VPN, or pass a different -HostRoot."
    }
    $relDir = Join-Path $HostRoot "releases\$ver"
    if (-not (Test-Path -LiteralPath $relDir)) { New-Item -ItemType Directory -Path $relDir -Force | Out-Null }

    $assets = Get-ReleaseAssetsForVersion $ver
    foreach ($asset in $assets) {
        Copy-Item -LiteralPath $asset -Destination $relDir -Force
    }

    Update-ShareManifest

    Write-Info "Published releases\$ver\ (MSI + portable); refreshed manifest.json + root setup"
    Write-Info "Users install with:  $HostRoot\LunarExtensionHost-Setup.msi"
}

# Rebuild manifest.json by scanning the share's releases\ folder, and refresh the root
# LunarExtensionHost-Setup.msi to the latest version. latest = highest semver.
function Update-ShareManifest {
    $relRoot = Join-Path $HostRoot 'releases'
    $versions = @()
    if (Test-Path -LiteralPath $relRoot) {
        Get-ChildItem -LiteralPath $relRoot -Directory -Force | ForEach-Object {
            $v = $null
            if ([version]::TryParse($_.Name, [ref]$v)) {
                # Only consider versions that actually ship an .msi. This ignores any
                # legacy (pre-MSI) release folders that may still exist on the share.
                $msiName = "LunarExtensionHost-$($_.Name).msi"
                if (-not (Test-Path -LiteralPath (Join-Path $_.FullName $msiName))) {
                    $found = Get-ChildItem -LiteralPath $_.FullName -Filter '*.msi' -File | Select-Object -First 1
                    $msiName = if ($found) { $found.Name } else { $null }
                }
                if ($msiName) {
                    $exts = @()
                    $relJson = Join-Path $_.FullName 'release.json'
                    if (Test-Path -LiteralPath $relJson) {
                        try { $exts = @((Get-Content -LiteralPath $relJson -Raw | ConvertFrom-Json).extensions | ForEach-Object { $_.name }) } catch { }
                    }
                    $versions += [pscustomobject]@{
                        version        = $_.Name
                        msi            = "releases/$($_.Name)/$msiName"
                        extensionNames = $exts
                    }
                }
            }
        }
    }
    $sorted = @($versions | Sort-Object { [version]$_.version } -Descending)
    $latest = if ($sorted.Count -gt 0) { $sorted[0].version } else { $null }
    [pscustomobject]@{
        name        = $AppName
        latest      = $latest
        setup       = 'LunarExtensionHost-Setup.msi'
        updatedAt   = (Get-Date).ToString('o')
        versions    = $sorted
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $HostRoot 'manifest.json') -Encoding ASCII

    # Point the stable root setup at the latest version's MSI.
    if ($latest) {
        $latestMsi = Join-Path $HostRoot "releases\$latest\LunarExtensionHost-$latest.msi"
        if (Test-Path -LiteralPath $latestMsi) {
            Copy-Item -LiteralPath $latestMsi -Destination (Join-Path $HostRoot 'LunarExtensionHost-Setup.msi') -Force
        }
    }
}

# --- 4b. Publish to GitHub Releases ---------------------------------------------
function Publish-GitHubRelease($ver, $notesText) {
    if (-not $Repo) { throw 'Publishing to GitHub needs -Repo owner/name.' }
    Write-Step "Publishing GitHub release v$ver -> $Repo"
    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if (-not $gh) { throw "GitHub CLI 'gh' not found. Install it or use -PublishShare only." }

    $tag = "v$ver"
    $notesFile = Join-Path ([System.IO.Path]::GetTempPath()) ("lunar-gh-notes-{0}-{1}.md" -f $ver, [Guid]::NewGuid().ToString("N"))
    $notesText | Set-Content -LiteralPath $notesFile -Encoding UTF8

    # gh writes progress/diagnostics to stderr (even on success). Run the whole
    # gh interaction with Continue so PowerShell's Stop preference does not turn
    # that stderr into a terminating error; gate on $LASTEXITCODE instead.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & gh release view $tag --repo $Repo 2>&1
        $exists = ($LASTEXITCODE -eq 0)

        if (-not $exists) {
            Write-Info "Creating release $tag"
            & gh release create $tag --repo $Repo --title "Lunar Extension Host $ver" `
                --notes-file $notesFile 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "gh release create failed ($LASTEXITCODE)" }
        } else {
            Write-Info "Release $tag exists - updating notes and refreshing assets"
            & gh release edit $tag --repo $Repo --title "Lunar Extension Host $ver" `
                --notes-file $notesFile 2>&1 | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "gh release edit failed ($LASTEXITCODE)" }
        }

        $assets = Get-ReleaseAssetsForVersion $ver
        & gh release upload $tag --repo $Repo --clobber @assets 2>&1 | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "gh release upload failed ($LASTEXITCODE)" }

        Write-Info "Uploaded $((@($assets)).Count) asset(s) to $tag"
    }
    finally {
        if (Test-Path -LiteralPath $notesFile) {
            Remove-Item -LiteralPath $notesFile -Force
        }
        $ErrorActionPreference = $prevEap
    }
}

# --- Main -----------------------------------------------------------------------
$Version = Resolve-Version
Write-Step "$AppName packager - mode: $Mode, version: $Version"

if ($Clean -and (Test-Path $DistDir)) {
    Write-Step "Cleaning $DistDir"
    Remove-Item $DistDir -Recurse -Force
}
New-Item -ItemType Directory -Path $DistDir   -Force | Out-Null
New-Item -ItemType Directory -Path $AssetsDir -Force | Out-Null

Invoke-Build

if (-not (Test-Path (Join-Path $BinDir $ExeName))) {
    throw "Expected executable not found: $(Join-Path $BinDir $ExeName). Build may have failed."
}

switch ($Mode) {
    'portable'  { New-Portable $Version }
    'installer' { New-Msi $Version; New-SetupExe $Version }
    'all'       { New-Portable $Version; New-Msi $Version; New-SetupExe $Version }
}

# Publishing (the MSI is required for either target).
$doGit   = $Publish -or $PublishGitHub
$doShare = $Publish -or $PublishShare
if (($doGit -or $doShare) -and $Mode -eq 'portable') {
    throw "Publishing requires the MSI. Use -Mode installer or -Mode all."
}
if ($doShare) { Publish-Share $Version }
if ($doGit)   {
    $notes = Resolve-ReleaseNotes $Version
    Publish-GitHubRelease $Version $notes
}
if (-not ($doGit -or $doShare)) {
    Write-Info "(staged only - add -Publish, -PublishGitHub, or -PublishShare to deploy)"
}

Write-Step "Packaging complete. Artifacts under: $DistDir"

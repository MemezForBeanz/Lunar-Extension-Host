#Requires -Version 5.1
<# Bundle the exact extension runtimes before ZIP/MSI packaging. Downloads are pinned and
   cached under build/, and no runtime is installed into Windows or the user's PATH. #>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PluginsRoot,
    [string]$DownloadCache=(Join-Path (Split-Path -Parent $PSScriptRoot) 'build/media-runtime-downloads')
)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
foreach($id in @('media','media-server')){
    $extension=Join-Path $PluginsRoot $id
    if(-not (Test-Path -LiteralPath (Join-Path $extension 'manifest.json'))){continue}
    $runtime=Join-Path $extension 'runtime'
    New-Item -ItemType Directory -Path $runtime -Force | Out-Null
    $source=Join-Path $repo "extensions/$id/runtime"
    Copy-Item -LiteralPath (Join-Path $source 'bootstrap.ps1') -Destination $runtime -Force
    Copy-Item -LiteralPath (Join-Path $source 'windows-x86_64.json') -Destination $runtime -Force
    $bootstrap=Join-Path $runtime 'bootstrap.ps1'
    # Use a child PowerShell so the bootstrap's exit cannot terminate the packager.
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bootstrap `
        -Manifest (Join-Path $runtime 'windows-x86_64.json') -Destination (Join-Path $runtime 'windows-x86_64') `
        -DownloadCache $DownloadCache
    if($LASTEXITCODE -ne 0){throw "Could not bundle $id runtime"}
}

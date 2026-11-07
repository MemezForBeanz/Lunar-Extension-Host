#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Manifest,
    [Parameter(Mandatory=$true)][string]$Destination,
    [string]$DownloadCache
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'

function Assert-RelativePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::IsPathRooted($Path) -or $Path.Contains(':') -or
        @(($Path -replace '\\','/').Split('/') | Where-Object { $_ -eq '..' }).Count -gt 0) {
        throw "Invalid runtime member path: $Path"
    }
}
function Assert-Child([string]$Path,[string]$Parent) {
    $resolved=[IO.Path]::GetFullPath($Path)
    $root=[IO.Path]::GetFullPath($Parent).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($root,[StringComparison]::OrdinalIgnoreCase)){throw 'Runtime path escaped its staging folder'}
    return $resolved
}
function Test-Ready([string]$Directory,$Definition) {
    $receiptPath=Join-Path $Directory 'receipt.json'
    if(-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)){return $false}
    try {
        $receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
        if($receipt.id -ne $Definition.id){return $false}
        foreach($tool in $Definition.tools.PSObject.Properties){
            Assert-RelativePath $tool.Value
            $file=Join-Path $Directory $tool.Value
            if(-not (Test-Path -LiteralPath $file -PathType Leaf)){return $false}
            $expected=$receipt.files.PSObject.Properties[$tool.Value].Value
            if(-not $expected -or (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne $expected){return $false}
        }
        return $true
    } catch {return $false}
}

$definition=Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if($definition.platform -ne 'windows-x86_64' -or $definition.id -notmatch '^[a-zA-Z0-9._-]+$'){throw 'Unsupported or invalid runtime manifest'}
$target=[IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
$parent=Split-Path -Parent $target
if([string]::IsNullOrWhiteSpace($parent) -or $target -eq [IO.Path]::GetPathRoot($target)){throw 'Runtime destination must be a child directory'}
New-Item -ItemType Directory -Path $parent -Force | Out-Null
$target=Assert-Child $target $parent
if(-not $DownloadCache){$DownloadCache=Join-Path $parent 'downloads'}
$DownloadCache=[IO.Path]::GetFullPath($DownloadCache)
New-Item -ItemType Directory -Path $DownloadCache -Force | Out-Null

# A second Lunar process waits for the first, rather than downloading or replacing the same
# tools at once. This lock is per destination and does not require administrator rights.
$lockPath=Join-Path $parent ((Split-Path -Leaf $target)+'.provision.lock')
$deadline=[DateTime]::UtcNow.AddMinutes(5)
$lock=$null
while(-not $lock){
    try{$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
    catch [IO.IOException]{if([DateTime]::UtcNow -gt $deadline){throw 'Timed out waiting for another media runtime preparation'};Start-Sleep -Milliseconds 500}
}
$staging=Assert-Child (Join-Path $parent ('.runtime-staging-'+[Guid]::NewGuid().ToString('N'))) $parent
$old=$null
$promoted=$false
try {
    if(Test-Ready $target $definition){Write-Output "Ready: $($definition.id)";exit 0}
    New-Item -ItemType Directory -Path $staging | Out-Null
    $payload=Join-Path $staging 'payload'
    New-Item -ItemType Directory -Path $payload | Out-Null
    $provenance=@()
    foreach($package in $definition.packages){
        if($package.id -notmatch '^[a-zA-Z0-9._-]+$' -or $package.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $package.url -notmatch '^https://'){
            throw 'Runtime package must have a pinned HTTPS URL and SHA-256'
        }
        if($package.format -notin @('zip','7z','exe')){throw 'Unsupported runtime archive format'}
        $archive=Assert-Child (Join-Path $DownloadCache ($package.sha256+'.'+$package.format)) $DownloadCache
        if(-not (Test-Path -LiteralPath $archive) -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $package.sha256){
            $partial=$archive+'.partial-'+[Guid]::NewGuid().ToString('N')
            try {
                Write-Output "Downloading $($package.id)"
                $curl=Join-Path $env:SystemRoot 'System32/curl.exe'
                if(Test-Path -LiteralPath $curl){
                    & $curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 --retry 2 --output $partial $package.url
                    if($LASTEXITCODE -ne 0){throw "Download failed for $($package.id)"}
                } else {
                    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -UseBasicParsing -Uri $package.url -OutFile $partial -TimeoutSec 300
                }
                if((Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $package.sha256){throw "Checksum mismatch for $($package.id)"}
                Move-Item -LiteralPath $partial -Destination $archive -Force
            } finally {if(Test-Path -LiteralPath $partial){Remove-Item -LiteralPath $partial}}
        }
        $unpack=Assert-Child (Join-Path $staging $package.id) $staging
        New-Item -ItemType Directory -Path $unpack | Out-Null
        if($package.format -eq 'zip'){
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip=[IO.Compression.ZipFile]::OpenRead($archive)
            try{foreach($entry in $zip.Entries){if($entry.FullName){Assert-RelativePath $entry.FullName}}}finally{$zip.Dispose()}
            Expand-Archive -LiteralPath $archive -DestinationPath $unpack
        } elseif($package.format -eq '7z'){
            $tar=Join-Path $env:SystemRoot 'System32/tar.exe'
            if(-not (Test-Path -LiteralPath $tar)){throw 'This Windows version lacks tar.exe, needed for the packaged playback library'}
            $members=@(& $tar -tf $archive)
            if($LASTEXITCODE -ne 0){throw 'Could not inspect playback library archive'}
            foreach($member in $members){Assert-RelativePath $member}
            & $tar -xf $archive -C $unpack
            if($LASTEXITCODE -ne 0){throw 'Could not unpack playback library'}
        } else {
            $name=@($package.files.PSObject.Properties)[0].Name
            if($name -notmatch '^[a-zA-Z0-9._-]+$'){throw 'Invalid runtime executable name'}
            Copy-Item -LiteralPath $archive -Destination (Join-Path $unpack $name)
        }
        foreach($mapping in $package.files.PSObject.Properties){
            if($mapping.Name -notmatch '^[a-zA-Z0-9._-]+$'){throw 'Invalid runtime tool name'}
            Assert-RelativePath $mapping.Value
            $matches=@(Get-ChildItem -LiteralPath $unpack -Recurse -File | Where-Object {$_.Name -eq $mapping.Name})
            if($matches.Count -ne 1){throw "Expected exactly one $($mapping.Name) in $($package.id)"}
            $output=Assert-Child (Join-Path $payload $mapping.Value) $payload
            New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null
            Copy-Item -LiteralPath $matches[0].FullName -Destination $output
        }
        $licenseDir=Join-Path $payload ('licenses/'+$package.id)
        New-Item -ItemType Directory -Path $licenseDir -Force | Out-Null
        $notices=@(Get-ChildItem -LiteralPath $unpack -Recurse -File | Where-Object {$_.Name -match '^(LICENSE|COPYING|COPYRIGHT)'})
        $i=0
        foreach($notice in $notices){Copy-Item -LiteralPath $notice.FullName -Destination (Join-Path $licenseDir (([string]$i)+'-'+$notice.Name));$i++}
        $provenance+=@{id=$package.id;url=$package.url;sha256=$package.sha256;source=$package.source}
    }
    $hashes=@{}
    foreach($tool in $definition.tools.PSObject.Properties){
        Assert-RelativePath $tool.Value
        $file=Assert-Child (Join-Path $payload $tool.Value) $payload
        if(-not (Test-Path -LiteralPath $file -PathType Leaf)){throw "Runtime tool was not produced: $($tool.Name)"}
        $hashes[$tool.Value]=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    }
    @{id=$definition.id;platform=$definition.platform;files=$hashes;packages=$provenance} | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath (Join-Path $payload 'receipt.json') -Encoding Ascii
    if(Test-Path -LiteralPath $target){
        $old=Assert-Child (Join-Path $parent ('.runtime-old-'+[Guid]::NewGuid().ToString('N'))) $parent
        Move-Item -LiteralPath $target -Destination $old
    }
    try{Move-Item -LiteralPath $payload -Destination $target;$promoted=$true}
    catch{if($old -and -not (Test-Path -LiteralPath $target)){Move-Item -LiteralPath $old -Destination $target;$old=$null};throw}
    Write-Output "Ready: $($definition.id)"
} finally {
    $lock.Dispose()
    # Every recursive target is resolved and verified to remain directly inside the chosen
    # runtime parent before removal. An interrupted run never deletes the active payload.
    $staging=Assert-Child $staging $parent
    if(Test-Path -LiteralPath $staging){Remove-Item -LiteralPath $staging -Recurse -Force}
    if($promoted -and $old){$old=Assert-Child $old $parent;if(Test-Path -LiteralPath $old){Remove-Item -LiteralPath $old -Recurse -Force}}
}

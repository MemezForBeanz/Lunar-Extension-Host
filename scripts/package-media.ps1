# Build reviewable, self-contained Windows extension ZIPs from the current sources.
[CmdletBinding()]
param([string]$OutputRoot)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
if(-not $OutputRoot){$OutputRoot=Join-Path $repo 'dist/media-0.2.0'}
$OutputRoot=[IO.Path]::GetFullPath($OutputRoot)
if(Test-Path -LiteralPath $OutputRoot){throw 'Output directory already exists; choose a new -OutputRoot.'}
New-Item -ItemType Directory -Path (Join-Path $OutputRoot 'plugins') -Force | Out-Null
foreach($id in @('media','media-server')){Copy-Item -LiteralPath (Join-Path $repo "extensions/$id") -Destination (Join-Path $OutputRoot 'plugins') -Recurse}
& (Join-Path $PSScriptRoot 'package-media-runtime.ps1') -PluginsRoot (Join-Path $OutputRoot 'plugins')
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$artifacts=@()
foreach($id in @('media','media-server')){
 $source=Join-Path $OutputRoot "plugins/$id"
 $manifest=Get-Content -LiteralPath (Join-Path $source 'manifest.json') -Raw | ConvertFrom-Json
 $zip=Join-Path $OutputRoot ($id+'-'+$manifest.version+'-windows-x86_64.zip')
 # .NET Framework's CreateFromDirectory can emit Windows backslashes. ZIP members
 # use forward slashes so the extension importer sees the same layout on every host.
 $archive=[IO.Compression.ZipFile]::Open($zip,[IO.Compression.ZipArchiveMode]::Create)
 try {
  $source=[IO.Path]::GetFullPath($source).TrimEnd('\','/')
  foreach($file in Get-ChildItem -LiteralPath $source -Recurse -File){
   $relative=$file.FullName.Substring($source.Length+1).Replace('\','/')
   $entry=$archive.CreateEntry($id+'/'+$relative,[IO.Compression.CompressionLevel]::Optimal)
   $sourceStream=$file.OpenRead();$entryStream=$entry.Open()
   try{$sourceStream.CopyTo($entryStream)}finally{$sourceStream.Dispose();$entryStream.Dispose()}
  }
 } finally {$archive.Dispose()}
 $artifacts+=@{extension=$id;version=$manifest.version;file=(Split-Path -Leaf $zip);sha256=(Get-FileHash -LiteralPath $zip).Hash}
 Write-Output $zip
}
$artifacts | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputRoot 'artifacts.json') -Encoding Ascii
Copy-Item -LiteralPath (Join-Path $repo 'docs/media/rework.md') -Destination (Join-Path $OutputRoot 'README.md')
foreach($doc in @('source-compatibility.md','metadata.md','runtime.md','mihon-research.md','plex-reference.md')){
 Copy-Item -LiteralPath (Join-Path $repo "docs/media/$doc") -Destination $OutputRoot
}

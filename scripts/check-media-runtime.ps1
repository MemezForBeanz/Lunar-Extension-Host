# Offline integration check: a tiny ZIP fixture exercises extraction, receipts and atomic
# failure recovery. It never downloads or executes the fixture's fake executable.
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$root=Join-Path $repo ('build/runtime-check-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$source=Join-Path $root 'input'
New-Item -ItemType Directory -Path $source | Out-Null
[IO.File]::WriteAllText((Join-Path $source 'test.exe'),'not executable; fixture only')
$zip=Join-Path $root 'fixture.zip'
Compress-Archive -Path (Join-Path $source '*') -DestinationPath $zip
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
$cache=Join-Path $root 'downloads'
New-Item -ItemType Directory -Path $cache | Out-Null
Copy-Item -LiteralPath $zip -Destination (Join-Path $cache ($hash+'.zip'))
$definition=@{id='fixture-1';platform='windows-x86_64';tools=@{test='bin/test.exe'};packages=@(@{id='fixture';url='https://invalid.example/never-fetched.zip';sha256=$hash;format='zip';files=@{'test.exe'='bin/test.exe'};source='fixture'})}
$manifest=Join-Path $root 'manifest.json'
$definition | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifest -Encoding Ascii
$target=Join-Path $root 'runtime'
$bootstrap=Join-Path $repo 'extensions/media-server/runtime/bootstrap.ps1'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bootstrap -Manifest $manifest -Destination $target -DownloadCache $cache
if($LASTEXITCODE -ne 0){throw 'Offline preparation failed'}
$before=(Get-FileHash -LiteralPath (Join-Path $target 'bin/test.exe')).Hash
if(-not (Test-Path -LiteralPath (Join-Path $target 'receipt.json'))){throw 'Runtime receipt missing'}
# A later manifest cannot replace a good runtime if its payload is incomplete.
$definition.id='fixture-2';$definition.packages[0].files=@{'missing.exe'='bin/test.exe'}
$definition | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifest -Encoding Ascii
$ErrorActionPreference='Continue'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bootstrap -Manifest $manifest -Destination $target -DownloadCache $cache 2> (Join-Path $root 'expected-error.txt')
$ErrorActionPreference='Stop'
if($LASTEXITCODE -eq 0){throw 'Incomplete payload was accepted'}
if((Get-FileHash -LiteralPath (Join-Path $target 'bin/test.exe')).Hash -ne $before){throw 'Failed preparation changed the active runtime'}
$definition.packages[0].url='http://invalid.example/insecure.zip'
$definition | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifest -Encoding Ascii
$ErrorActionPreference='Continue'
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $bootstrap -Manifest $manifest -Destination (Join-Path $root 'insecure') -DownloadCache $cache 2> (Join-Path $root 'expected-insecure-error.txt')
$ErrorActionPreference='Stop'
if($LASTEXITCODE -eq 0){throw 'Unencrypted runtime URL was accepted'}
'Offline media runtime checks passed: verified extraction, receipt, failed-upgrade preservation, HTTPS requirement'
$global:LASTEXITCODE=0

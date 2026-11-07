# Native end-to-end check against a fresh catalog and contained FFmpeg. No user data.
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PluginsRoot,[int]$Port=8433)
$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$root=Join-Path $repo ('build/media-server-check-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$root/Films/Example Film (2020)","$root/secrets" -Force | Out-Null
$ffmpeg=Join-Path $PluginsRoot 'media-server/runtime/windows-x86_64/bin/ffmpeg.exe'
& $ffmpeg -v error -f lavfi -i 'color=c=black:s=64x64:d=1' -an -c:v libx264 -pix_fmt yuv420p "$root/Films/Example Film (2020)/Example Film (2020).mp4"
if($LASTEXITCODE -ne 0){throw 'Could not generate the integration fixture'}
$tokens=Join-Path $root 'tokens'
[IO.File]::WriteAllText($tokens,'test isolated-media-integration-token')
$headers=@{Authorization='Bearer isolated-media-integration-token'}
$base="http://127.0.0.1:$Port/ext/media-server/v1"
$process=Start-Process (Join-Path $repo 'build/win/bin/LunarCLI.exe') -ArgumentList @('--headless','--dev','--extensions',('"'+$PluginsRoot+'"'),'--require','media-server','--state-dir',('"'+"$root/state"+'"'),'--secrets-dir',('"'+"$root/secrets"+'"'),'--listen',"127.0.0.1:$Port",'--tokens-file',('"'+$tokens+'"'),'--for','30') -WindowStyle Hidden -RedirectStandardOutput "$root/stdout.log" -RedirectStandardError "$root/stderr.log" -PassThru
try {
 $status=$null
 for($i=0;$i -lt 30;$i++){
  try{$status=Invoke-RestMethod "$base/status" -Headers $headers -TimeoutSec 1;break}catch{Start-Sleep -Milliseconds 100}
 }
 if(-not $status -or $status.runtime.state -ne 'ready' -or $status.analysis -ne 'on'){throw 'Contained server runtime did not become ready'}
 if(-not $status.metadata.configured -or $status.metadata.provider -ne 'keyless'){throw 'Keyless metadata was not available in isolated service'}
 if(@($status.metadata.providers | Where-Object { -not $_.keyless -and $_.configured }).Count -ne 0){throw 'Unexpected private provider credentials in isolated service'}
 $library=Invoke-RestMethod "$base/libraries" -Method Post -Headers $headers -ContentType 'application/json' -Body (@{name='Fixture';kind='movie';root="$root/Films"}|ConvertTo-Json)
 for($i=0;$i -lt 60;$i++){
  $status=Invoke-RestMethod "$base/status" -Headers $headers
  if($status.files -eq 1 -and $status.analysing -eq 0){break}
  Start-Sleep -Milliseconds 100
 }
 if($status.files -ne 1 -or $status.failed -ne 0 -or $status.analysing -ne 0){throw 'Scan or contained ffprobe analysis did not complete'}
 $items=(Invoke-RestMethod "$base/libraries/$($library.id)/items" -Headers $headers).items
 if($items.Count -ne 1 -or $items[0].height -ne 64){throw 'Analyzed media facts are incorrect'}
 $detail=Invoke-RestMethod "$base/items/$($items[0].id)" -Headers $headers
 $facts=@{provider='cinemeta';external_id='tt0120338';title='Chosen fixture title';overview='Public desktop metadata';token='discard-this-field'} | ConvertTo-Json
 $applied=Invoke-RestMethod "$base/items/$($items[0].id)/metadata/apply" -Method Post -Headers $headers -ContentType 'application/json' -Body $facts
 $matched=Invoke-RestMethod "$base/items/$($items[0].id)" -Headers $headers
 if(-not $applied.saved -or $matched.title -ne 'Chosen fixture title' -or $matched.metadata.provider -ne 'cinemeta'){throw 'Public desktop metadata did not persist'}
 if(($matched | ConvertTo-Json -Depth 12) -match 'discard-this-field'){throw 'An unknown credential field leaked into catalog metadata'}
 $request=[Net.HttpWebRequest]::Create("$base/files/$($detail.files[0].id)/stream")
 $request.Headers['Authorization']=$headers.Authorization
 $request.AddRange(0,15)
 $stream=$request.GetResponse()
 try { if([int]$stream.StatusCode -ne 206 -or $stream.ContentLength -ne 16){throw 'Authenticated byte-range streaming failed'} }
 finally {$stream.Dispose()}
 Write-Output 'Contained server: ready; local scan, FFprobe analysis, keyless metadata and authenticated byte-range playback passed'
} finally {
 if(-not $process.HasExited){$process.Kill();$process.WaitForExit()}
}

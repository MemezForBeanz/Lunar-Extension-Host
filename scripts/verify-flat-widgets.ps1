param([switch]$BuildOnly)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$env:TEMP = 'D:\lunar-council\tmp'; $env:TMP = $env:TEMP
$env:PATH = 'C:\Windows\System32;C:\msys64\mingw64\bin;' + $env:PATH
$dir = 'D:\lunar-council\scratch\fork'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$exe = Join-Path $dir 'verify_flat_widgets.exe'
$gcc = 'C:\msys64\mingw64\bin\gcc.exe'
$libs = @((Join-Path $repo 'vendor\iup-src\build\libiup.a'),
  '-luser32','-lgdi32','-lgdiplus','-lcomdlg32','-lcomctl32',
  '-lole32','-loleaut32','-luuid','-lwinspool','-ladvapi32','-lshell32',
  '-luxtheme','-lmsimg32','-lwinmm','-lstdc++')
& $gcc -O2 "-I$(Join-Path $repo 'vendor\iup\include')" (Join-Path $repo 'iup-fork\verify\verify_flat_widgets.c') -o $exe -mwindows @libs
if ($LASTEXITCODE -ne 0) { throw 'flat widget harness did not link' }
Write-Output "Built $exe"
if (-not $BuildOnly) { & $exe }

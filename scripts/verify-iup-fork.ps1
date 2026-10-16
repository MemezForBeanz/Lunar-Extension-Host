# scripts/verify-iup-fork.ps1 - build the gradient/corner verification harness against
# the from-source fork libiup.a, run it, and screenshot the window to a PNG so the new
# native rounded/gradient drawing can be visually confirmed.
$ErrorActionPreference = "Continue"
$repo   = Split-Path -Parent $PSScriptRoot
$srcdir = Join-Path $repo "vendor\iup-src\iup\src"
$vdir   = Join-Path $repo "vendor\iup-src\verify"
$fork   = Join-Path $repo "vendor\iup-src\build\libiup.a"
$iupdir = Join-Path $repo "vendor\iup"
$gcc    = "C:\msys64\mingw64\bin\gcc.exe"
$exe    = Join-Path $vdir "verify_gradient.exe"
$png    = Join-Path $vdir "verify.png"

# 1. build fork lib (incremental) so the harness links the latest patches
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "build-iup-fork.ps1") | Out-Host

# 2. compile + link the harness (only needs core IUP + Win system libs)
$inc = @("-I$iupdir\include")
$libs = @($fork,
  '-luser32','-lgdi32','-lgdiplus','-lcomdlg32','-lcomctl32',
  '-lole32','-loleaut32','-luuid','-lwinspool','-ladvapi32','-lshell32',
  '-luxtheme','-lmsimg32','-lwinmm','-lstdc++')
& $gcc -O2 -w @inc (Join-Path $vdir "verify_gradient.c") -o $exe -mwindows @libs 2>"$env:TEMP\verify_link.err"
if ($LASTEXITCODE -ne 0) {
  Write-Host "LINK FAILED:" -ForegroundColor Red
  Get-Content "$env:TEMP\verify_link.err" | Select-Object -First 40
  exit 1
}
Write-Host "Harness built: $exe" -ForegroundColor Green

# 3. run it and screenshot the window
Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Win {
  [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Auto)]
  public static extern IntPtr FindWindow(string cls, string name);
  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")]
  public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr h);
  public struct RECT { public int Left, Top, Right, Bottom; }
}
"@

$p = Start-Process -FilePath $exe -PassThru
Start-Sleep -Seconds 2

$hwnd = [Win]::FindWindow($null, "Lunar IUP Fork - Gradient/Corner Verify")
if ($hwnd -eq [IntPtr]::Zero) {
  Write-Host "Could not find harness window." -ForegroundColor Red
} else {
  [Win]::SetForegroundWindow($hwnd) | Out-Null
  Start-Sleep -Milliseconds 400
  $r = New-Object Win+RECT
  [Win]::GetWindowRect($hwnd, [ref]$r) | Out-Null
  $w = $r.Right - $r.Left; $h = $r.Bottom - $r.Top
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $g.GetHdc()
  [Win]::PrintWindow($hwnd, $hdc, 2) | Out-Null   # 2 = PW_RENDERFULLCONTENT
  $g.ReleaseHdc($hdc)
  $g.Dispose()
  $bmp.Save($png, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()
  Write-Host "Saved screenshot: $png ($w x $h)" -ForegroundColor Green
}

if (-not $p.HasExited) { $p | Stop-Process -Force -ErrorAction SilentlyContinue }

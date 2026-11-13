param([int]$Runs = 5, [string]$OutputDir = 'build/ui-benchmark', [switch]$Profile, [switch]$Uncapped,
 [switch]$IdleOnly, [int]$IdleMs = 2000, [int]$WarmupMs = 2000, [switch]$SkipNetworkProbes,
 [string]$OrgPacksDir = 'C:\Users\Hayden MSI\.t3\worktrees\lunar-orgpacks-imgui-1',
 [ValidateSet('warp','auto','hardware')][string]$Renderer='warp',
 [ValidateSet('auto','lua','native')][string]$Layout='auto')
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$out = [IO.Path]::GetFullPath((Join-Path $repo $OutputDir))
New-Item -ItemType Directory -Force $out | Out-Null
$packs = $OrgPacksDir
if (-not (Test-Path -LiteralPath $packs)) { throw "Org packs missing: $packs" }
# Own and close every process/thread/desktop handle. No visible windows or user settings.
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text;
public static class LunarBench {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct SI {public int cb; public string r,desktop,title; public int x,y,xs,ys,xc,yc,fa,flags; public short sw,r2; public IntPtr r3,i,o,e;}
 [StructLayout(LayoutKind.Sequential)] public struct PI {public IntPtr hP,hT; public int pid,tid;}
 [DllImport("user32",CharSet=CharSet.Unicode,SetLastError=true)] public static extern IntPtr CreateDesktopW(string n,IntPtr a,IntPtr b,int f,uint acc,IntPtr sa);
 [DllImport("user32")] public static extern bool CloseDesktop(IntPtr h);
 [DllImport("kernel32",CharSet=CharSet.Unicode,SetLastError=true)] public static extern bool CreateProcessW(string app,StringBuilder cmd,IntPtr pa,IntPtr ta,bool inh,uint fl,IntPtr env,string cwd,ref SI si,out PI pi);
 [DllImport("kernel32")] public static extern uint WaitForSingleObject(IntPtr h,uint ms);
 [DllImport("kernel32")] public static extern bool TerminateProcess(IntPtr h,uint c);
 [DllImport("kernel32")] public static extern bool GetExitCodeProcess(IntPtr h,out uint c);
 [DllImport("kernel32")] public static extern bool CloseHandle(IntPtr h);
}
'@
$envNames = @('APPDATA','LUNAR_PROFILE','LUNAR_PROFILE_DIR','LUNAR_DEV_EXTENSIONS','LUNAR_CAPTURE_CLIENT','LUNAR_BENCH_LAUNCH_QPC','LUNAR_BENCH_MODE','LUNAR_BENCH_PROFILE','LUNAR_RENDERER','LUNAR_GLYPHS','LUNAR_VSYNC','LUNAR_BENCH_IDLE_ONLY','LUNAR_BENCH_IDLE_MS','LUNAR_BENCH_WARMUP_MS','LUNAR_BENCH_SKIP_PROBES','LUNAR_LAYOUT')
$saved = @{}
foreach ($name in $envNames) { $saved[$name]=[Environment]::GetEnvironmentVariable($name) }
$desktopName = 'LunarBenchmark' + [Guid]::NewGuid().ToString('N')
$desktop = [LunarBench]::CreateDesktopW($desktopName,[IntPtr]::Zero,[IntPtr]::Zero,0,0x10000000,[IntPtr]::Zero)
if ($desktop -eq [IntPtr]::Zero) { throw 'CreateDesktop failed' }
$records = @()
try {
 $env:LUNAR_CAPTURE_CLIENT='1'; $env:LUNAR_DEV_EXTENSIONS='0'
 $env:LUNAR_RENDERER=$Renderer; $env:LUNAR_GLYPHS='gdi'; $env:LUNAR_LAYOUT=$Layout
 $env:LUNAR_VSYNC = $(if ($Uncapped) {'0'} else {'1'})
 $env:LUNAR_BENCH_PROFILE = $(if ($Profile) {'1'} else {'0'})
 $env:LUNAR_BENCH_IDLE_ONLY = $(if ($IdleOnly) {'1'} else {'0'})
 $env:LUNAR_BENCH_IDLE_MS="$IdleMs"; $env:LUNAR_BENCH_WARMUP_MS="$WarmupMs"
 $env:LUNAR_BENCH_SKIP_PROBES = $(if ($SkipNetworkProbes) {'1'} else {'0'})
 for ($run=1; $run -le $Runs; $run++) {
  # Alternate backend order on every repeat to reduce cache/order bias.
  $backends = $(if ($run % 2) { @('iup','imgui') } else { @('imgui','iup') })
  $modes = $(if ($run % 2) { @('none','all') } else { @('all','none') })
  foreach ($mode in $modes) { foreach ($backend in $backends) {
   $dir=Join-Path $out "$backend-$mode-$run"
   if (Test-Path -LiteralPath $dir) { throw "Refusing to reuse benchmark directory: $dir" }
   New-Item -ItemType Directory -Force "$dir/appdata/Lunar Extension Host" | Out-Null
   '{"welcome_tour_completed":true,"welcome_tour_dismissed":true,"theme":"lunar_dark"}' | Set-Content "$dir/appdata/Lunar Extension Host/settings.json" -Encoding ascii
   $env:APPDATA="$dir/appdata"; $env:LUNAR_PROFILE_DIR=$packs
   $env:LUNAR_PROFILE = $(if ($mode -eq 'all') {'*'} else {''})
   $env:LUNAR_BENCH_MODE=$mode
   $build = $(if ($backend -eq 'iup') {'iup-bench'} else {'win'})
   $exe=Join-Path $repo "build/$build/bin/Lunar.exe"
   $si=New-Object LunarBench+SI; $si.cb=[Runtime.InteropServices.Marshal]::SizeOf($si); $si.desktop=$desktopName
   $pi=New-Object LunarBench+PI
   $cmd=New-Object Text.StringBuilder ('"'+$exe+'" "'+$PSScriptRoot+'\ui_benchmark.lua" "'+$dir+'"')
   $env:LUNAR_BENCH_LAUNCH_QPC=([Diagnostics.Stopwatch]::GetTimestamp()/[double][Diagnostics.Stopwatch]::Frequency).ToString('R',[Globalization.CultureInfo]::InvariantCulture)
   if (-not [LunarBench]::CreateProcessW([NullString]::Value,$cmd,[IntPtr]::Zero,[IntPtr]::Zero,$false,0,[IntPtr]::Zero,$repo,[ref]$si,[ref]$pi)) { throw "CreateProcess failed for $exe" }
   try {
    # Short waits allow progress messages; no background benchmark processes remain.
    $waited=0
    while ([LunarBench]::WaitForSingleObject($pi.hP,10000) -ne 0) {
     $waited+=10
     Write-Output "$backend $mode run $run still measuring ($waited seconds)"
     if ($waited -ge 120) { [void][LunarBench]::TerminateProcess($pi.hP,124); throw "Benchmark timed out: $dir" }
    }
    [uint32]$code=0; [void][LunarBench]::GetExitCodeProcess($pi.hP,[ref]$code)
    if ($code -ne 0) { throw "Benchmark exit $code : $dir" }
    $measurement=Get-Content "$dir/result.json" -Raw | ConvertFrom-Json
    if (-not $measurement.complete) { throw "Incomplete result: $dir" }
    $records+= [pscustomobject]@{backend=$backend;mode=$mode;run=$run;result="$dir/result.json"}
    Write-Output ("{0} {1} run {2}: ready {3:N1} ms, {4} extensions, idle CPU {5:N1} ms" -f $backend,$mode,$run,$measurement.ready_ms,$measurement.extension_count,$measurement.idle.cpu_ms)
   } finally { [void][LunarBench]::CloseHandle($pi.hT); [void][LunarBench]::CloseHandle($pi.hP) }
  } }
 }
 $records | ConvertTo-Json | Set-Content "$out/index.json" -Encoding utf8
 $system = Get-CimInstance Win32_ComputerSystem
 [pscustomobject]@{date=(Get-Date).ToString('o');commit=(git -C $repo rev-parse HEAD);packsCommit=(git -C $packs rev-parse HEAD);logicalCpus=$system.NumberOfLogicalProcessors;memoryGB=[math]::Round($system.TotalPhysicalMemory/1GB,1);cpu=(Get-CimInstance Win32_Processor).Name;os=[Environment]::OSVersion.ToString();renderer=$Renderer;layout=$Layout;runs=$Runs;profile=$Profile.IsPresent;uncapped=$Uncapped.IsPresent} | ConvertTo-Json | Set-Content "$out/machine.json"
} finally {
 [void][LunarBench]::CloseDesktop($desktop)
 foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
}

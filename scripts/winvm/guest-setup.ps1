# scripts/winvm/guest-setup.ps1 — one-time setup inside the Windows test VM.
#
# Run in an ELEVATED Windows PowerShell after Windows and virtio-win-guest-tools
# are installed. `scripts/winvm.sh serve-setup` on the host serves this file and
# the host's SSH key; in the VM:
#
#   Set-ExecutionPolicy -Scope Process Bypass -Force
#   iwr http://192.168.122.1:8765/guest-setup.ps1 -OutFile $env:TEMP\guest-setup.ps1
#   & $env:TEMP\guest-setup.ps1
#
# It sets up:
#   1. OpenSSH Server with the host's key, so the host can sync, build and test
#   2. no sleep or screen lock, and auto-login for this account, so GUI tests have
#      a live desktop (this is a throwaway test VM; the password is stored by
#      Windows' Winlogon auto-login)
#   3. MSYS2 with the packages README.md lists for building Lunar, and Git for Windows
#   4. C:\lunar\ and a scheduled task that runs GUI jobs on the interactive
#      desktop (a program started over SSH runs in a session with no desktop)

$ErrorActionPreference = "Stop"
$hostUrl = "http://192.168.122.1:8765"

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }

$me = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($me)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
	throw "Run this from an elevated PowerShell (Run as administrator)."
}
$user = $env:USERNAME

Step "OpenSSH Server"
$cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object -First 1
if ($cap.State -ne "Installed") { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
Set-Service sshd -StartupType Automatic
Start-Service sshd
if (-not (Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue)) {
	New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
		-Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
}
# The built-in rule only covers Private networks, and Windows files the VM's
# NAT network as Public: allow SSH on every profile and call the network Private.
Set-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -Enabled True -Profile Any
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
# Commands from the host run in Windows PowerShell.
New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Force `
	-Value "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" -PropertyType String | Out-Null
# Administrators' keys live in one file that only Administrators and SYSTEM may touch.
$keys = "$env:ProgramData\ssh\administrators_authorized_keys"
# Saved to a file first: the host's server sends .pub as application/octet-stream,
# which Windows PowerShell returns as bytes rather than text.
Invoke-WebRequest "$hostUrl/lunar_winvm.pub" -OutFile $keys -UseBasicParsing
(Get-Content $keys -Raw).Trim() | Set-Content -Encoding ascii $keys
icacls $keys /inheritance:r /grant "*S-1-5-32-544:F" /grant "SYSTEM:F" | Out-Null
Restart-Service sshd

Step "Time zone"
# libvirt gives Windows a local-time RTC; Windows must use the host's zone to read
# it, or its clock (and every file it writes) is hours off from the host's.
$hostTz = (Invoke-WebRequest "$hostUrl/timezone.txt" -UseBasicParsing -ErrorAction SilentlyContinue)
if ($hostTz) { Set-TimeZone -Id ([Text.Encoding]::ASCII.GetString($hostTz.Content).Trim()) }

Step "Power, lock screen and auto-login"
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization" -Name NoLockScreen -Value 1 -Type DWord
Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name ScreenSaveActive -Value "0"
# No toast notifications: they are topmost popups and land on top of the windows the
# GUI probes sample (a Windows Update toast broke the overlay probe's resize check).
$push = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications"
New-Item -Path $push -Force | Out-Null
Set-ItemProperty -Path $push -Name ToastEnabled -Value 0 -Type DWord
New-Item -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Force | Out-Null
Set-ItemProperty -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name DisableNotificationCenter -Value 1 -Type DWord
$pw = Read-Host -AsSecureString "Password for '$user' (for auto-login; leave empty if the account has none)"
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw))
$winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty $winlogon -Name AutoAdminLogon -Value "1"
Set-ItemProperty $winlogon -Name DefaultUserName -Value $user
Set-ItemProperty $winlogon -Name DefaultPassword -Value $plain
Set-ItemProperty $winlogon -Name DefaultDomainName -Value $env:COMPUTERNAME
# Windows 11 hides passwordless/auto sign-in behind "Windows Hello only"; turn that off.
$hello = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device"
if (Test-Path $hello) { Set-ItemProperty $hello -Name DevicePasswordLessBuildVersion -Value 0 -Type DWord }

Step "MSYS2 (toolchain for building Lunar)"
if (-not (Test-Path "C:\msys64\usr\bin\bash.exe")) {
	$installer = "$env:TEMP\msys2-x86_64-latest.exe"
	Invoke-WebRequest "https://repo.msys2.org/distrib/msys2-x86_64-latest.exe" -OutFile $installer -UseBasicParsing
	& $installer in --confirm-command --accept-messages --root C:\msys64 | Out-Host
}
$bash = "C:\msys64\usr\bin\bash.exe"
# The first update may restart the core; run it twice, as MSYS2 recommends.
& $bash -lc "pacman -Syu --noconfirm" | Out-Host
& $bash -lc "pacman -Syu --noconfirm" | Out-Host
& $bash -lc "pacman -S --noconfirm --needed mingw-w64-x86_64-toolchain mingw-w64-x86_64-cmake mingw-w64-x86_64-python perl make tar" | Out-Host

Step "Git for Windows (the IUP fork build applies its patches with git)"
if (-not (Test-Path "C:\Program Files\Git\cmd\git.exe")) {
	winget install --id Git.Git -e --silent --accept-source-agreements --accept-package-agreements --disable-interactivity | Out-Host
}

Step "C:\lunar and the interactive job runner"
New-Item -ItemType Directory -Force -Path C:\lunar\src, C:\lunar\job | Out-Null
# The host writes C:\lunar\job\command.ps1, starts this task, and waits for
# C:\lunar\job\done (exit code); output goes to C:\lunar\job\output.log.
@'
$job = "C:\lunar\job"
Remove-Item "$job\done", "$job\output.log" -ErrorAction SilentlyContinue
$env:PATH = "C:\msys64\mingw64\bin;C:\Program Files\Git\cmd;$env:PATH"
$code = 0
try {
	& powershell -NoProfile -ExecutionPolicy Bypass -File "$job\command.ps1" *> "$job\output.log"
	$code = $LASTEXITCODE
} catch {
	$_ | Out-File -Append "$job\output.log"
	$code = 1
}
Set-Content -Path "$job\done" -Value $code
'@ | Set-Content -Encoding utf8 C:\lunar\run-job.ps1
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
	-Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\lunar\run-job.ps1"
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
Register-ScheduledTask -TaskName "LunarRun" -Action $action -Principal $principal -Force | Out-Null

Step "Done"
Write-Host "Reboot once so auto-login takes effect. The host connects with: scripts/winvm.sh ssh"

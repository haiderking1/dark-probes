# first logon of the probe image: the runner and the settings the reference
# machine has, then power off so the build can save the disk
param([string]$src)
$ErrorActionPreference = 'Continue'
$run = 'C:\dark\run'
New-Item -ItemType Directory -Force $run | Out-Null
Copy-Item (Join-Path $src 'winrund.exe') $run
Copy-Item (Join-Path $src 'windbg.exe') $run
Copy-Item (Join-Path $src 'token') (Join-Path $run 'token')

schtasks /create /f /tn darkrun /tr "C:\dark\run\winrund.exe 7777 C:\dark\run" /sc onlogon /ru soka /it /rl limited | Out-Null
schtasks /create /f /tn darkrun_admin /tr "C:\dark\run\winrund.exe 7778 C:\dark\run" /sc onlogon /ru soka /it /rl highest | Out-Null
netsh advfirewall firewall add rule name=darkrun dir=in action=allow protocol=TCP localport=7777-7778 | Out-Null

# the reference machine's settings
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting" /v Disabled /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting" /v DontShowUI /t REG_DWORD /d 1 /f | Out-Null
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f | Out-Null
Set-Service wuauserv -StartupType Manual
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization" /v NoLockScreen /t REG_DWORD /d 1 /f | Out-Null

'done' | Out-File C:\dark\run\setup.done
Stop-Computer -Force

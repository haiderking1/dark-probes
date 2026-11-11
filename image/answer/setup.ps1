# the probe image's setup, in three logons: the runner, the reference
# machine's settings, runtimes and the october update (KB5127648 on its
# checkpoint), then the .NET update, then a check and power off so the build
# can save the disk. The answer disc (the runner's files) and the extras
# disc (the installers, extras.txt marks it) are found by what's on them
$ErrorActionPreference = 'Continue'
$run = 'C:\dark\run'
$state = 'C:\dark\setup'
New-Item -ItemType Directory -Force $run, $state | Out-Null
$log = "$state\setup.log"
function say ($text) { "$(Get-Date -Format s) $text" | Out-File -Append $log }
$src = (Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path ($_.DriveLetter + ':\winrund.exe')) } | Select-Object -First 1).DriveLetter + ':\'
$extras = (Get-Volume | Where-Object { $_.DriveLetter -and (Test-Path ($_.DriveLetter + ':\extras.txt')) } | Select-Object -First 1).DriveLetter + ':\'
$stage = if (Test-Path "$state\stage") { [int](Get-Content "$state\stage") } else { 0 }
say "stage $stage, answer $src, extras $extras"

if ($stage -eq 0) {
  Copy-Item (Join-Path $src 'winrund.exe') $run
  Copy-Item (Join-Path $src 'windbg.exe') $run
  Copy-Item (Join-Path $src 'token') (Join-Path $run 'token')
  Copy-Item (Join-Path $src 'setup.ps1') $state
  schtasks /create /f /tn darkrun /tr "C:\dark\run\winrund.exe 7777 C:\dark\run" /sc onlogon /ru soka /it /rl limited | Out-Null
  schtasks /create /f /tn darkrun_admin /tr "C:\dark\run\winrund.exe 7778 C:\dark\run" /sc onlogon /ru soka /it /rl highest | Out-Null
  netsh advfirewall firewall add rule name=darkrun dir=in action=allow protocol=TCP localport=7777-7778 | Out-Null

  # the reference machine's settings
  reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting" /v Disabled /t REG_DWORD /d 1 /f | Out-Null
  reg add "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting" /v DontShowUI /t REG_DWORD /d 1 /f | Out-Null
  reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f | Out-Null
  reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization" /v NoLockScreen /t REG_DWORD /d 1 /f | Out-Null
  Set-Service wuauserv -StartupType Manual
  # defender kept fresh unsigned probes from starting: leave the runner's folder alone
  Add-MpPreference -ExclusionPath 'C:\dark'
  Set-MpPreference -SubmitSamplesConsent 2 -MAPSReporting 0

  # the runtimes the reference machine has
  $quiet = '/install', '/quiet', '/norestart'
  foreach ($job in @(
      @('vc2005_x86.exe', '/q'), @('vc2005_x64.exe', '/q'),
      @('vc2010_x86.exe', '/q /norestart'), @('vc2010_x64.exe', '/q /norestart'),
      @('vc2012_x86.exe', $quiet), @('vc2012_x64.exe', $quiet),
      @('vc2013_x86.exe', $quiet), @('vc2013_x64.exe', $quiet),
      @('vc2019_x86.exe', $quiet), @('vc2019_x64.exe', $quiet))) {
    $p = Start-Process -Wait -PassThru (Join-Path $extras $job[0]) -ArgumentList $job[1]
    say "$($job[0]) $($p.ExitCode)"
  }
  $p = Start-Process -Wait -PassThru (Join-Path $extras 'directx.exe') -ArgumentList '/Q', '/T:C:\dark\dx'
  say "directx unpack $($p.ExitCode)"
  $p = Start-Process -Wait -PassThru 'C:\dark\dx\DXSETUP.exe' -ArgumentList '/silent'
  say "directx $($p.ExitCode)"
  Remove-Item -Recurse -Force 'C:\dark\dx'

  # the update and its checkpoint, from one folder: dism puts them in order
  $p = Start-Process -Wait -PassThru dism.exe -ArgumentList '/online', '/add-package', "/packagepath:$($extras)updates", '/quiet', '/norestart'
  say "update $($p.ExitCode)"
  '1' | Out-File "$state\stage"
  # the next stages at the next logons (no path argument: a quoted one
  # ending in a backslash breaks the task's command line)
  schtasks /create /f /tn darksetup /tr "powershell -NoProfile -ExecutionPolicy Bypass -File $state\setup.ps1" /sc onlogon /ru soka /it /rl highest | Out-Null
  say "next stage task $LASTEXITCODE"
  Restart-Computer -Force
} elseif ($stage -eq 1) {
  $p = Start-Process -Wait -PassThru dism.exe -ArgumentList '/online', '/add-package', "/packagepath:$($extras)dotnet", '/quiet', '/norestart'
  say "dotnet $($p.ExitCode)"
  '2' | Out-File "$state\stage"
  Restart-Computer -Force
} else {
  $v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
  say "build $($v.CurrentBuild).$($v.UBR)"
  Get-HotFix | ForEach-Object { say "hotfix $($_.HotFixID)" }
  # the reference machine's power settings (balanced)
  powercfg /change standby-timeout-ac 15
  powercfg /change standby-timeout-dc 10
  powercfg /change monitor-timeout-ac 5
  powercfg /change monitor-timeout-dc 3
  powercfg /change disk-timeout-ac 20
  powercfg /change disk-timeout-dc 10
  powercfg /change hibernate-timeout-ac 0
  powercfg /change hibernate-timeout-dc 0
  schtasks /delete /f /tn darksetup | Out-Null
  # the cache holds 10 GB: drop the update's leftovers and hand the free
  # space back so the disk compresses
  $p = Start-Process -Wait -PassThru dism.exe -ArgumentList '/online', '/cleanup-image', '/startcomponentcleanup', '/quiet'
  say "cleanup $($p.ExitCode)"
  Optimize-Volume -DriveLetter C -ReTrim
  "build $($v.CurrentBuild).$($v.UBR)" | Out-File C:\dark\run\setup.done
  Stop-Computer -Force
}

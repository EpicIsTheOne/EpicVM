#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$UserName = 'Epic',
    [string]$StarterPath = (Join-Path $PSScriptRoot 'Start-EpicVMDirectStreams.ps1'),
    [string]$StartupDirectory = 'C:\Users\Epic\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script=$StarterPath
if (-not (Test-Path -LiteralPath $script)) { throw "Missing stream starter: $script" }
$action=New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$script+'"') -WorkingDirectory (Split-Path $script)
$user=(Get-LocalUser $UserName).SID.Value
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay='PT15S'
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
Register-ScheduledTask -TaskName 'EpicVM Direct Streams' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Recover EpicVM browser streams and the shared Caddy gateway after sign-in.' -Force | Select-Object TaskName,State
$link=Join-Path $StartupDirectory 'EpicVM Direct Streams.lnk'
if(Test-Path -LiteralPath $link){Move-Item -LiteralPath $link -Destination ($link+'.disabled') -Force}
Start-ScheduledTask -TaskName 'EpicVM Direct Streams'

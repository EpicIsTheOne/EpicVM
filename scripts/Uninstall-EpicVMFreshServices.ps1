#Requires -RunAsAdministrator
param([switch]$ConfirmHostRevoked)
$ErrorActionPreference='Stop'
if(-not $ConfirmHostRevoked){throw 'Revoke this host in its portal before removing its services. Then pass -ConfirmHostRevoked.'}
$root='C:\ProgramData\EpicVM\fresh-setup'
$package='C:\Program Files\EpicVM'
Import-Module (Join-Path $package 'scripts/HostComponents.psm1') -Force
Assert-EpicVMComponentPath $root|Out-Null
$key=(Get-Content 'C:\ProgramData\MultiSeat\api-key.txt' -Raw).Trim()
$seats=Invoke-RestMethod 'http://127.0.0.1:9550/api/seats/' -Headers @{'X-MultiSeat-Key'=$key}
if(@($seats).Count){throw 'End active desktops before removing hosting services.'}
foreach($name in @('EpicVMHostControl','EpicVMHostRuntime','EpicVMRemoteAgent','EpicVMGateway','EpicVMLocalGateway','EpicVMPortal')){
 $record=Join-Path $root ($name+'.service.json')
 if(-not(Test-Path -LiteralPath $record)){continue}
 $saved=Get-Content -LiteralPath $record -Raw|ConvertFrom-Json
 $service=Get-Service $name -ErrorAction SilentlyContinue
 if(-not $service){continue}
 if($name -ne 'EpicVMHostControl'){
  $actual=(Get-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$name+'\Parameters')).Application
  if([string]$actual -ine [string]$saved.executable){throw 'Service executable changed. No unrelated service will be removed.'}
 }
 Stop-Service $name
 & sc.exe delete $name|Out-Null
 if($LASTEXITCODE -ne 0){throw 'Could not remove an owned service.'}
}
Write-Output 'Setup-owned services removed. Accounts, profiles, drivers, certificates, installed binaries and private state are retained for recovery.'

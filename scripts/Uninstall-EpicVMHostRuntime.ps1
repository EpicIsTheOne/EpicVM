#Requires -RunAsAdministrator
param([string]$InstallRoot='C:\Program Files\EpicVM')
$ErrorActionPreference='Stop'
foreach($name in @('EpicVMHostRuntime','EpicVMHostControl')){
    $service=Get-Service $name -ErrorAction SilentlyContinue
    if($service){if($service.Status -ne 'Stopped'){Stop-Service $name -Force}; & sc.exe delete $name | Out-Null}
}
$shortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'EpicVM Agent.lnk'
if(Test-Path -LiteralPath $shortcut){Remove-Item -LiteralPath $shortcut}
# Preserve machine private state, Windows profiles, seat accounts and runtime
# binaries for recovery. Cleanup can be performed separately after verification.
Write-Output 'Services removed. Host state, profiles and installed files were preserved.'

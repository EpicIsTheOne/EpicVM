Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Invoke-EpicVMServiceTool([string]$Executable,[string[]]$Arguments) {
 & $Executable @Arguments | Out-Null
 if($LASTEXITCODE -ne 0){throw 'A Windows service configuration step failed. Retry setup.'}
}
function Install-EpicVMSetupService([string]$Name,[string]$Executable,[string]$Parameters,[string]$Directory,[string]$PackageRoot,[string]$SetupRoot,[string]$Environment) {
 $allowed=@('EpicVMPortal','EpicVMGateway','EpicVMLocalGateway','EpicVMRemoteAgent','EpicVMHostRuntime','EpicVMHostControl')
 if($Name -notin $allowed){throw 'Unsupported setup service.'}
 $record=Join-Path $SetupRoot ($Name+'.service.json')
 $existing=Get-Service $Name -ErrorAction SilentlyContinue
 if($existing -and -not(Test-Path -LiteralPath $record)){throw 'A preexisting service was found. Use repair/update; fresh setup will not replace it.'}
 $desired=@{name=$Name;executable=$Executable;parameters=$Parameters;directory=$Directory;environment=$Environment}
 if(Test-Path -LiteralPath $record){
  $saved=Get-Content -LiteralPath $record -Raw | ConvertFrom-Json
  foreach($key in $desired.Keys){if([string]$saved.$key -cne [string]$desired[$key]){throw 'Service belongs to different setup inputs. Repair is required.'}}
 } else {
  [IO.File]::WriteAllText($record,($desired|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
 }
 if($existing){
  $serviceKey='HKLM:\SYSTEM\CurrentControlSet\Services\'+$Name
  if($Name -eq 'EpicVMHostControl'){
   $image=[string](Get-ItemProperty -LiteralPath $serviceKey).ImagePath
   if($image -cne ('"'+$Executable+'"')){throw 'Installed control service identity changed. Use repair.'}
  } else {
   $registeredParameters=Get-ItemProperty -LiteralPath ($serviceKey+'\Parameters')
   if([string]$registeredParameters.Application -ine $Executable -or [string]$registeredParameters.AppParameters -cne $Parameters){throw 'Installed service configuration differs from setup. Use repair.'}
  }
 }
 $nssm=Join-Path $PackageRoot 'nssm.exe'
 try {
  if(-not $existing){
   if($Name -eq 'EpicVMHostControl'){
    New-Service -Name $Name -BinaryPathName ('"'+$Executable+'"') -StartupType Automatic | Out-Null
   } else {
    Invoke-EpicVMServiceTool $nssm @('install',$Name,$Executable,$Parameters)
    Invoke-EpicVMServiceTool sc.exe @('config',$Name,'binPath=',('"'+$nssm+'"'))
   }
  }
  if($Name -ne 'EpicVMHostControl'){
   # Preserve quotes exactly under the Windows PowerShell setup broker.
   Set-ItemProperty -LiteralPath ('HKLM:\SYSTEM\CurrentControlSet\Services\'+$Name+'\Parameters') -Name AppParameters -Value $Parameters
   Invoke-EpicVMServiceTool $nssm @('set',$Name,'AppDirectory',$Directory)
   Invoke-EpicVMServiceTool $nssm @('set',$Name,'Start','SERVICE_AUTO_START')
   if($Environment){Invoke-EpicVMServiceTool $nssm @('set',$Name,'AppEnvironmentExtra',$Environment)}
   $logs=Join-Path $SetupRoot 'logs';New-Item -ItemType Directory -Force -Path $logs | Out-Null
   Invoke-EpicVMServiceTool $nssm @('set',$Name,'AppStdout',(Join-Path $logs ($Name+'.out.log')))
   Invoke-EpicVMServiceTool $nssm @('set',$Name,'AppStderr',(Join-Path $logs ($Name+'.err.log')))
   Invoke-EpicVMServiceTool $nssm @('set',$Name,'AppRotateFiles','1')
   Invoke-EpicVMServiceTool $nssm @('set',$Name,'AppRotateBytes','10485760')
  }
  Invoke-EpicVMServiceTool sc.exe @('failure',$Name,'reset=','86400','actions=','restart/5000/restart/15000/restart/60000')
  Start-Service $Name
 } catch {
  if(-not $existing){
   Stop-Service $Name -ErrorAction SilentlyContinue
   if($Name -eq 'EpicVMHostControl'){& sc.exe delete $Name | Out-Null}else{& $nssm remove $Name confirm | Out-Null}
  }
  throw
 }
}
Export-ModuleMember -Function Install-EpicVMSetupService,Invoke-EpicVMServiceTool

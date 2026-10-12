param(
 [ValidateSet('Check','Prepare','Enroll','Poll','InstallPortal','InstallComponents','InstallGateway','InstallRuntime','ConfigureLan','CheckConnectivity','Status')][string]$Action='Check',
 [string]$InputFile,
 [string]$PackageRoot=(Split-Path $PSScriptRoot),
 [string]$StateRoot='C:\ProgramData\EpicVM\fresh-setup'
)
$ErrorActionPreference='Stop'
$python=Join-Path $PackageRoot 'python\python.exe'
$engine=Join-Path $PackageRoot 'scripts\fresh_host_setup.py'
if($Action -eq 'InstallComponents') {
 & (Join-Path $PSScriptRoot 'Install-EpicVMHostComponents.ps1') -PackageRoot $PackageRoot
 return
}
if($Action -eq 'Check') {
 $checks=@()
 foreach($file in @('python/python.exe','pwsh7/pwsh.exe','scripts/HostStorage.ps1','scripts/Initialize-EpicVMStorage.ps1','scripts/Configure-EpicVMFreshLan.ps1','scripts/local_lan.py','scripts/fresh_host_setup.py','scripts/fresh_host_runtime.py','scripts/portal_service.py','dashboard/app.py','epicvm_web/dist/index.html','control/EpicVM.Control.exe','ui/EpicVM.Agent.exe','viewer/web-server.exe','viewer/streamer.exe','gateway/caddy.exe','nssm.exe','components/components.json')) {
   $checks+=@{name=$file;ready=(Test-Path -LiteralPath (Join-Path $PackageRoot $file))}
 }
 $checks+=@{name='Windows x64';ready=[Environment]::Is64BitOperatingSystem}
 $checks+=@{name='Existing EpicVM host';ready=$true;existing=[bool](Get-Service EpicVMHostRuntime -ErrorAction SilentlyContinue)}
 @{ok=$true;checks=$checks;ready=@($checks|Where-Object {-not $_.ready}).Count -eq 0;streamVerified=$false} | ConvertTo-Json -Depth 5
 return
}
$setupMutex=New-Object Threading.Mutex($false,'Global\EpicVM.FreshSetup')
if(-not $setupMutex.WaitOne(0)){$setupMutex.Dispose();throw 'Another host setup operation is already running.'}
try {
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {throw 'Administrator access is required to prepare protected setup state.'}
if(-not (Test-Path -LiteralPath $python)) {throw 'The fresh-host package must include its Python runtime.'}
$StateRoot=[IO.Path]::GetFullPath($StateRoot)
foreach($candidate in @($StateRoot,[IO.Path]::GetFullPath($PackageRoot))) {
 $walk=$candidate
 while($walk) {
  if(Test-Path -LiteralPath $walk) {if((Get-Item -LiteralPath $walk).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Setup paths cannot traverse links.'}}
  $parent=Split-Path -Parent $walk
  if($parent -eq $walk){break}
  $walk=$parent
 }
}

if($StateRoot -ne 'C:\ProgramData\EpicVM\fresh-setup') {throw 'Use the protected fresh-setup directory.'}
if(Test-Path -LiteralPath $StateRoot) {
 if((Get-Item -LiteralPath $StateRoot).Attributes -band [IO.FileAttributes]::ReparsePoint) {throw 'Setup directory cannot be a link.'}
} else {
 New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
}
& icacls.exe $StateRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if($LASTEXITCODE -ne 0) {throw 'Could not protect setup credentials.'}
switch($Action) {
 'Status' { & $python $engine status --root $StateRoot }
 'CheckConnectivity' { & $python $engine connectivity --root $StateRoot; if($LASTEXITCODE -ne 0){throw 'Connectivity is incomplete. Check hostname DNS, port forwarding and certificates.'} }
 'InstallGateway' { & (Join-Path $PSScriptRoot 'Install-EpicVMFreshRuntime.ps1') -PackageRoot $PackageRoot -SetupRoot $StateRoot -GatewayOnly }
 'InstallRuntime' { & (Join-Path $PSScriptRoot 'Install-EpicVMFreshRuntime.ps1') -PackageRoot $PackageRoot -SetupRoot $StateRoot }
 'ConfigureLan' {
   $inputData=Get-Content -LiteralPath $InputFile -Raw|ConvertFrom-Json
   & (Join-Path $PSScriptRoot 'Configure-EpicVMFreshLan.ps1') -PackageRoot $PackageRoot -SetupRoot $StateRoot -Address $inputData.address
 }
 'Prepare' {
   $c=Get-Content -LiteralPath $InputFile -Raw | ConvertFrom-Json
   if((Get-Service EpicVMHostRuntime -ErrorAction SilentlyContinue) -and -not(Test-Path (Join-Path $StateRoot 'EpicVMHostRuntime.service.json'))) {throw 'An existing EpicVM host was found. Use its update/repair path; fresh setup will not replace it.'}
   if($c.dataRoot){& (Join-Path $PSScriptRoot 'Initialize-EpicVMStorage.ps1') -DataRoot $c.dataRoot -HostId $c.hostId -ValidateOnly}
   & $python $engine prepare --root $StateRoot --configuration $InputFile
   if($LASTEXITCODE -ne 0) {throw 'Could not prepare setup state.'}
   $saved=Get-Content (Join-Path $StateRoot 'setup-state.json') -Raw|ConvertFrom-Json
   if($saved.configuration.dataRoot){& (Join-Path $PSScriptRoot 'Initialize-EpicVMStorage.ps1') -DataRoot $saved.configuration.dataRoot -HostId $saved.configuration.hostId}
   Write-Output '{"ok":true,"message":"Private setup and data location saved. Continue installing components."}'

 }
 'Enroll' { & $python $engine enroll --root $StateRoot; if($LASTEXITCODE -ne 0) {throw 'Enrollment could not start.'} }
 'Poll' { & $python $engine poll --root $StateRoot; if($LASTEXITCODE -ne 0) {throw 'Could not check enrollment.'} }
 'InstallPortal' {
   $c=Get-Content (Join-Path $StateRoot 'setup-state.json') -Raw | ConvertFrom-Json
   if($c.configuration.layout -ne 'same-pc') {throw 'Portal installation is only for same-PC setup.'}
   & $python -c 'import flask,cryptography,waitress'
   if($LASTEXITCODE -ne 0) {throw 'Portal Python dependencies are missing from the package.'}
   if((Get-Service EpicVMPortal -ErrorAction SilentlyContinue) -and -not(Test-Path (Join-Path $StateRoot 'EpicVMPortal.service.json'))) {throw 'Portal already installed. Use its repair/update path.'}
   $safePackage=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')+'\'
   $programRoot=[IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')+'\'
   if(-not $safePackage.StartsWith($programRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'Install a verified package under Program Files before registering privileged services.'}
   $unsafe=@((Get-Acl -LiteralPath $PackageRoot).Access | Where-Object { $_.AccessControlType -eq 'Allow' -and $_.IdentityReference -match 'Users$|Everyone$|Authenticated Users$' -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) })
   if($unsafe.Count){throw 'Portal package is writable by ordinary users.'}
   if((Get-NetTCPConnection -LocalPort 5050 -State Listen -ErrorAction SilentlyContinue) -and -not(Test-Path (Join-Path $StateRoot 'EpicVMPortal.service.json'))){throw 'Portal port 5050 is already occupied.'}
   $nssm=Join-Path $PackageRoot 'nssm.exe'
   if(-not (Test-Path $nssm)) {throw 'Portal service wrapper missing from package.'}
   Import-Module (Join-Path $PSScriptRoot 'FreshHostServices.psm1') -Force
   Install-EpicVMSetupService -Name EpicVMPortal -Executable $python -Parameters ('"'+(Join-Path $PackageRoot 'scripts\portal_service.py')+'" "'+$StateRoot+'" "'+$PackageRoot+'"') -Directory $PackageRoot -PackageRoot $PackageRoot -SetupRoot $StateRoot
   Write-Output '{"ok":true,"message":"Portal service installed on loopback port 5050. Configure HTTPS before enrollment. Streaming is not yet verified."}'
 }
}

} finally {$setupMutex.ReleaseMutex();$setupMutex.Dispose()}

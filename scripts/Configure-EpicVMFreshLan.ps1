#Requires -RunAsAdministrator
param([string]$PackageRoot='C:\Program Files\EpicVM',[string]$SetupRoot='C:\ProgramData\EpicVM\fresh-setup',[string]$Address)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'HostStorage.ps1')
Import-Module (Join-Path $PSScriptRoot 'HostComponents.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'FreshHostServices.psm1') -Force
$PackageRoot=Assert-EpicVMComponentPath $PackageRoot
$SetupRoot=Assert-EpicVMComponentPath $SetupRoot
if($PackageRoot.TrimEnd('\') -ine 'C:\Program Files\EpicVM' -or $SetupRoot.TrimEnd('\') -ine 'C:\ProgramData\EpicVM\fresh-setup'){throw 'Use the installed verified package and protected setup location.'}
$unsafe=@((Get-Acl -LiteralPath $PackageRoot).Access|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference -match 'Users$|Everyone$|Authenticated Users$' -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write)})
if($unsafe.Count){throw 'Package is writable by ordinary users.'}
$root=Assert-EpicVMComponentPath (Join-Path (Get-EpicVMDataRoot) 'host-runtime')
$state=Get-Content (Join-Path $SetupRoot 'setup-state.json') -Raw|ConvertFrom-Json
if(-not(Test-Path -LiteralPath (Join-Path $root 'host-runtime.json'))){throw 'Install the host runtime before local network setup.'}
if((Test-Path (Join-Path $root 'local-gateway.json'))){
 $existing=Get-Content (Join-Path $root 'local-gateway.json') -Raw|ConvertFrom-Json
 if($existing.mode -ne 'local-ca'){throw 'Your existing domain-backed LAN gateway was retained. Fresh LAN setup will not replace it.'}
}
if(-not $Address){
 $addresses=@(Get-NetIPConfiguration|Where-Object {$_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up'}|ForEach-Object {$_.IPv4Address.IPAddress}|Where-Object {$_ -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'})
 if($addresses.Count -ne 1){throw 'More than one home-network address was found. Enter the host LAN address in setup and retry.'}
 $Address=$addresses[0]
}
if(-not(Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Address -ErrorAction SilentlyContinue)){throw 'This LAN address is not assigned to the host.'}
foreach($port in @(8443,8444,2020)){
 if((Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) -and -not(Test-Path (Join-Path $SetupRoot 'EpicVMLocalGateway.service.json'))){throw "Local gateway port $port is occupied. Existing listeners were preserved."}
}
$python=Join-Path $PackageRoot 'python/python.exe'
$binary=Join-Path $root 'caddy-lan.exe'
if(Test-Path -LiteralPath $binary){if((Get-FileHash $binary).Hash -ne (Get-FileHash (Join-Path $PackageRoot 'gateway/caddy.exe')).Hash){throw 'Local gateway binary differs from the verified package. Repair is required.'}}else{Copy-Item -LiteralPath (Join-Path $PackageRoot 'gateway/caddy.exe') -Destination $binary}
& $python (Join-Path $PackageRoot 'scripts/local_lan.py') configure --root $root --address $Address --portal $state.configuration.portalOrigin
if($LASTEXITCODE -ne 0){throw 'Local HTTPS configuration failed.'}
$validation=Start-Process -FilePath $binary -ArgumentList ('validate --config "'+(Join-Path $root 'Caddyfile.lan')+'"') -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $root 'lan-validation.out.log') -RedirectStandardError (Join-Path $root 'lan-validation.err.log')
if($validation.ExitCode -ne 0){throw 'Local HTTPS configuration did not validate.'}
Install-EpicVMSetupService -Name EpicVMLocalGateway -Executable $binary -Parameters ('run --config "'+(Join-Path $root 'Caddyfile.lan')+'"') -Directory $root -PackageRoot $PackageRoot -SetupRoot $SetupRoot
$reload=Start-Process -FilePath $binary -ArgumentList ('reload --address 127.0.0.1:2020 --config "'+(Join-Path $root 'Caddyfile.lan')+'"') -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $root 'lan-reload.out.log') -RedirectStandardError (Join-Path $root 'lan-reload.err.log')
if($reload.ExitCode -ne 0){throw 'Local gateway reload failed. Retry local setup; normal hosting is independent.'}
foreach($port in @(8443,8444)){
 $rule="EpicVM Local Setup $port"
 if(-not(Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)){
  New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Program $binary -Protocol TCP -LocalPort $port -LocalAddress $Address -RemoteAddress LocalSubnet|Out-Null
 } else {
  Get-NetFirewallRule -DisplayName $rule|Get-NetFirewallAddressFilter|Set-NetFirewallAddressFilter -LocalAddress $Address -RemoteAddress LocalSubnet|Out-Null
 }
}
$ready=$false
for($attempt=0;$attempt -lt 30;$attempt++){if(Test-Path (Join-Path $root 'lan-certificates/pki/authorities/local/root.crt')){$ready=$true;break};Start-Sleep -Milliseconds 500}
if(-not $ready){throw 'Local certificate is still being generated. Retry this step.'}
$export=& $python (Join-Path $PackageRoot 'scripts/local_lan.py') export --root $root
if($LASTEXITCODE -ne 0){throw 'Could not export the public trust certificate.'}
$state|Add-Member -Force -NotePropertyName lanConfigured -NotePropertyValue $true
[IO.File]::WriteAllText((Join-Path $SetupRoot 'setup-state.json'),($state|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

Write-Output $export

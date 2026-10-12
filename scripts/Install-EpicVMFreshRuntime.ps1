#Requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$PackageRoot,[string]$SetupRoot='C:\ProgramData\EpicVM\fresh-setup',[switch]$GatewayOnly)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HostComponents.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'FreshHostServices.psm1') -Force
$PackageRoot=Assert-EpicVMComponentPath $PackageRoot
$SetupRoot=Assert-EpicVMComponentPath $SetupRoot
. (Join-Path $PSScriptRoot 'HostStorage.ps1')
$root=Join-Path (Get-EpicVMDataRoot) 'host-runtime'
Assert-EpicVMComponentPath $root | Out-Null
if($PackageRoot.TrimEnd('\') -ine 'C:\Program Files\EpicVM'){throw 'Install the verified package under Program Files first.'}
$unsafe=@((Get-Acl -LiteralPath $PackageRoot).Access|Where-Object {$_.AccessControlType -eq 'Allow' -and $_.IdentityReference -match 'Users$|Everyone$|Authenticated Users$' -and ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write)})
if($unsafe.Count){throw 'Host package is writable by ordinary users.'}
if((Get-Service EpicVMHostRuntime -ErrorAction SilentlyContinue) -and -not(Test-Path (Join-Path $SetupRoot 'EpicVMHostRuntime.service.json'))){throw 'Existing host detected. Fresh setup will not replace your running installation.'}
if((Get-Service EpicVMRemoteAgent -ErrorAction SilentlyContinue) -and -not(Test-Path (Join-Path $SetupRoot 'EpicVMRemoteAgent.service.json'))){throw 'A preexisting host agent was found. Fresh setup will not modify this installation.'}
$python=Join-Path $PackageRoot 'python/python.exe'
$nssm=Join-Path $PackageRoot 'nssm.exe'
foreach($file in @('python/python.exe','nssm.exe','gateway/caddy.exe','scripts/fresh_host_runtime.py','scripts/direct_stream_auth.py','viewer/web-server.exe','viewer/streamer.exe','viewer/static/stream.js','control/EpicVM.Control.exe','pwsh7/pwsh.exe')){
 if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $file))){throw ('Package is missing '+$file)}
}
& $python -c 'import psutil, flask, cryptography, waitress'
if($LASTEXITCODE -ne 0){throw 'Bundled Python runtime is incomplete.'}
$state=Get-Content (Join-Path $SetupRoot 'setup-state.json') -Raw|ConvertFrom-Json
$private=Get-Content (Join-Path $SetupRoot 'setup-private.json') -Raw|ConvertFrom-Json
if(-not $GatewayOnly){
 foreach($entry in @(@{port=8765;service='EpicVMRemoteAgent'},@{port=8090;service='EpicVMHostRuntime'})){
  if((Get-NetTCPConnection -LocalPort $entry.port -State Listen -ErrorAction SilentlyContinue) -and -not(Test-Path (Join-Path $SetupRoot ($entry.service+'.service.json')))){throw ('Management port '+$entry.port+' is occupied. Resolve the conflict before retrying.')}
 }
}
foreach($port in @(80,443,2019)){
 if((Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue) -and -not(Test-Path (Join-Path $SetupRoot 'EpicVMGateway.service.json'))){throw "Port $port is in use. Configure the existing reverse proxy before retrying."}
}
New-Item -ItemType Directory -Force -Path $root | Out-Null
& icacls.exe $root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not protect runtime state.'}
if($GatewayOnly){
 & $python (Join-Path $PackageRoot 'scripts/fresh_host_runtime.py') $SetupRoot $root --gateway-only
} else {
 if(-not $state.operatorSid){throw 'Choose the local operator account during setup.'}
 Get-LocalUser -SID $state.operatorSid -ErrorAction Stop | Out-Null
 & $python (Join-Path $PackageRoot 'scripts/fresh_host_runtime.py') $SetupRoot $root $PackageRoot $state.operatorSid
}
if($LASTEXITCODE -ne 0){throw 'Could not generate fresh runtime state. Check enrollment and retry.'}
New-Item -ItemType Directory -Force -Path (Join-Path $root 'profile'),(Join-Path $root 'logs')|Out-Null
$caddy=Join-Path $PackageRoot 'gateway/caddy.exe'
& $caddy validate --config (Join-Path $root 'Caddyfile') 2>$null | Out-Null
if($LASTEXITCODE -ne 0){throw 'HTTPS configuration did not validate.'}
Install-EpicVMSetupService -Name EpicVMGateway -Executable $caddy -Parameters ('run --config "'+(Join-Path $root 'Caddyfile')+'"') -Directory $root -PackageRoot $PackageRoot -SetupRoot $SetupRoot -Environment ('APPDATA='+(Join-Path $root 'profile'))
foreach($port in @(80,443)){
 $rule="EpicVM Setup HTTPS $port"
 if(-not(Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)){New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Program $caddy -Protocol TCP -LocalPort $port | Out-Null}
}
if($GatewayOnly){Write-Output '{"ok":true,"message":"HTTPS gateway started. Point your hostnames here and forward TCP 80/443 if needed, then check connectivity."}';return}
$adapter='C:\ProgramData\EpicVM\agent'
Assert-EpicVMComponentPath $adapter | Out-Null
if((Get-Service EpicVMRemoteAgent -ErrorAction SilentlyContinue) -and -not(Test-Path (Join-Path $SetupRoot 'EpicVMRemoteAgent.service.json'))){throw 'A preexisting host agent was found. Use repair instead of fresh setup.'}
New-Item -ItemType Directory -Force -Path $adapter | Out-Null
& icacls.exe $adapter /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not protect agent credentials.'}
Copy-Item -Path (Join-Path $PackageRoot 'remote_agent/windows/*') -Destination $adapter -Recurse -Force
Copy-Item -LiteralPath (Join-Path $PackageRoot 'scripts/HostStorage.ps1') -Destination (Join-Path $adapter 'HostStorage.ps1') -Force
[IO.File]::WriteAllText((Join-Path $adapter 'agent.txt'),$private.agentToken,[Text.UTF8Encoding]::new($false))
$address=([uri]$state.configuration.agentUrl).Host
$agentConfig=@{Provider='MultiSeat';BindAddress=$address;Port=8765;TokenFile=(Join-Path $adapter 'agent.txt');ConfigFile=(Join-Path $adapter 'config.json')}
[IO.File]::WriteAllText((Join-Path $adapter 'config.json'),($agentConfig|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$pwsh=Join-Path $PackageRoot 'pwsh7/pwsh.exe'
Install-EpicVMSetupService -Name EpicVMRemoteAgent -Executable $pwsh -Parameters ('-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $adapter 'EpicVM.Agent.ps1')+'" -ConfigPath "'+(Join-Path $adapter 'config.json')+'"') -Directory $adapter -PackageRoot $PackageRoot -SetupRoot $SetupRoot
if($address -ne '127.0.0.1' -and -not(Get-NetFirewallRule -DisplayName 'EpicVM Setup Agent Tailscale' -ErrorAction SilentlyContinue)){
 New-NetFirewallRule -DisplayName 'EpicVM Setup Agent Tailscale' -Direction Inbound -Action Allow -Program $pwsh -Protocol TCP -LocalAddress $address -LocalPort 8765 -RemoteAddress '100.64.0.0/10' | Out-Null
}
if(-not(Get-NetFirewallRule -DisplayName 'EpicVM Direct Streams Media UDP 40900-41199' -ErrorAction SilentlyContinue)){
 New-NetFirewallRule -DisplayName 'EpicVM Direct Streams Media UDP 40900-41199' -Direction Inbound -Action Allow -Program (Join-Path $PackageRoot 'viewer/web-server.exe') -Protocol UDP -LocalPort '40900-41199' | Out-Null
}
Install-EpicVMSetupService -Name EpicVMHostRuntime -Executable $python -Parameters ('"'+(Join-Path $PackageRoot 'scripts/host_runtime.py')+'"') -Directory (Join-Path $PackageRoot 'scripts') -PackageRoot $PackageRoot -SetupRoot $SetupRoot -Environment ('EPICVM_HOST_RUNTIME_CONFIG='+(Join-Path $root 'host-runtime.json'))
Install-EpicVMSetupService -Name EpicVMHostControl -Executable (Join-Path $PackageRoot 'control/EpicVM.Control.exe') -Parameters '' -Directory $PackageRoot -PackageRoot $PackageRoot -SetupRoot $SetupRoot
$shortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'EpicVM Agent.lnk'
$shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($shortcut);$link.TargetPath=Join-Path $PackageRoot 'ui/EpicVM.Agent.exe';$link.Save()
$state.stage='runtime-installed'
[IO.File]::WriteAllText((Join-Path $SetupRoot 'setup-state.json'),($state|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
Write-Output '{"ok":true,"message":"Boot services installed. Complete the real desktop connection check before enabling friend access.","streamVerified":false}'

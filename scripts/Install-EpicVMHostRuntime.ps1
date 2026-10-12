#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [Parameter(Mandatory)][string]$SourceState,
    [Parameter(Mandatory)][string]$OperatorName,
    [Parameter(Mandatory)][string]$HostId,
    [Parameter(Mandatory)][string]$PortalOrigin,
    [Parameter(Mandatory)][string]$PublicOrigin,
    [Parameter(Mandatory)][string]$CaddyExecutable,
    [Parameter(Mandatory)][string]$CaddyConfiguration,
    [Parameter(Mandatory)][string]$CaddyStorage,
    [Parameter(Mandatory)][string]$ViewerPackage,
    [Parameter(Mandatory)][string]$SyncTokenFile,
    [string]$InstallRoot = 'C:\Program Files\EpicVM',
    [string]$StateRoot = 'C:\ProgramData\EpicVM\host-runtime'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'HostStorage.ps1')
if(-not $PSBoundParameters.ContainsKey('StateRoot')){$StateRoot=Join-Path (Get-EpicVMDataRoot) 'host-runtime'}
foreach ($origin in @($PortalOrigin,$PublicOrigin)) { $uri=[uri]$origin; if($uri.Scheme -ne 'https' -or $uri.AbsolutePath -ne '/' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { throw 'Use HTTPS origins without paths or credentials.' } }
if($HostId -notmatch '^[a-z0-9][a-z0-9._-]{0,62}$'){throw 'Invalid host ID.'}
foreach($required in @((Join-Path $PackageRoot 'python/python.exe'),(Join-Path $PackageRoot 'control/EpicVM.Control.exe'),(Join-Path $PackageRoot 'ui/EpicVM.Agent.exe'),(Join-Path $SourceState 'signing.key'),$CaddyExecutable,$CaddyConfiguration,$SyncTokenFile,(Join-Path $ViewerPackage 'web-server.exe'))){if(-not(Test-Path -LiteralPath $required)){throw "Missing required runtime input: $required"}}
if(Get-Service EpicVMHostRuntime -ErrorAction SilentlyContinue){throw 'Runtime already installed. Use a controlled upgrade instead of overwriting live state.'}
$operatorSid=(Get-LocalUser $OperatorName).SID.Value
New-Item -ItemType Directory -Force -Path $StateRoot,$InstallRoot | Out-Null
& icacls.exe $StateRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
if($LASTEXITCODE -ne 0){throw 'State ACL installation failed.'}
Copy-Item -Path (Join-Path $PackageRoot '*') -Destination $InstallRoot -Recurse -Force
$streamSources=Join-Path $PSScriptRoot '.'
New-Item -ItemType Directory -Force -Path (Join-Path $InstallRoot 'scripts'),(Join-Path $InstallRoot 'viewer'),(Join-Path $InstallRoot 'gateway') | Out-Null
foreach($file in @('host_runtime.py','manage_host_runtime.py','supervise_host_direct_streams.py','provision_direct_stream.py','host_stream_gateway.py','write_direct_stream_caddy.py','Start-EpicVMLocalGateway.ps1','stream_recovery.js','stream_network.js')){
    Copy-Item -LiteralPath (Join-Path $streamSources $file) -Destination (Join-Path $InstallRoot 'scripts') -Force
}
Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'dashboard/direct_stream_auth.py') -Destination (Join-Path $InstallRoot 'scripts/direct_stream_auth.py') -Force
Get-ChildItem -LiteralPath $ViewerPackage | Where-Object {$_.Name -notin @('server','logs')} | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $InstallRoot 'viewer') -Recurse -Force}
Copy-Item -LiteralPath $CaddyExecutable -Destination (Join-Path $InstallRoot 'gateway/caddy.exe') -Force
Copy-Item -Path (Join-Path $SourceState '*') -Destination $StateRoot -Recurse -Force
# SQLite backup produces a consistent snapshot even with the old gateway live.
$backupCode='import sqlite3,sys; source=sqlite3.connect(sys.argv[1]); target=sqlite3.connect(sys.argv[2]); source.backup(target); target.close(); source.close()'
& (Join-Path $InstallRoot 'python/python.exe') -c $backupCode (Join-Path $SourceState 'nonces.sqlite3') (Join-Path $StateRoot 'nonces.sqlite3')
if($LASTEXITCODE -ne 0){throw 'Private stream-session snapshot failed.'}
# Explicit runtime modules override any legacy copies imported with the state.
Copy-Item -LiteralPath (Join-Path $InstallRoot 'scripts/host_stream_gateway.py') -Destination $StateRoot -Force
Copy-Item -LiteralPath (Join-Path $InstallRoot 'scripts/direct_stream_auth.py') -Destination $StateRoot -Force
New-Item -ItemType Directory -Force -Path (Join-Path $StateRoot 'profile/Caddy'),(Join-Path $StateRoot 'logs') | Out-Null
if(Test-Path -LiteralPath $CaddyStorage){Copy-Item -Path (Join-Path $CaddyStorage '*') -Destination (Join-Path $StateRoot 'profile/Caddy') -Recurse -Force}
$oldSlash=$SourceState.Replace('\','/');$newSlash=$StateRoot.Replace('\','/')
$config=Get-Content -LiteralPath $CaddyConfiguration -Raw
$config=$config.Replace($oldSlash,$newSlash).Replace($SourceState,$StateRoot)
$config=$config -replace 'output file [^\r\n]+?caddy\.log', ('output file '+(Join-Path $StateRoot 'logs/caddy.log').Replace('\','/'))
[IO.File]::WriteAllText((Join-Path $StateRoot 'Caddyfile'),$config)
$lanConfig=Join-Path $StateRoot 'Caddyfile.lan'
if(Test-Path -LiteralPath $lanConfig){$lan=Get-Content -LiteralPath $lanConfig -Raw;$lan=$lan.Replace($oldSlash,$newSlash).Replace($SourceState,$StateRoot);[IO.File]::WriteAllText($lanConfig,$lan)}
Copy-Item -LiteralPath $SyncTokenFile -Destination (Join-Path $StateRoot 'sync.token') -Force
$runtime=@{hostId=$HostId;portalOrigin=$PortalOrigin.TrimEnd('/');publicOrigin=$PublicOrigin.TrimEnd('/');stateRoot=$StateRoot;syncTokenFile=(Join-Path $StateRoot 'sync.token');pythonExe=(Join-Path $InstallRoot 'python/python.exe');scriptsRoot=(Join-Path $InstallRoot 'scripts');viewerPackage=(Join-Path $InstallRoot 'viewer');caddyExe=(Join-Path $InstallRoot 'gateway/caddy.exe');caddyConfig=(Join-Path $StateRoot 'Caddyfile')}
[IO.File]::WriteAllText((Join-Path $StateRoot 'host-runtime.json'),($runtime|ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $StateRoot 'operator.sid'),$operatorSid)
foreach($marker in @('.caddy-applied','.lan-caddy-applied','.manifest-published')){ $path=Join-Path $StateRoot $marker;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path} }
$nssm=Join-Path $InstallRoot 'nssm.exe'
if(-not(Test-Path -LiteralPath $nssm)){Copy-Item -LiteralPath 'C:\ProgramData\EpicVM\agent\nssm.exe' -Destination $nssm}
& $nssm install EpicVMHostRuntime $runtime.pythonExe ('"'+(Join-Path $InstallRoot 'scripts/host_runtime.py')+'"') | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\EpicVMHostRuntime' -Name ImagePath -Value ('"'+$nssm+'"')
Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\EpicVMHostRuntime\Parameters' -Name AppParameters -Value ('"'+(Join-Path $InstallRoot 'scripts/host_runtime.py')+'"')
& $nssm set EpicVMHostRuntime AppDirectory $runtime.scriptsRoot | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
& $nssm set EpicVMHostRuntime AppEnvironmentExtra ('EPICVM_HOST_RUNTIME_CONFIG='+(Join-Path $StateRoot 'host-runtime.json')) | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
& $nssm set EpicVMHostRuntime AppStdout (Join-Path $StateRoot 'logs/runtime.out.log') | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
& $nssm set EpicVMHostRuntime AppStderr (Join-Path $StateRoot 'logs/runtime.err.log') | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
& $nssm set EpicVMHostRuntime AppRotateFiles 1 | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
& $nssm set EpicVMHostRuntime AppRotateBytes 10485760 | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
& $nssm set EpicVMHostRuntime AppRestartDelay 5000 | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
if($LASTEXITCODE -ne 0){throw 'Runtime process settings could not be configured.'}
& sc.exe config EpicVMHostRuntime obj= 'NT SERVICE\EpicVMHostRuntime' start= auto | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
if($LASTEXITCODE -ne 0){throw 'Runtime service identity could not be configured.'}
& sc.exe sidtype EpicVMHostRuntime unrestricted | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
& icacls.exe $StateRoot /grant 'NT SERVICE\EpicVMHostRuntime:(OI)(CI)M' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
if($LASTEXITCODE -ne 0){throw 'Runtime state permissions failed.'}
& icacls.exe $InstallRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' 'NT SERVICE\EpicVMHostRuntime:(OI)(CI)RX' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
New-Service -Name EpicVMHostControl -BinaryPathName ('"'+(Join-Path $InstallRoot 'control/EpicVM.Control.exe')+'"') -StartupType Automatic -DisplayName 'EpicVM Host Control' | Out-Null
& sc.exe failure EpicVMHostRuntime reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
& sc.exe failure EpicVMHostControl reset= 86400 actions= restart/5000/restart/15000/restart/60000 | Out-Null
if($LASTEXITCODE -ne 0){throw 'Windows service or permission configuration failed.'}
Start-Service EpicVMHostControl
$adapterRoot='C:\ProgramData\EpicVM\agent'
if(-not(Test-Path -LiteralPath (Join-Path $adapterRoot 'HostGaming.ps1'))){throw 'Existing Windows host adapter is required.'}
$backupRoot=Join-Path $StateRoot 'backups/host-adapter'
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
foreach($file in @('HostGaming.ps1','HostingPolicy.ps1')) {
    $target=Join-Path $adapterRoot $file
    if(Test-Path -LiteralPath $target){Copy-Item -LiteralPath $target -Destination $backupRoot -Force}
    Copy-Item -LiteralPath (Join-Path $PackageRoot ('remote_agent/windows/'+$file)) -Destination $target -Force
}
Restart-Service EpicVMRemoteAgent
foreach($rule in @(
    @{Name='EpicVM machine viewer media';Program=(Join-Path $InstallRoot 'viewer/web-server.exe');Protocol='UDP';LocalPort='40900-41199'},
    @{Name='EpicVM machine HTTPS gateway';Program=(Join-Path $InstallRoot 'gateway/caddy.exe');Protocol='TCP';LocalPort='443'}
)) {
    if(-not(Get-NetFirewallRule -DisplayName $rule.Name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $rule.Name -Direction Inbound -Action Allow -Program $rule.Program -Protocol $rule.Protocol -LocalPort $rule.LocalPort | Out-Null
    }
}
$localSettings=Join-Path $StateRoot 'local-gateway.json'
if(Test-Path -LiteralPath $localSettings) {
    $local=Get-Content -LiteralPath $localSettings -Raw | ConvertFrom-Json
    if($local.enabled) {
        $origin=[uri]$local.origin
        $address=[ipaddress]$local.address
        $lanBinary=Join-Path $StateRoot 'caddy-lan.exe'
        if($origin.Scheme -ne 'https' -or -not(Test-Path -LiteralPath $lanBinary)){throw 'Invalid LAN gateway configuration.'}
        # Migration changes the executable path. Keep the LAN interface/subnet
        # restrictions while replacing the obsolete user-profile allow rule.
        $lanRule=Get-NetFirewallRule -DisplayName 'EpicVM Local Gateway HTTPS' -ErrorAction SilentlyContinue
        if($lanRule) {
            $lanRule | Set-NetFirewallRule -Enabled True -Direction Inbound -Action Allow -Profile Any
            $lanRule | Get-NetFirewallApplicationFilter | Set-NetFirewallApplicationFilter -Program $lanBinary
            $lanRule | Get-NetFirewallPortFilter | Set-NetFirewallPortFilter -Protocol TCP -LocalPort $origin.Port
            $lanRule | Get-NetFirewallAddressFilter | Set-NetFirewallAddressFilter -LocalAddress $address.IPAddressToString -RemoteAddress LocalSubnet
        } else {
            New-NetFirewallRule -DisplayName 'EpicVM Local Gateway HTTPS' -Direction Inbound -Action Allow -Program $lanBinary -Protocol TCP -LocalPort $origin.Port -LocalAddress $address.IPAddressToString -RemoteAddress LocalSubnet -Profile Any | Out-Null
        }
    }
}
$shortcut=Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'EpicVM Agent.lnk'
$shell=New-Object -ComObject WScript.Shell;$link=$shell.CreateShortcut($shortcut);$link.TargetPath=Join-Path $InstallRoot 'ui/EpicVM.Agent.exe';$link.Save()
Write-Output 'Machine runtime installed. Control service is running; perform the controlled listener handoff before starting EpicVMHostRuntime.'

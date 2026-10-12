[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$ConfigurationFile,[string]$PackageRoot=(Split-Path $PSScriptRoot),[switch]$CheckOnly)
$ErrorActionPreference='Stop'
$config=Get-Content -LiteralPath $ConfigurationFile -Raw | ConvertFrom-Json
foreach($key in @('operatorName','hostId','portalOrigin','publicOrigin','stateBundle')){if(-not $config.$key){throw ('Missing setup setting: '+$key)}}
$bundle=[IO.Path]::GetFullPath($config.stateBundle)
$arguments=@{
    PackageRoot=[IO.Path]::GetFullPath($PackageRoot);SourceState=$bundle;OperatorName=$config.operatorName;HostId=$config.hostId;
    PortalOrigin=$config.portalOrigin;PublicOrigin=$config.publicOrigin;CaddyExecutable=(Join-Path $PackageRoot 'gateway/caddy.exe');
    CaddyConfiguration=(Join-Path $bundle 'Caddyfile');CaddyStorage=(Join-Path $bundle 'profile/Caddy');
    ViewerPackage=(Join-Path $PackageRoot 'viewer');SyncTokenFile=(Join-Path $bundle 'sync.token')
}
foreach($origin in @($config.portalOrigin,$config.publicOrigin)){$uri=[uri]$origin;if($uri.Scheme -ne 'https' -or $uri.AbsolutePath -ne '/' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment){throw 'Use HTTPS host origins without paths or credentials.'}}
if($config.hostId -notmatch '^[a-z0-9][a-z0-9._-]{0,62}$'){throw 'Invalid host ID.'}
Get-LocalUser -Name $config.operatorName -ErrorAction Stop | Out-Null
foreach($service in @('MultiSeatService','EpicVMRemoteAgent')){if((Get-Service $service -ErrorAction Stop).Status -ne 'Running'){throw ('Start the enrolled host prerequisite: '+$service)}}
if(Get-Service EpicVMHostRuntime -ErrorAction SilentlyContinue){throw 'Host is already installed. Use About & updates in the Agent instead.'}
$required=@('python/python.exe','control/EpicVM.Control.exe','ui/EpicVM.Agent.exe','gateway/caddy.exe','viewer/web-server.exe','scripts/Install-EpicVMHostRuntime.ps1','remote_agent/windows/HostGaming.ps1','remote_agent/windows/HostingPolicy.ps1','dashboard/direct_stream_auth.py')
foreach($path in $required){if(-not(Test-Path -LiteralPath (Join-Path $PackageRoot $path))){throw ('Host package is missing '+$path)}}
foreach($path in @('signing.key','nonces.sqlite3','routes.json','sync.token','Caddyfile','profile/Caddy')){if(-not(Test-Path -LiteralPath (Join-Path $bundle $path))){throw ('Host-specific state bundle is missing '+$path)}}
foreach($path in @('C:\ProgramData\EpicVM\agent\HostGaming.ps1','C:\ProgramData\EpicVM\agent\nssm.exe')){if(-not(Test-Path -LiteralPath $path)){throw 'Complete host enrollment and adapter installation first.'}}
Write-Output 'Setup prerequisites passed. Existing Windows accounts and private state will be preserved.'
if($CheckOnly){return}
if($PSCmdlet.ShouldProcess('This Windows host','Install EpicVM boot runtime and Agent')){
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
    if(-not([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Run setup as administrator after checking prerequisites.'}
    & (Join-Path $PackageRoot 'scripts/Install-EpicVMHostRuntime.ps1') @arguments
}

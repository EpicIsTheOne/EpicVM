[CmdletBinding()]
param([string]$DotNet='dotnet',[Parameter(Mandatory)][string]$PythonRuntime,[Parameter(Mandatory)][string]$OutputDirectory,[string]$GatewayExecutable,[string]$ViewerRuntime,[string]$ComponentBundle,[string]$PowerShellRuntime=$PSHOME,[string]$NssmExecutable,[string]$Version='0.1.0-preview')
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot
if(-not(Test-Path (Join-Path $PythonRuntime 'python.exe'))){throw 'Provide a prepared machine Python runtime with psutil and SQLite.'}
& (Join-Path $PythonRuntime 'python.exe') -c 'import psutil,sqlite3,flask,werkzeug,cryptography,waitress'
if($LASTEXITCODE -ne 0){throw 'Prepare the Python runtime with all pinned portal dependencies before packaging.'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new output directory so old files cannot enter this release.'}
New-Item -ItemType Directory -Force -Path $OutputDirectory,(Join-Path $OutputDirectory 'scripts'),(Join-Path $OutputDirectory 'dashboard') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $OutputDirectory 'python') | Out-Null
Copy-Item -Path (Join-Path $PythonRuntime '*') -Destination (Join-Path $OutputDirectory 'python') -Recurse -Force
& $DotNet publish (Join-Path $repo 'host_app/Control/EpicVM.Control.csproj') -c Release -r win-x64 --self-contained true -o (Join-Path $OutputDirectory 'control') --nologo
if($LASTEXITCODE -ne 0){throw 'Control build failed'}
& $DotNet publish (Join-Path $repo 'host_app/Agent/EpicVM.Agent.csproj') -c Release -r win-x64 --self-contained true -o (Join-Path $OutputDirectory 'ui') --nologo
if($LASTEXITCODE -ne 0){throw 'Agent UI build failed'}
foreach($file in @('Install-EpicVMHostRuntime.ps1','Uninstall-EpicVMHostRuntime.ps1','host_runtime.py','manage_host_runtime.py','supervise_host_direct_streams.py','provision_direct_stream.py','host_stream_gateway.py','write_direct_stream_caddy.py','Start-EpicVMLocalGateway.ps1','stream_recovery.js','stream_network.js')){
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $OutputDirectory 'scripts') -Force
}
foreach($file in @('HostStorage.ps1','Initialize-EpicVMStorage.ps1','Configure-EpicVMFreshLan.ps1','local_lan.py','FreshHostServices.psm1','Install-EpicVMFreshRuntime.ps1','Uninstall-EpicVMFreshServices.ps1','fresh_host_runtime.py','Install-EpicVMFreshPackage.ps1','HostComponents.psm1','Install-EpicVMHostComponents.ps1','fresh_host_setup.py','portal_service.py','initialize_portal.py','Setup-EpicVMFreshHost.ps1','HostUpdates.ps1','Update-EpicVMHost.ps1','Setup-EpicVMHost.ps1','agent_update_wait.py')){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $OutputDirectory 'scripts') -Force}
Copy-Item -LiteralPath (Join-Path $repo 'docs/WINDOWS-HOST-UPDATES.md') -Destination (Join-Path $OutputDirectory 'scripts/WINDOWS-HOST-UPDATES.md') -Force
Copy-Item -LiteralPath (Join-Path $repo 'dashboard/direct_stream_auth.py') -Destination (Join-Path $OutputDirectory 'scripts/direct_stream_auth.py') -Force
Copy-Item -LiteralPath (Join-Path $repo 'dashboard/direct_stream_auth.py') -Destination (Join-Path $OutputDirectory 'dashboard') -Force
New-Item -ItemType Directory -Force -Path (Join-Path $OutputDirectory 'remote_agent/windows') | Out-Null
foreach($file in @('EpicVM.Agent.ps1','HostGaming.ps1','HostingPolicy.ps1','ServiceRuntime.ps1','AgentTransport.ps1','Provisioning.ps1','SharedGames.ps1','SharedGamesWorker.ps1','SharedGamesCodex.ps1')) {
    Copy-Item -LiteralPath (Join-Path $repo ('remote_agent/windows/'+$file)) -Destination (Join-Path $OutputDirectory 'remote_agent/windows') -Force
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'HostStorage.ps1') -Destination (Join-Path $OutputDirectory 'remote_agent/windows')
Copy-Item -LiteralPath (Join-Path $repo 'docs/WINDOWS-HOST-AGENT.md') -Destination (Join-Path $OutputDirectory 'README.md') -Force
if($GatewayExecutable){New-Item -ItemType Directory -Path (Join-Path $OutputDirectory 'gateway') | Out-Null;Copy-Item -LiteralPath $GatewayExecutable -Destination (Join-Path $OutputDirectory 'gateway/caddy.exe')}
if($ViewerRuntime){
    if(-not(Test-Path -LiteralPath (Join-Path $ViewerRuntime 'web-server.exe'))){throw 'Provide a prepared credential-free viewer distribution.'}
    New-Item -ItemType Directory -Path (Join-Path $OutputDirectory 'viewer') | Out-Null
    Get-ChildItem -LiteralPath $ViewerRuntime | Where-Object {$_.Name -notin @('server','logs')} | ForEach-Object {Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $OutputDirectory 'viewer') -Recurse}
}
Write-Output 'Built Windows x64 package without credentials or host state.'

Get-ChildItem -LiteralPath (Join-Path $repo 'dashboard') -File -Filter '*.py' | Copy-Item -Destination (Join-Path $OutputDirectory 'dashboard')
Copy-Item -LiteralPath (Join-Path $repo 'memory_engine') -Destination (Join-Path $OutputDirectory 'memory_engine') -Recurse
New-Item -ItemType Directory -Force -Path (Join-Path $OutputDirectory 'epicvm_web/dist'),(Join-Path $OutputDirectory 'docs') | Out-Null
Copy-Item -Path (Join-Path $repo 'epicvm_web/dist/*') -Destination (Join-Path $OutputDirectory 'epicvm_web/dist') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repo 'docs/FRESH-HOST-SETUP.md') -Destination (Join-Path $OutputDirectory 'docs')
Copy-Item -LiteralPath (Join-Path $repo 'docs/THIRD-PARTY-HOST-COMPONENTS.md') -Destination (Join-Path $OutputDirectory 'docs')

New-Item -ItemType Directory -Force -Path (Join-Path $OutputDirectory 'remote_agent/windows/providers') | Out-Null
Get-ChildItem -LiteralPath (Join-Path $repo 'remote_agent/windows/providers') -File -Filter '*.ps1' | Copy-Item -Destination (Join-Path $OutputDirectory 'remote_agent/windows/providers')

if($ComponentBundle){
 Import-Module (Join-Path $PSScriptRoot 'HostComponents.psm1') -Force
 Test-EpicVMComponentBundle $ComponentBundle | Out-Null
 Copy-Item -LiteralPath $ComponentBundle -Destination (Join-Path $OutputDirectory 'components') -Recurse
}
if(-not(Test-Path (Join-Path $PowerShellRuntime 'pwsh.exe'))){throw 'Provide a complete PowerShell 7 runtime for fresh hosts.'}
New-Item -ItemType Directory -Path (Join-Path $OutputDirectory 'pwsh7')|Out-Null
Copy-Item -Path (Join-Path $PowerShellRuntime '*') -Destination (Join-Path $OutputDirectory 'pwsh7') -Recurse
if(-not $NssmExecutable -or -not(Test-Path $NssmExecutable)){throw 'Provide the verified NSSM executable.'}
Copy-Item -LiteralPath $NssmExecutable -Destination (Join-Path $OutputDirectory 'nssm.exe')
$files=@(Get-ChildItem $OutputDirectory -File -Recurse|ForEach-Object {@{path=$_.FullName.Substring([IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\').Length+1).Replace('\','/');sha256=(Get-FileHash $_.FullName).Hash.ToLowerInvariant()}})
[IO.File]::WriteAllText((Join-Path $OutputDirectory 'fresh-release.json'),(@{schema=1;product='EpicVM Fresh Host';version=$Version;files=$files;releaseStatus='preview';cleanMachineVerified=$false}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))

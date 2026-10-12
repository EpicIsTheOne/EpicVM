[CmdletBinding()]
param(
 [string]$PackageRoot=(Split-Path $PSScriptRoot),
 [switch]$CheckOnly,
 [string]$ResultFile,
 [string]$StateRoot='C:\ProgramData\EpicVM\setup-components'
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HostComponents.psm1') -Force
function Result($value) { $json=$value|ConvertTo-Json -Depth 8;if($ResultFile){[IO.File]::WriteAllText($ResultFile,$json,[Text.UTF8Encoding]::new($false))};Write-Output $json }
$before=@(Get-EpicVMComponentStatus)
if($CheckOnly){Result @{ok=$true;components=$before;ready=@($before|Where-Object {-not $_.ready}).Count -eq 0;streamVerified=$false};return}
if(-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Administrator rights are required to install host components.'}
if(-not [Environment]::Is64BitProcess){throw 'Run the x64 component installer.'}
$StateRoot=Assert-EpicVMComponentPath $StateRoot
if($StateRoot -ne 'C:\ProgramData\EpicVM\setup-components'){throw 'Use the protected component state directory.'}
New-Item -ItemType Directory -Force -Path $StateRoot | Out-Null
& icacls.exe $StateRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not protect component state.'}
$mutex=New-Object Threading.Mutex($false,'Global\EpicVM.ComponentSetup')
if(-not $mutex.WaitOne(0)){throw 'Another component installation is in progress.'}
$state=@{schema=1;runId=[guid]::NewGuid().ToString('N');stage='verifying';steps=@();rebootRequired=$false;updatedAt='';ok=$false}
$checkpoint=Join-Path $StateRoot 'component-status.json'
$created=@();$newService=$false;$wasStopped=@();$rdpBackup=$null;$rdpFirewallCreated=$false
try {
 $bundle=Assert-EpicVMComponentPath (Join-Path $PackageRoot 'components')
 $manifest=Test-EpicVMComponentBundle $bundle
 Write-EpicVMComponentCheckpoint $checkpoint $state
 if(@($before|Where-Object {-not $_.ready}).Count -gt 0 -and (Get-Service MultiSeatService -ErrorAction SilentlyContinue)){
   $busyHealth=Get-EpicVMMultiSeatComponentHealth
   if($busyHealth.seatCount -gt 0){throw 'End active desktops before changing host components.'}
 }
 foreach($id in @('vigem','hidhide','sudovda','apollo','multiseat')){
  $state.stage=$id;Write-EpicVMComponentCheckpoint $checkpoint $state
  $current=@(Get-EpicVMComponentStatus)|Where-Object {$_.id -eq $id}|Select-Object -First 1
  if($current.ready){$state.steps+=@{component=$id;action='kept';detail='Healthy existing component retained'};continue}
  if($id -in @('vigem','hidhide')) {
   $asset=$manifest.components|Where-Object {$_.id -eq $id}|Select-Object -First 1
   $installed=Invoke-EpicVMVerifiedDriverInstaller (Join-Path $bundle ('downloads/'+$asset.file))
   if($installed.rebootRequired){$state.rebootRequired=$true}
  } elseif($id -eq 'sudovda') {
   if($current.present){$state.rebootRequired=$true;$state.steps+=@{component=$id;action='needs-reboot';detail='Existing display driver is not active'};continue}
   $driver=Join-Path $bundle 'sudovda'
   $cert=Join-Path $driver 'sudovda.cer'
   # Certificate bytes and helper publisher were pinned and verified above.
   Import-Certificate -FilePath $cert -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
   Import-Certificate -FilePath $cert -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
   & (Join-Path $driver 'nefconc.exe') --create-device-node --class-name Display --class-guid '4D36E968-E325-11CE-BFC1-08002BE10318' --hardware-id 'root\sudomaker\sudovda' | Out-Null
   if($LASTEXITCODE -ne 0){throw 'Virtual display device creation failed.'}
   & (Join-Path $driver 'nefconc.exe') --install-driver --inf-path (Join-Path $driver 'SudoVDA.inf') | Out-Null
   if($LASTEXITCODE -ne 0){throw 'Virtual display driver installation failed.'}
   $state.rebootRequired=$true
  } elseif($id -eq 'apollo') {
   $dest='C:\Program Files\ApolloVibe'
   if(Test-Path -LiteralPath $dest){throw 'Existing Apollo payload needs repair. It was preserved; no unrelated installation was overwritten.'}
   New-Item -ItemType Directory -Path $dest | Out-Null;$created+=@($dest)
   Copy-Item -Path (Join-Path $bundle 'apollo/*') -Destination $dest -Recurse -Force
  } elseif($id -eq 'multiseat') {
   $service=Get-Service MultiSeatService -ErrorAction SilentlyContinue
   if($service){Start-Service MultiSeatService;$wasStopped+=@('MultiSeatService')}
   else {
    $ts='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
    $tcp=$ts+'\WinStations\RDP-Tcp'
    $rdpBackup=@{deny=(Get-ItemProperty $ts).fDenyTSConnections;nla=(Get-ItemProperty $tcp).UserAuthentication;security=(Get-ItemProperty $tcp).SecurityLayer}
    $state.rdpBefore=$rdpBackup;Write-EpicVMComponentCheckpoint $checkpoint $state
    Set-ItemProperty $ts -Name fDenyTSConnections -Value 0
    Set-ItemProperty $tcp -Name UserAuthentication -Value 0
    Set-ItemProperty $tcp -Name SecurityLayer -Value 2
    if(-not(Get-NetFirewallRule -DisplayName 'EpicVM local-only RDP' -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName 'EpicVM local-only RDP' -Direction Inbound -Action Block -Protocol TCP -LocalPort 3389 -Profile Any | Out-Null
      $rdpFirewallCreated=$true
    }
    $state.rebootRequired=$true
    $dest='C:\Program Files\MultiSeat';$data='C:\ProgramData\MultiSeat'
    if((Test-Path $dest) -or (Test-Path $data)){throw 'Unregistered MultiSeat files already exist. Repair is required; data was preserved.'}
    New-Item -ItemType Directory -Path $dest,$data | Out-Null;$created+=@($dest,$data)
    & icacls.exe $data /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Could not protect MultiSeat state.'}
    Copy-Item -Path (Join-Path $bundle 'multiseat/*') -Destination $dest -Recurse -Force
    $bytes=New-Object byte[] 32;[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $key=[Convert]::ToBase64String($bytes)
    [IO.File]::WriteAllText((Join-Path $data 'api-key.txt'),$key,[Text.UTF8Encoding]::new($false))
    $settings=@{MultiSeat=@{ApiPort=9550;ApiBindLoopbackOnly=$true;ApiKey=$key;CorsOrigins=@();MaxSeats=4;ApolloExePath='C:\Program Files\ApolloVibe\sunshine.exe';AudioMode='PerSession';EnableHidHideCloaking=$false;EnablePadRulePreWrite=$false}}
    [IO.File]::WriteAllText((Join-Path $dest 'appsettings.local.json'),($settings|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    & icacls.exe (Join-Path $dest 'appsettings.local.json') /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Could not protect MultiSeat credentials.'}
    New-Service -Name MultiSeatService -BinaryPathName ('"'+(Join-Path $dest 'MultiSeat.Service.exe')+'"') -StartupType Automatic -DisplayName 'MultiSeat Streaming Service' | Out-Null
    $newService=$true;Start-Service MultiSeatService
   }
  }
  $state.steps+=@{component=$id;action='installed';detail='Pinned component installed'}
  Write-EpicVMComponentCheckpoint $checkpoint $state
 }
 $after=@(Get-EpicVMComponentStatus)
 $missing=@($after|Where-Object {-not $_.ready})
 if($missing.Count -and -not $state.rebootRequired){throw ('Component verification failed: '+(($missing|ForEach-Object {$_.id}) -join ', '))}
 $health=$null
 if(-not $state.rebootRequired){$health=Get-EpicVMMultiSeatComponentHealth;if(-not $health.sudoVdaReady){throw 'MultiSeat does not see its isolation display driver.'}}
 $state.stage=if($state.rebootRequired){'reboot-required'}else{'components-ready'};$state.ok=$true
 $state.components=$after;$state.streamVerified=$false
 if($health){$state.health=$health}
 Write-EpicVMComponentCheckpoint $checkpoint $state;Result $state
} catch {
 $state.stage='failed';$state.error=$_.Exception.Message;$state.partialDriversRetained=$true
 if($newService){Stop-Service MultiSeatService -ErrorAction SilentlyContinue;& sc.exe delete MultiSeatService | Out-Null}
 foreach($path in $created){
  $safe=Assert-EpicVMComponentPath $path
  if($safe -notin @('C:\Program Files\ApolloVibe','C:\Program Files\MultiSeat','C:\ProgramData\MultiSeat')){throw 'Rollback target outside component scope.'}
  if($safe -eq 'C:\ProgramData\MultiSeat'){continue}
  if(Test-Path -LiteralPath $safe){Remove-Item -LiteralPath $safe -Recurse -Force}
 }
 if($rdpBackup){
  $ts='HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server';$tcp=$ts+'\WinStations\RDP-Tcp'
  Set-ItemProperty $ts -Name fDenyTSConnections -Value $rdpBackup.deny
  Set-ItemProperty $tcp -Name UserAuthentication -Value $rdpBackup.nla
  Set-ItemProperty $tcp -Name SecurityLayer -Value $rdpBackup.security
 }
 if($rdpFirewallCreated){Remove-NetFirewallRule -DisplayName 'EpicVM local-only RDP'}
 foreach($name in $wasStopped){Stop-Service $name -ErrorAction SilentlyContinue}
 # Shared driver packages remain installed on failure, allowing safe retry.
 Write-EpicVMComponentCheckpoint $checkpoint $state;Result $state;throw
} finally {$mutex.ReleaseMutex();$mutex.Dispose()}

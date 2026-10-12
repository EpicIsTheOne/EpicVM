Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Assert-EpicVMComponentPath([string]$Path) {
 $full=[IO.Path]::GetFullPath($Path)
 $walk=$full
 while($walk) {
  $item=Get-Item -LiteralPath $walk -Force -ErrorAction SilentlyContinue
  if($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Component paths cannot traverse links or junctions.'}
  $parent=Split-Path -Parent $walk;if($parent -eq $walk){break};$walk=$parent
 }
 return $full
}
function Read-EpicVMComponentLock([string]$Path) {
 if((Get-FileHash -LiteralPath $Path).Hash -ne '80DEAA2B99DD5F4C4A35584DF6CE7826FDA6862926E52FCA6E1DD5ACD74730AA'){throw 'Component lock differs from the supported release.'}
 $lock=Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
 if($lock.schema -ne 1 -or $lock.architecture -ne 'x64'){throw 'Unsupported component lock.'}
 $allowed=@('multiseat','apollo','vigem','hidhide','sudovda-source')
 $seen=@{}
 foreach($c in $lock.components) {
  if($c.id -notin $allowed -or $seen.ContainsKey($c.id)){throw 'Unknown or duplicate component.'}
  $seen[$c.id]=$true
  if($c.sha256 -notmatch '^[a-f0-9]{64}$' -or $c.file -notmatch '^[A-Za-z0-9_.-]+$'){throw 'Invalid component digest or file.'}
  $url=[uri]$c.url
  if($url.Scheme -ne 'https' -or $url.Host -ne 'github.com' -or $url.UserInfo -or $url.Query -or $url.Fragment -or $url.AbsolutePath -notmatch '^/(vibesoftwarecoder/(MultiSeat|ApolloVibe)|nefarius/(ViGEmBus|HidHide)|ClassicOldSong/Apollo)/releases/download/[^/]+/[^/]+$' -or $url.AbsolutePath -match '/latest/'){throw 'Use pinned vendor release URLs.'}
 }
 if($seen.Count -ne $allowed.Count){throw 'Component lock is incomplete.'}
 return $lock
}
function Test-EpicVMComponentAsset($Component,[string]$Path) {
 if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){return $false}
 if((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Component.sha256){return $false}
 if($Component.kind -eq 'installer') {
  $sig=Get-AuthenticodeSignature -LiteralPath $Path
  if($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or $sig.SignerCertificate.Subject -notmatch [regex]::Escape($Component.publisher)){return $false}
 }
 return $true
}
function Get-EpicVMComponentAsset($Component,[string]$Cache) {
 $cachePath=Assert-EpicVMComponentPath $Cache
 New-Item -ItemType Directory -Force -Path $cachePath | Out-Null
 $dest=Join-Path $cachePath $Component.file
 if(Test-EpicVMComponentAsset $Component $dest){return $dest}
 $temp=Join-Path $cachePath ($Component.file+'.'+[guid]::NewGuid().ToString('N')+'.download')
 try {
  Invoke-WebRequest -Uri $Component.url -OutFile $temp -UseBasicParsing -TimeoutSec 120
  if(-not(Test-EpicVMComponentAsset $Component $temp)){throw 'Downloaded component failed its pinned digest or publisher verification.'}
  Move-Item -LiteralPath $temp -Destination $dest -Force
 } finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
 return $dest
}
function Expand-EpicVMComponentArchive([string]$Archive,[string]$Destination) {
 $dest=Assert-EpicVMComponentPath $Destination
 if(Test-Path -LiteralPath $dest){throw 'Use an empty component extraction destination.'}
 $zip=[IO.Compression.ZipFile]::OpenRead($Archive)
 try {
  $entries=@{};[long]$size=0
  foreach($entry in $zip.Entries) {
   $name=$entry.FullName.Replace('\','/');$parts=$name.Split('/')
   if($name.StartsWith('/') -or $name.Contains(':') -or $parts -contains '..' -or $parts -contains '.' -or $entries.ContainsKey($name.ToLowerInvariant())){throw 'Unsafe or duplicate component archive entry.'}
   if((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000){throw 'Component archive cannot contain links.'}
   $entries[$name.ToLowerInvariant()]=$true;$size+=$entry.Length
   if($size -gt 2GB -or $entries.Count -gt 20000){throw 'Component archive exceeds supported limits.'}
   $target=[IO.Path]::GetFullPath((Join-Path $dest $name))
   if(-not $target.StartsWith($dest.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Archive entry escapes its destination.'}
  }
  New-Item -ItemType Directory -Path $dest | Out-Null
  foreach($entry in $zip.Entries) {
   $target=Join-Path $dest $entry.FullName.Replace('/','\')
   if($entry.FullName.EndsWith('/')){New-Item -ItemType Directory -Force -Path $target | Out-Null;continue}
   New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
   [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$target)
  }
 }finally{$zip.Dispose()}
 return $dest
}
function Write-EpicVMComponentCheckpoint([string]$Path,$State) {
 $State.updatedAt=[DateTimeOffset]::UtcNow.ToString('O')
 $temp=$Path+'.tmp'
 [IO.File]::WriteAllText($temp,($State|ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
 Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Get-EpicVMComponentStatus {
 $devices=@(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
 $result=@()
 foreach($spec in @(
  @{id='sudovda';pattern='SudoMaker|SudoVDA'},
  @{id='vigem';pattern='ViGEm'},
  @{id='hidhide';pattern='HidHide'}
 )) {
  $matches=@($devices | Where-Object {($_.FriendlyName -match $spec.pattern -or $_.InstanceId -match $spec.pattern)})
  $healthy=@($matches|Where-Object {$_.Status -eq 'OK'})
  if($spec.id -eq 'vigem'){
    $bus=Get-CimInstance Win32_SystemDriver -Filter "Name='ViGEmBus'" -ErrorAction SilentlyContinue
    if($bus){$matches=@($bus);$healthy=@($bus|Where-Object {$_.State -eq 'Running'})}
  }
  $result+=@{id=$spec.id;present=$matches.Count -gt 0;ready=$healthy.Count -gt 0;detail=if($healthy.Count){'Driver active'}elseif($matches.Count){'Driver needs attention or reboot'}else{'Driver missing'}}
 }
 $ms=Get-Service MultiSeatService -ErrorAction SilentlyContinue
 $result+=@{id='multiseat';present=[bool]$ms;ready=($null -ne $ms -and $ms.Status -eq 'Running');detail=if($ms){'Service '+$ms.Status}else{'Service missing'}}
 $apollo='C:\Program Files\ApolloVibe\sunshine.exe'
 $result+=@{id='apollo';present=(Test-Path -LiteralPath $apollo);ready=((Test-Path -LiteralPath $apollo) -and (Test-Path 'C:\Program Files\ApolloVibe\assets\apps.json'));detail='Machine Apollo payload'}
 return $result
}
function Invoke-EpicVMVerifiedDriverInstaller([string]$Path) {
 $p=Start-Process -FilePath $Path -ArgumentList '/quiet','/norestart' -WindowStyle Hidden -Wait -PassThru
 if($p.ExitCode -notin @(0,3010,1641)){throw ('Driver installer failed with exit code '+$p.ExitCode)}
 return @{exitCode=$p.ExitCode;rebootRequired=$p.ExitCode -in @(3010,1641)}
}
function Get-EpicVMMultiSeatComponentHealth {
 $key='C:\ProgramData\MultiSeat\api-key.txt'
 if(-not(Test-Path -LiteralPath $key)){throw 'MultiSeat API authentication is missing.'}
 $headers=@{'X-MultiSeat-Key'=(Get-Content -LiteralPath $key -Raw).Trim()}
 $auth=Invoke-RestMethod 'http://127.0.0.1:9550/api/system/auth' -Headers $headers -TimeoutSec 10
 $displays=Invoke-RestMethod 'http://127.0.0.1:9550/api/system/displays' -Headers $headers -TimeoutSec 10
 $seats=Invoke-RestMethod 'http://127.0.0.1:9550/api/seats/' -Headers $headers -TimeoutSec 10
 if($auth.authEnabled -ne $true){throw 'MultiSeat must require API authentication.'}
 return @{authenticated=$true;sudoVdaReady=($displays.sudoVdaFound -eq $true);seatCount=@($seats).Count}
}
Export-ModuleMember -Function *-EpicVM*
function Test-EpicVMComponentBundle([string]$Bundle) {
 $root=Assert-EpicVMComponentPath $Bundle
 $manifest=Get-Content -LiteralPath (Join-Path $root 'components.json') -Raw -Encoding UTF8 | ConvertFrom-Json
 if($manifest.schema -ne 1 -or $manifest.product -ne 'EpicVM Host Components' -or $manifest.architecture -ne 'x64'){throw 'Unsupported component bundle.'}
 $lock=Read-EpicVMComponentLock (Join-Path $root 'components.lock.json')
 $manifest.components=$lock.components
 $seen=@{}
 foreach($file in $manifest.files){
  if($file.path -notmatch '^(multiseat|apollo|sudovda|downloads)/[A-Za-z0-9_ .()/+@-]+$' -or $file.path.Split('/') -contains '..' -or $file.path.Contains(':') -or $seen.ContainsKey($file.path.ToLowerInvariant()) -or $file.sha256 -notmatch '^[a-f0-9]{64}$'){throw 'Unsafe component file manifest.'}
  $seen[$file.path.ToLowerInvariant()]=$true
  $path=Assert-EpicVMComponentPath (Join-Path $root $file.path)
  if(-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Get-FileHash -LiteralPath $path).Hash -ine $file.sha256){throw 'Component bundle integrity verification failed.'}
 }
 foreach($c in $lock.components){if(-not(Test-EpicVMComponentAsset $c (Join-Path $root ('downloads/'+$c.file)))){throw 'Component source failed pinned verification.'}}
 foreach($directory in @('multiseat','apollo','sudovda','downloads')){
  foreach($file in Get-ChildItem -LiteralPath (Join-Path $root $directory) -Recurse -File){$relative=$file.FullName.Substring($root.TrimEnd('\').Length+1).Replace('\','/');if(-not $seen.ContainsKey($relative.ToLowerInvariant())){throw 'Unlisted component file.'}}
 }
 foreach($required in @('multiseat/MultiSeat.Service.exe','apollo/sunshine.exe','apollo/assets/apps.json','sudovda/SudoVDA.inf','sudovda/sudovda.cer','sudovda/nefconc.exe')){if(-not $seen.ContainsKey($required.ToLowerInvariant())){throw 'Required component payload missing.'}}
 # Re-extract verified vendor ZIPs and compare every executable payload against
 # them. A rewritten local manifest cannot bless changed MultiSeat/Apollo code.
 $proof=Join-Path $env:TEMP ('epicvm-component-proof-'+[guid]::NewGuid().ToString('N'))
 New-Item -ItemType Directory -Path $proof | Out-Null
 try{
  foreach($c in $lock.components|Where-Object {$_.id -in @('multiseat','apollo')}){
   $verify=Expand-EpicVMComponentArchive (Join-Path $root ('downloads/'+$c.file)) (Join-Path $proof $c.id)
   $expected=@{}
   foreach($source in Get-ChildItem $verify -File -Recurse){$expected[$source.FullName.Substring($verify.Length+1).ToLowerInvariant()]=$true}
   foreach($actual in Get-ChildItem (Join-Path $root $c.id) -File -Recurse){if(-not $expected.ContainsKey($actual.FullName.Substring((Join-Path $root $c.id).Length+1).ToLowerInvariant())){throw 'Unexpected file outside pinned vendor payload.'}}
   foreach($source in Get-ChildItem $verify -File -Recurse){$relative=$source.FullName.Substring($verify.Length+1);$dest=Join-Path $root ($c.id+'/'+$relative);if(-not(Test-Path -LiteralPath $dest) -or (Get-FileHash $source.FullName).Hash -ne (Get-FileHash $dest).Hash){throw 'Payload differs from pinned vendor archive.'}}
  }
 }finally{if((Assert-EpicVMComponentPath $proof).StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $proof -Recurse -Force}}
 if((Get-FileHash (Join-Path $root 'sudovda/sudovda.cer')).Hash -ine $manifest.sudoCertificateSha256 -or $manifest.sudoCertificateSha256 -ne '6accdcd519f6179d967db4eaa20ecf25a732ba30e87f4cffebc768b2c13c9007'){throw 'Unexpected SudoVDA certificate.'}
 $driverHashes=@{
  'nefconc.exe'='9DBA1F1A9E2B21843C4A0CA6C6FFA9E747250DD6E42C8C14325CA069AD43EA8F'
  'sudovda.cat'='2F9189DE5604BEC9D86F51640CC540639E394D9AD0F8E689129375E95F2D22F8'
  'sudovda.cer'='6ACCDCD519F6179D967DB4EAA20ECF25A732BA30E87F4CFFEBC768B2C13C9007'
  'SudoVDA.dll'='47EE263CB5DE9382C6630A2D7F3DAFEC4A49419F953BEEC869CA5DD0C460FF63'
  'SudoVDA.inf'='AD69AC682756F0CF339B081FAC7E6E8159FDF2CA01CA69DF8945C7246C286925'
 }
 foreach($name in $driverHashes.Keys){if((Get-FileHash (Join-Path $root ('sudovda/'+$name))).Hash -ne $driverHashes[$name]){throw 'SudoVDA payload differs from the supported release.'}}
 $sig=Get-AuthenticodeSignature (Join-Path $root 'sudovda/nefconc.exe')
 if($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Nefarius Software Solutions'){throw 'Invalid driver helper signature.'}
 return $manifest
}
Export-ModuleMember -Function *-EpicVM*

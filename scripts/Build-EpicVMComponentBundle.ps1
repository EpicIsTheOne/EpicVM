param(
 [Parameter(Mandatory)][string]$OutputDirectory,
 [string]$Cache=(Join-Path $env:ProgramData 'EpicVM\component-cache'),
 [string]$SevenZip='C:\Program Files\7-Zip\7z.exe'
)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HostComponents.psm1') -Force
$repo=Split-Path $PSScriptRoot
$lock=Read-EpicVMComponentLock (Join-Path $repo 'setup/components.lock.json')
$out=Assert-EpicVMComponentPath $OutputDirectory
if(Test-Path -LiteralPath $out){throw 'Use a new component bundle directory.'}
New-Item -ItemType Directory -Path $out | Out-Null
$downloads=Join-Path $out 'downloads';New-Item -ItemType Directory -Path $downloads | Out-Null
foreach($c in $lock.components){$file=Get-EpicVMComponentAsset $c $Cache;Copy-Item -LiteralPath $file -Destination $downloads}
Expand-EpicVMComponentArchive (Join-Path $downloads 'multiseat-windows-x64.zip') (Join-Path $out 'multiseat') | Out-Null
Expand-EpicVMComponentArchive (Join-Path $downloads 'apollovibe-windows-x64.zip') (Join-Path $out 'apollo') | Out-Null
if(-not(Test-Path -LiteralPath $SevenZip)){throw '7-Zip is needed only on the release builder to extract the official SudoVDA payload.'}
$driverSource=Join-Path $out 'driver-source'
& $SevenZip x (Join-Path $downloads 'Apollo-0.4.6.exe') ('-o'+$driverSource) 'drivers/sudovda/*' -y | Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not extract official SudoVDA driver.'}
$driver=Join-Path $out 'sudovda';New-Item -ItemType Directory -Path $driver | Out-Null
foreach($name in @('SudoVDA.inf','SudoVDA.dll','sudovda.cat','sudovda.cer','nefconc.exe')){Copy-Item -LiteralPath (Join-Path $driverSource ('drivers/sudovda/'+$name)) -Destination $driver}
if((Get-FileHash (Join-Path $driver 'sudovda.cer')).Hash -ne '6ACCDCD519F6179D967DB4EAA20ECF25A732BA30E87F4CFFEBC768B2C13C9007'){throw 'Unexpected SudoVDA signing certificate.'}
$nef=Get-AuthenticodeSignature (Join-Path $driver 'nefconc.exe')
if($nef.Status -ne 'Valid' -or $nef.SignerCertificate.Subject -notmatch 'Nefarius Software Solutions'){throw 'SudoVDA installer helper is not trusted.'}
$files=@()
foreach($directory in @('multiseat','apollo','sudovda','downloads')){
 foreach($file in Get-ChildItem -LiteralPath (Join-Path $out $directory) -File -Recurse){
  $relative=$file.FullName.Substring($out.TrimEnd('\').Length+1).Replace('\','/')
  if($relative -match '(?i)(^|/)(api-key\.txt|accounts\.json|agent\.token|signing\.key|appsettings\.local\.json)$'){throw 'Component bundle contains private state.'}
  $files+=@{path=$relative;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant();bytes=$file.Length}
 }
}
[IO.File]::WriteAllText((Join-Path $out 'components.json'),(@{schema=1;product='EpicVM Host Components';architecture='x64';files=$files;components=$lock.components;sudoCertificateSha256='6accdcd519f6179d967db4eaa20ecf25a732ba30e87f4cffebc768b2c13c9007'}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
Copy-Item -LiteralPath (Join-Path $repo 'setup/components.lock.json') -Destination $out
Write-Output ('Verified component bundle ready: '+$out)

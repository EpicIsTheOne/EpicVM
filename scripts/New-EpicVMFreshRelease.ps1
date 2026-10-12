param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$OutputPath,[string]$Version='0.1.0-preview',[switch]$Preview,[string]$CertificateThumbprint)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem
if(Test-Path -LiteralPath $OutputPath){throw 'Choose a new release output path.'}
if($Version -notmatch '^\d+\.\d+\.\d+([.-][a-zA-Z0-9.-]+)?$'){throw 'Invalid release version.'}
$root=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
if(-not $Preview){
 if(-not $CertificateThumbprint){throw 'A trusted code-signing certificate is required for a public release. Use -Preview only for explicitly labeled test packages.'}
 $certificate=Get-Item -LiteralPath ('Cert:\CurrentUser\My\'+$CertificateThumbprint)
 if(-not $certificate.HasPrivateKey -or $certificate.NotAfter -lt (Get-Date)){throw 'A valid signing certificate with its private key is required.'}
 $targets=@((Join-Path $root 'ui/EpicVM.Agent.exe'),(Join-Path $root 'control/EpicVM.Control.exe'))
 $targets+=@(Get-ChildItem (Join-Path $root 'scripts') -File|Where-Object Extension -in @('.ps1','.psm1')|Select-Object -ExpandProperty FullName)
 foreach($target in $targets){
  $signature=Set-AuthenticodeSignature -LiteralPath $target -Certificate $certificate -TimestampServer 'http://timestamp.digicert.com' -HashAlgorithm SHA256
  if($signature.Status -ne 'Valid'){throw 'A package file did not receive a valid trusted signature.'}
 }
}
$files=@(Get-ChildItem $root -File -Recurse | Where-Object Name -ne 'fresh-release.json' | ForEach-Object {@{path=$_.FullName.Substring($root.Length+1).Replace('\','/');sha256=(Get-FileHash $_.FullName).Hash.ToLowerInvariant()}})
$manifest=Join-Path $root 'fresh-release.json'
[IO.File]::WriteAllText($manifest,(@{schema=1;product='EpicVM Fresh Host';version=$Version;files=$files;releaseStatus=$(if($Preview){'preview'}else{'signed-candidate'});cleanMachineVerified=$false}|ConvertTo-Json -Depth 6),[Text.UTF8Encoding]::new($false))
[IO.Compression.ZipFile]::CreateFromDirectory($root,[IO.Path]::GetFullPath($OutputPath),[IO.Compression.CompressionLevel]::Optimal,$false)
$checksums=@{archive=(Get-FileHash $OutputPath).Hash.ToLowerInvariant();manifest=(Get-FileHash $manifest).Hash.ToLowerInvariant();preview=[bool]$Preview;version=$Version}
[IO.File]::WriteAllText($OutputPath+'.checksums.json',($checksums|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
Write-Output ($checksums|ConvertTo-Json)

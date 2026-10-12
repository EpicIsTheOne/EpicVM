#Requires -RunAsAdministrator
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedManifestSha256)
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HostComponents.psm1') -Force
$source=Assert-EpicVMComponentPath $PackageRoot
$target='C:\Program Files\EpicVM'
Assert-EpicVMComponentPath $target | Out-Null
if(Test-Path -LiteralPath $target){throw 'An existing EpicVM package was found. Use its update/repair path. No files were changed.'}
$manifestPath=Join-Path $source 'fresh-release.json'
if((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ine $ExpectedManifestSha256){throw 'Release manifest does not match its trusted published checksum.'}
$manifest=Get-Content -LiteralPath $manifestPath -Raw|ConvertFrom-Json
if($manifest.schema -ne 1 -or $manifest.product -ne 'EpicVM Fresh Host'){throw 'Unsupported fresh-host package.'}
$seen=@{}
foreach($file in $manifest.files){
 $relative=[string]$file.path
 if($relative -notmatch '^[a-zA-Z0-9_ .()+@-]+(/[a-zA-Z0-9_ .()+@-]+)*$' -or $relative.Split('/') -contains '..' -or $relative.Split('/') -contains '.' -or $seen.ContainsKey($relative.ToLowerInvariant())){throw 'Unsafe release file path.'}
 $seen[$relative.ToLowerInvariant()]=$true
 $path=Assert-EpicVMComponentPath (Join-Path $source $relative)
 if((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $file.sha256){throw 'Release file failed integrity verification.'}
}
foreach($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force){
 $relative=$file.FullName.Substring($source.TrimEnd('\').Length+1).Replace('\','/').ToLowerInvariant()
 if($relative -ne 'fresh-release.json' -and -not $seen.ContainsKey($relative)){throw 'Release contains an unlisted file.'}
}
foreach($directory in Get-ChildItem -LiteralPath $source -Directory -Recurse -Force){Assert-EpicVMComponentPath $directory.FullName|Out-Null}
New-Item -ItemType Directory -Path $target|Out-Null
& icacls.exe $target /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX'|Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not protect installed package.'}
foreach($file in $manifest.files){
 $destination=Join-Path $target $file.path
 New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination)|Out-Null
 Copy-Item -LiteralPath (Join-Path $source $file.path) -Destination $destination
}
Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $target 'fresh-release.json')
foreach($file in $manifest.files){if((Get-FileHash -LiteralPath (Join-Path $target $file.path)).Hash -ine $file.sha256){throw 'Installed package integrity check failed. No services were registered.'}}
$shell=New-Object -ComObject WScript.Shell
$shortcut=$shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath('CommonPrograms')) 'EpicVM Host Setup.lnk'))
$shortcut.TargetPath=Join-Path $target 'ui/EpicVM.Agent.exe';$shortcut.Arguments='--setup';$shortcut.Save()
Write-Output 'Verified package installed. Open EpicVM Host Setup from Start. Existing accounts and private host state were not imported.'

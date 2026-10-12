param([Parameter(Mandatory)][string]$DataRoot,[Parameter(Mandatory)][string]$HostId,[switch]$ValidateOnly,[string]$Locator=(Join-Path $env:ProgramData 'EpicVM\storage.json'))
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'HostComponents.psm1') -Force
if($HostId -notmatch '^[a-z0-9][a-z0-9._-]{0,62}$'){throw 'Invalid host identity.'}
if($DataRoot -notmatch '^[A-Za-z]:\\' -or $DataRoot.Substring(2) -match '[<>:"|?*\x00-\x1f]' -or $DataRoot -match '(?i)(^|\\)(Windows|Users|Program Files(?: \(x86\))?)(\\|$)' -or $DataRoot -match '(^|\\)(\.\.?|[^\\]*[ .]|(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.[^\\]*)?)(\\|$)'){throw 'Choose a dedicated local folder outside system and profile directories.'}
$DataRoot=Assert-EpicVMComponentPath $DataRoot
if($DataRoot -notmatch '^[A-Za-z]:\\' -or $DataRoot.TrimEnd('\').Length -lt 4){throw 'Choose a dedicated folder on a local drive.'}
$drive=Get-Volume -DriveLetter $DataRoot.Substring(0,1) -ErrorAction Stop
if($drive.DriveType -ne 'Fixed' -or $drive.FileSystem -ne 'NTFS' -or $drive.SizeRemaining -lt 1GB){throw 'Choose a fixed NTFS drive with at least 1 GB available.'}
$standard=Join-Path $env:ProgramData 'EpicVM'
$marker=Join-Path $DataRoot '.epicvm-storage.json'
if($DataRoot.TrimEnd('\') -ine $standard -and (Test-Path -LiteralPath $DataRoot)){
 if(Test-Path -LiteralPath $marker){$owner=Get-Content $marker -Raw|ConvertFrom-Json;if($owner.hostId -cne $HostId){throw 'This data folder belongs to a different host.'}}
 elseif(@(Get-ChildItem -LiteralPath $DataRoot -Force).Count){throw 'Choose an empty data folder. Existing files were preserved.'}
}
$locator=Assert-EpicVMComponentPath $Locator
if(Test-Path -LiteralPath $locator){$old=Get-Content $locator -Raw|ConvertFrom-Json;if([string]$old.dataRoot -ine $DataRoot){throw 'Existing storage selection differs. Live data will not be moved by fresh setup.'}}
if($ValidateOnly){return}
New-Item -ItemType Directory -Path $DataRoot -Force|Out-Null
$acl=New-Object Security.AccessControl.DirectorySecurity
$acl.SetAccessRuleProtection($true,$false)
$acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
foreach($sid in @('S-1-5-18','S-1-5-32-544')){
 $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
}
Set-Acl -LiteralPath $DataRoot -AclObject $acl
[IO.File]::WriteAllText($marker,(@{schema=1;hostId=$HostId}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
New-Item -ItemType Directory -Path (Split-Path $locator) -Force|Out-Null
# The locator itself is protected, without changing unrelated parent ACLs.
$temporary=$locator+'.new'
[IO.File]::WriteAllText($temporary,(@{schema=1;dataRoot=$DataRoot}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
& icacls.exe $temporary /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F'|Out-Null
if($LASTEXITCODE -ne 0){throw 'Could not protect the storage locator.'}
Move-Item -LiteralPath $temporary -Destination $locator -Force
Write-Output 'Protected data location prepared. Existing Windows profiles were not moved.'

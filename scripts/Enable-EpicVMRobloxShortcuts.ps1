param([switch]$Apply)
$ErrorActionPreference='Stop'
$sourceRoot=Split-Path -Parent $PSScriptRoot
$stage=Join-Path $sourceRoot 'docs\verification\roblox-desktops-20261012\stage'
$destination='C:\Program Files\EpicVM\shared-apps\Roblox'
$desktop=[Environment]::GetFolderPath('CommonDesktopDirectory')
if (-not $Apply) {
    [pscustomobject]@{Apps=@('Roblox Player','Roblox Studio');Desktop=$desktop;Launcher=$destination;FirstUse='Official per-user installation'}
    return
}
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator rights required to publish shared shortcuts.' }
foreach($name in @('RobloxPlayerInstaller.exe','RobloxStudioInstaller.exe')) {
    $signature=Get-AuthenticodeSignature -LiteralPath (Join-Path $stage $name)
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Roblox Corporation(?:,|$)') {throw 'Installer signature verification failed'}
}
New-Item -ItemType Directory -Force (Join-Path $destination 'installers') | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-EpicVMRoblox.ps1') -Destination $destination -Force
foreach($name in @('RobloxPlayerInstaller.exe','RobloxStudioInstaller.exe')) {Copy-Item -LiteralPath (Join-Path $stage $name) -Destination (Join-Path $destination 'installers') -Force}
$shell=New-Object -ComObject WScript.Shell
$backup=Join-Path $sourceRoot 'docs\verification\roblox-desktops-20261012\shortcuts-before'
New-Item -ItemType Directory -Force $backup | Out-Null
foreach($app in @('Player','Studio')) {
    $name=if($app -eq 'Studio') {'Roblox Studio'}else{'Roblox Player'}
    $linkPath=Join-Path $desktop ($name+'.lnk')
    if (Test-Path -LiteralPath $linkPath) {Copy-Item -LiteralPath $linkPath -Destination $backup -Force}
    $link=$shell.CreateShortcut($linkPath)
    $link.TargetPath="$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $link.Arguments='-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+(Join-Path $destination 'Start-EpicVMRoblox.ps1')+'" -App '+$app
    $link.WorkingDirectory=$destination
    $icon=if($app -eq 'Studio') {'RobloxStudioInstaller.exe'}else{'RobloxPlayerInstaller.exe'}
    $link.IconLocation=(Join-Path $destination ('installers\'+$icon))+',0'
    $link.Description='Open Roblox '+$app+' in your Windows account. Official setup runs on first use.'
    $link.Save()
    [pscustomobject]@{App=$name;Shortcut=$linkPath;Installed=Test-Path -LiteralPath $linkPath}
}

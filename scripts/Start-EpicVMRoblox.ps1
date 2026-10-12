param(
    [ValidateSet('Player','Studio')][string]$App = 'Studio',
    [switch]$NoStart
)
$ErrorActionPreference = 'Stop'

function Find-EpicVMRobloxExecutable {
    param([string]$App, [string]$VersionsRoot = (Join-Path $env:LOCALAPPDATA 'Roblox\Versions'))
    $name = if ($App -eq 'Studio') { 'RobloxStudioBeta.exe' } else { 'RobloxPlayerBeta.exe' }
    if (-not (Test-Path -LiteralPath $VersionsRoot -PathType Container)) { return $null }
    # Inspect only application payloads in the current Windows account.
    $versions = Get-ChildItem -LiteralPath $VersionsRoot -Directory |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        Sort-Object LastWriteTime -Descending
    foreach ($version in $versions) {
        $path = Join-Path $version.FullName $name
        if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    }
    return $null
}

function Test-EpicVMRobloxPublisher {
    param([string]$Path)
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    return $signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match '(?:^|,\s*)O=Roblox Corporation(?:,|$)'
}

function Start-EpicVMRoblox {
    param([string]$App)
    $exe = Find-EpicVMRobloxExecutable -App $App
    if (-not $exe) {
        $installerName = if ($App -eq 'Studio') { 'RobloxStudioInstaller.exe' } else { 'RobloxPlayerInstaller.exe' }
        $installer = Join-Path $PSScriptRoot ('installers\' + $installerName)
        if (-not (Test-EpicVMRobloxPublisher -Path $installer)) { throw 'The Roblox installer could not be verified. Ask the host administrator to refresh it.' }
        # Roblox's official installer writes to this user's LocalAppData, so
        # every desktop keeps independent accounts, settings, and updates.
        Start-Process -FilePath $installer -Wait
        $deadline = [DateTime]::UtcNow.AddMinutes(2)
        do {
            $exe = Find-EpicVMRobloxExecutable -App $App
            if ($exe) { break }
            Start-Sleep -Seconds 2
        } while ([DateTime]::UtcNow -lt $deadline)
        if (-not $exe) { throw 'Roblox setup did not finish. Open this shortcut again to retry, or install from roblox.com.' }
        $processName = if ($App -eq 'Studio') { 'RobloxStudioBeta' } else { 'RobloxPlayerBeta' }
        $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
        if (Get-Process -Name $processName -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session }) { return }
    }
    if (-not (Test-EpicVMRobloxPublisher -Path $exe)) { throw 'The Roblox application could not be verified. Reinstall it from roblox.com in this Windows account.' }
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
}

if (-not $NoStart) {
    try { Start-EpicVMRoblox -App $App }
    catch {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'EpicVM Roblox', 'OK', 'Error')
        exit 1
    }
}

[CmdletBinding()]
param(
    [string] $Repository = 'EpicIsTheOne/EpicVM',
    [string] $Branch = 'main',
    [string] $TailscaleAddress,
    [string] $SwitchName,
    [switch] $NonInteractive
)

$ErrorActionPreference = 'Stop'

if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw 'Repository must use the owner/name form.'
}
if ($Branch -notmatch '^[A-Za-z0-9_.-]+$') {
    throw 'Branch must contain only letters, numbers, dots, underscores, and hyphens.'
}

$pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
if (-not $pwsh) {
    throw 'PowerShell 7 (pwsh) is required. Install it, then run this downloader again.'
}

$downloadRoot = Join-Path ([IO.Path]::GetTempPath()) ('EpicVM-RemoteVM-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
$baseUrl = "https://raw.githubusercontent.com/$Repository/$Branch/remote_agent/windows"
$files = @('setup.ps1', 'install.ps1', 'EpicVM.Agent.ps1', 'providers/HyperVProvider.ps1')

try {
    Write-Host 'Downloading EpicVM RemoteVM setup...' -ForegroundColor Cyan
    foreach ($relativePath in $files) {
        $destination = Join-Path $downloadRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Invoke-WebRequest `
            -Uri "$baseUrl/$relativePath" `
            -OutFile $destination `
            -Headers @{ 'User-Agent' = 'EpicVM-RemoteVM-Setup' } `
            -UseBasicParsing
    }

    $setup = Join-Path $downloadRoot 'setup.ps1'
    $setupArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $setup)
    if ($TailscaleAddress) { $setupArgs += @('-TailscaleAddress', $TailscaleAddress) }
    if ($SwitchName) { $setupArgs += @('-SwitchName', $SwitchName) }
    if ($NonInteractive) { $setupArgs += '-NonInteractive' }

    Write-Host 'Launching the guided EpicVM RemoteVM setup...' -ForegroundColor Green
    & $pwsh.Source @setupArgs
    if ($LASTEXITCODE -ne 0) {
        throw "RemoteVM setup failed with exit code $LASTEXITCODE."
    }
}
finally {
    Remove-Item -LiteralPath $downloadRoot -Recurse -Force -ErrorAction SilentlyContinue
}

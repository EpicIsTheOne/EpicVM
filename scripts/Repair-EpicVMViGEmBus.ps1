#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$DriverDirectory = 'C:\Program Files\Nefarius Software Solutions\ViGEm Bus Driver')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$hardwareId = 'Nefarius\ViGEmBus\Gen1'
$classGuid = '{4D36E97D-E325-11CE-BFC1-08002BE10318}'
$installer = Join-Path $DriverDirectory 'nefconw.exe'
$inf = Join-Path $DriverDirectory 'ViGEmBus.inf'
foreach ($path in @($installer, $inf)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing installed driver file: $path" }
}

function Get-EpicVMViGEmDevice {
    @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.HardwareID -contains $hardwareId })
}

function Invoke-EpicVMDriverTool([string[]]$Arguments) {
    $result = Start-Process -FilePath $installer -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    if ($result.ExitCode -ne 0) { throw "ViGEm driver utility failed with exit code $($result.ExitCode)." }
}

$devices = @(Get-EpicVMViGEmDevice)
if ($devices.Count -gt 1) { throw 'Multiple Nefarius bus devices exist; inspect before changing them.' }
if ($devices.Count -eq 1 -and $devices[0].ConfigManagerErrorCode -eq 0) {
    $devices | Select-Object Name, PNPDeviceID, ConfigManagerErrorCode
    return
}
if ($devices.Count -eq 0) {
    Invoke-EpicVMDriverTool -Arguments @('--create-device-node', '--hardware-id', $hardwareId,
        '--class-name', 'System', '--class-guid', $classGuid)
}
# Bind only the Nefarius hardware ID declared by this installed INF.
# Oculus uses a separate hardware ID and is not removed or modified.
Invoke-EpicVMDriverTool -Arguments @('--install-driver', '--inf-path', ('"' + $inf + '"'))
$devices = @(Get-EpicVMViGEmDevice)
if ($devices.Count -ne 1 -or $devices[0].ConfigManagerErrorCode -ne 0) {
    throw 'The Nefarius bus is not healthy after repair. Inspect PnP state before retrying.'
}
$devices | Select-Object Name, PNPDeviceID, ConfigManagerErrorCode

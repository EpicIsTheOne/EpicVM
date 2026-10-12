param([string]$Root = (Join-Path $env:LOCALAPPDATA 'EpicVM\direct-streams'))
$ErrorActionPreference = 'Stop'
$config = Join-Path $Root 'local-gateway.json'
if (-not (Test-Path -LiteralPath $config)) { return }
$settings = Get-Content -LiteralPath $config -Raw | ConvertFrom-Json
if (-not $settings.enabled) { return }
if ($settings.mode -eq 'local-ca') {
    $service=Get-Service EpicVMLocalGateway -ErrorAction SilentlyContinue
    if(-not $service){throw 'Local gateway service is missing. Repair local setup.'}
    if($service.Status -ne 'Running'){Start-Service EpicVMLocalGateway}
    return
}
$existing = Get-CimInstance Win32_Process -Filter "name = 'caddy-lan.exe'" -ErrorAction SilentlyContinue
if ($existing) { return }
$env:CF_API_TOKEN = (Get-Content -LiteralPath (Join-Path $Root 'lan-dns.token') -Raw).Trim()
try {
    Start-Process -FilePath (Join-Path $Root 'caddy-lan.exe') -ArgumentList @('run','--config',(Join-Path $Root 'Caddyfile.lan')) -WindowStyle Hidden -WorkingDirectory $Root -RedirectStandardOutput (Join-Path $Root 'lan.out.log') -RedirectStandardError (Join-Path $Root 'lan.err.log')
} finally { Remove-Item Env:CF_API_TOKEN }

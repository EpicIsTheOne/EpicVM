param(
    [Parameter(Mandatory)][string]$Address,
    [string]$Hostname = 'lan.epicvm.techexplore.us',
    [int]$Port = 8443,
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'EpicVM\direct-streams')
)
$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run elevated to install the scoped LAN firewall rule.' }
if ($Hostname -notmatch '^[a-z0-9][a-z0-9.-]+$' -or $Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or $Port -lt 1024 -or $Port -gt 65535) { throw 'Invalid local gateway settings.' }
if (-not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $Address -ErrorAction SilentlyContinue)) { throw 'The LAN address is not assigned to this host.' }
$binary = Join-Path $Root 'caddy-lan.exe'
$credential = Join-Path $Root 'lan-dns.token'
if (-not (Test-Path -LiteralPath $binary) -or -not (Test-Path -LiteralPath $credential)) { throw 'Install Caddy with dns.providers.cloudflare and the private DNS token before enabling LAN mode.' }
$modules = & $binary list-modules
if ($modules -notcontains 'dns.providers.cloudflare') { throw 'Dedicated Caddy binary lacks the Cloudflare DNS provider.' }
$config = @"
{
    admin 127.0.0.1:2020
    auto_https disable_redirects
}
https://${Hostname}:${Port} {
    bind $Address
    tls {
        dns cloudflare {env.CF_API_TOKEN}
    }
    @localhealth path /EpicVM/local-health
    handle @localhealth {
        header Access-Control-Allow-Origin https://techexplore.us
        header Access-Control-Allow-Private-Network true
        header Access-Control-Allow-Methods "GET, OPTIONS"
        header Cache-Control no-store
        respond "ok" 200
    }
    import $($Root.Replace('\','/'))/caddy-routes.caddy
    handle {
        redir https://techexplore.us/EpicVM/portal 302
    }
}
"@
$configPath = Join-Path $Root 'Caddyfile.lan'
if (Test-Path -LiteralPath $configPath) { Copy-Item -LiteralPath $configPath -Destination ($configPath + '.before-lan') }
[IO.File]::WriteAllText($configPath, $config)
$env:CF_API_TOKEN = (Get-Content -LiteralPath $credential -Raw).Trim()
try {
    # Caddy writes successful validation logs to stderr. Windows PowerShell
    # treats native stderr as errors, so rely on the process exit code.
    $validation = Start-Process -FilePath $binary -ArgumentList @('validate','--config',('"' + $configPath + '"')) -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $Root 'lan-validation.out.log') -RedirectStandardError (Join-Path $Root 'lan-validation.err.log')
    if ($validation.ExitCode -ne 0) { throw 'LAN Caddy validation failed. Check the private validation logs.' }
}
finally { Remove-Item Env:CF_API_TOKEN }
$rule = 'EpicVM Local Gateway HTTPS'
if (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -DisplayName $rule }
New-NetFirewallRule -DisplayName $rule -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -LocalAddress $Address -RemoteAddress LocalSubnet -Profile Any -Program $binary | Out-Null
[IO.File]::WriteAllText((Join-Path $Root 'local-gateway.json'), (@{enabled=$true;origin="https://${Hostname}:${Port}";address=$Address} | ConvertTo-Json))
& (Join-Path $PSScriptRoot 'Start-EpicVMLocalGateway.ps1') -Root $Root
Write-Output "Local gateway configured on https://${Hostname}:${Port}. Verify a trusted HTTPS connection before advertising it to users."

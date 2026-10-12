# EpicVM's native Windows gaming adapter. MultiSeat owns the session, display,
# stream and teardown; this file only applies EpicVM's catalog and owner policy.
$storageSource=Join-Path $PSScriptRoot 'HostStorage.ps1'
if(Test-Path -LiteralPath $storageSource){. $storageSource}
$script:HostGamingRoot = if(Get-Command Get-EpicVMDataRoot -ErrorAction SilentlyContinue){Join-Path (Get-EpicVMDataRoot) 'host-gaming'}else{'C:\ProgramData\EpicVM\host-gaming'}
$script:HostGamingCatalog = Join-Path $script:HostGamingRoot 'games.json'
$script:MultiSeatBase = 'http://127.0.0.1:9550'
$policySource = Join-Path $PSScriptRoot 'HostingPolicy.ps1'
if (Test-Path -LiteralPath $policySource) { . $policySource }

function Initialize-EpicVMHostGaming {
    if (-not (Test-Path -LiteralPath $script:HostGamingRoot)) {
        [IO.Directory]::CreateDirectory($script:HostGamingRoot) | Out-Null
    }
    & icacls.exe $script:HostGamingRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Host gaming catalog permissions could not be secured.' }
}

function Invoke-EpicVMMultiSeat([string]$Method, [string]$Path, $Payload = $null) {
    if ($Path -notmatch '^/api/(seats|accounts|system)/[a-zA-Z0-9/_-]*$') { throw 'Invalid seat API path.' }
    $keyPath = 'C:\ProgramData\MultiSeat\api-key.txt'
    if (-not (Test-Path -LiteralPath $keyPath -PathType Leaf)) { throw 'MultiSeat is not installed with API authentication enabled.' }
    $key = [IO.File]::ReadAllText($keyPath).Trim()
    if (-not $key) { throw 'MultiSeat API key is empty.' }
    $args = @{ Uri = ($script:MultiSeatBase + $Path); Method = $Method; Headers = @{'X-MultiSeat-Key' = $key}; TimeoutSec = 90; ErrorAction = 'Stop' }
    if ($null -ne $Payload) {
        $args.ContentType = 'application/json'
        $args.Body = ConvertTo-Json -InputObject $Payload -Depth 8 -Compress
    }
    try {
        $response = Invoke-WebRequest @args
        if (-not $response.Content) { return $null }
        return ConvertFrom-Json -InputObject $response.Content -AsHashtable
    } catch {
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if ($Path -eq '/api/seats/epicvm-existing') {
            if ($code -eq 403) { throw 'The Windows password was not accepted. Use the account password, not its PIN.' }
            if ($code -eq 429) { throw 'Too many Windows password attempts. Wait five minutes before trying again.' }
            if ($code -eq 409) { throw 'This Windows account is busy or needs recovery. Sign out of any other Windows session for it before trying again.' }
        }
        throw "Seat service request failed ($code): $Method $Path"
    } finally { $key = $null }
}

function Get-EpicVMHostGamingCatalog {
    Initialize-EpicVMHostGaming
    if (Test-Path -LiteralPath $script:HostGamingCatalog) {
        return @(Get-Content -LiteralPath $script:HostGamingCatalog -Raw | ConvertFrom-Json -AsHashtable)
    }
    return @()
}

function Get-EpicVMHostGamingAccount([string]$Owner) {
    if ($Owner -notmatch '^(portal|dashboard-config):[a-zA-Z0-9_.@-]{1,128}$') { throw 'Invalid EpicVM owner.' }
    $assignment = Get-EpicVMExistingAccountAssignment $Owner
    if ($assignment) {
        $user = Get-LocalUser -SID $assignment.accountSid -ErrorAction SilentlyContinue
        if (-not $user -or -not $user.Enabled -or [string]$user.PrincipalSource -ne 'Local' -or $user.Name -cne $assignment.accountName) { throw 'The assigned local Windows account changed or is unavailable. Ask your administrator to reassign it.' }
        return [string]$user.Name
    }
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Owner.ToLowerInvariant()))
    $hex = [Convert]::ToHexString($hash).ToLowerInvariant()
    $legacy = 'evseat_' + $hex.Substring(0, 13)
    # Existing seats keep their Windows profile; only newly created accounts
    # receive the readable name. MultiSeat caps names at 20 characters.
    if (Get-LocalUser -Name $legacy -ErrorAction SilentlyContinue) { return $legacy }
    $parts = $Owner.Split(':', 2)
    $label = $parts[1].ToLowerInvariant()
    if ($parts[0] -eq 'portal' -and $label -match '^[a-z0-9_]{1,13}$' -and $label -notmatch '^cfg_') {
        return 'EpicVM_' + $label
    }
    if ($parts[0] -eq 'dashboard-config') { return 'EpicVM_cfg_' + $hex.Substring(0, 9) }
    $safe = [regex]::Replace($label, '[^a-z0-9_]', '_').Trim('_')
    if (-not $safe) { $safe = 'user' }
    return 'EpicVM_' + $safe.Substring(0, [Math]::Min(8, $safe.Length)) + '_' + $hex.Substring(0, 4)
}

function Get-EpicVMExistingAccountMappings {
    Initialize-EpicVMHostGaming
    $path = Join-Path $script:HostGamingRoot 'local-account-assignments.json'
    if (Test-Path -LiteralPath $path) { return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable) }
    return @{}
}

function Get-EpicVMExistingAccountAssignment([string]$Owner) {
    $mappings = Get-EpicVMExistingAccountMappings
    return $mappings[$Owner.ToLowerInvariant()]
}

function Test-EpicVMHostSeatOwnership([string]$AccountName) {
    $mappings = Get-EpicVMExistingAccountMappings
    foreach ($owner in $mappings.Keys) {
        $assignment = $mappings[$owner]
        if ($assignment.accountName -ine $AccountName) { continue }
        if ($owner -notmatch '^portal:[a-zA-Z0-9_.@-]{1,128}$') { return $false }
        $user = Get-LocalUser -SID $assignment.accountSid -ErrorAction SilentlyContinue
        return [bool]($user -and $user.Name -ieq $AccountName -and $user.SID.Value -eq $assignment.accountSid)
    }
    return $AccountName -match '^(evseat_[0-9a-f]{13}|EpicVM_[a-z0-9_]{1,13})$'
}

function Get-EpicVMExistingLocalAccounts {
    $linked = @(Invoke-EpicVMMultiSeat GET '/api/accounts/' | ForEach-Object { $_.username })
    $mappings = Get-EpicVMExistingAccountMappings
    return @{ok=$true;accounts=@(Get-LocalUser | Where-Object {
        $_.Enabled -and [string]$_.PrincipalSource -eq 'Local' -and $_.SID.Value -notmatch '-(500|501|503|504)$' -and
        $_.Name -match '^[a-zA-Z0-9][a-zA-Z0-9._-]{0,19}$' -and $_.Name -notmatch '^(EpicVM_|evseat_|MultiSeatSeat)' -and $_.Name -notin $linked
    } | ForEach-Object { @{accountName=$_.Name;accountSid=$_.SID.Value} });assignments=$mappings}
}

function Set-EpicVMExistingAccountAssignment($Request) {
    $owner = [string]$Request.owner
    if ($owner -notmatch '^portal:[a-zA-Z0-9_.@-]{1,128}$') { throw 'Choose a portal account.' }
    $owner = $owner.ToLowerInvariant()
    $mappings = Get-EpicVMExistingAccountMappings
    $current = if ($mappings[$owner]) { [string]$mappings[$owner].accountName } else { Get-EpicVMHostGamingAccount $owner }
    $sid = [string]$Request.accountSid
    $view = Get-EpicVMHostGamingView
    if (-not $view.ready -or -not $view.supportsExistingLocalAccounts) { throw 'Update the host service before assigning local accounts.' }
    $next = $null
    if ($sid) {
        $next = @( (Get-EpicVMExistingLocalAccounts).accounts | Where-Object { $_.accountSid -eq $sid })
        if ($next.Count -ne 1) { throw 'Choose an enabled local Windows account supported by MultiSeat.' }
        $next = $next[0]
        foreach ($key in @($mappings.Keys)) { if ($key -ne $owner -and $mappings[$key].accountSid -eq $sid) { throw 'This Windows account is already assigned.' } }
    }
    if (@($view.seats | Where-Object { $_.accountName -ieq $current -or ($next -and $_.accountName -ieq $next.accountName) }).Count) { throw 'End the affected desktop sessions before changing their Windows account. Saved files and accounts will be preserved.' }
    if ($next) { $mappings[$owner] = $next } else { $mappings.Remove($owner) }
    Write-EpicVMGameJson (Join-Path $script:HostGamingRoot 'local-account-assignments.json') $mappings
    return @{ok=$true;assignment=$next}
}

function Get-EpicVMApolloAuth([int]$PortBase, [switch]$Create) {
    $path = Join-Path $script:HostGamingRoot 'apollo-auth.json'
    if (Test-Path -LiteralPath $path) {
        $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $cipher = [Convert]::FromBase64String([string]$record.cipher)
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($cipher, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        try { return @{username=[string]$record.username;password=[Text.Encoding]::UTF8.GetString($plain)} }
        finally { [Array]::Clear($plain, 0, $plain.Length) }
    }
    if (-not $Create) { throw 'Seat streaming pairing is not initialized.' }
    if (Test-Path -LiteralPath 'C:\ProgramData\MultiSeat\apollo\shared_credentials.json') {
        throw 'Existing seat streaming credentials need administrator migration.'
    }
    $username = 'epicvm-seat-stream'
    $password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(42)) + 'aA1!'
    try {
        $body = @{currentUsername='';currentPassword='';newUsername=$username;newPassword=$password;confirmNewPassword=$password} | ConvertTo-Json -Compress
        $response = Invoke-RestMethod -Uri "https://127.0.0.1:$($PortBase+1)/api/password" -Method Post -ContentType 'application/json' -Body $body -SkipCertificateCheck -TimeoutSec 10
        if ($response.status -ne $true) { throw 'Seat streaming credential setup failed.' }
        $bytes = [Text.Encoding]::UTF8.GetBytes($password)
        try { $cipher = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine) }
        finally { [Array]::Clear($bytes, 0, $bytes.Length) }
        Write-EpicVMGameJson $path @{username=$username;cipher=[Convert]::ToBase64String($cipher)}
        return @{username=$username;password=$password}
    } catch { throw 'Seat streaming credential setup failed.' }
}

function Pair-EpicVMHostGaming($Request) {
    $account = Get-EpicVMHostGamingAccount ([string]$Request.owner)
    $pin = [string]$Request.pin
    if ($pin -notmatch '^\d{4}$') { throw 'Invalid stream pairing PIN.' }
    $view = Get-EpicVMHostGamingView
    $seats = @($view.seats | Where-Object { $_.accountName -ieq $account -and $_.status -in @('Ready','Streaming') })
    if ($seats.Count -ne 1) { throw 'The owner has no ready seat.' }
    $auth = Get-EpicVMApolloAuth ([int]$seats[0].portBase)
    try {
        $base = "https://127.0.0.1:$([int]$seats[0].portBase+1)"
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Invoke-WebRequest -Uri "$base/api/login" -Method Post -WebSession $session -ContentType 'application/json' -Body (@{username=$auth.username;password=$auth.password}|ConvertTo-Json -Compress) -SkipCertificateCheck -TimeoutSec 10 | Out-Null
        $before = Invoke-RestMethod -Uri "$base/api/clients/list" -WebSession $session -SkipCertificateCheck -TimeoutSec 10
        $existingIds = @($before.named_certs | ForEach-Object { $_.uuid })
        # Moonlight emits its PIN before its asynchronous host handshake has
        # necessarily reached Apollo. Retry only an explicit pending rejection.
        $deadline = [DateTime]::UtcNow.AddSeconds(20)
        do {
            $response = Invoke-RestMethod -Uri "$base/api/pin" -Method Post -WebSession $session -ContentType 'application/json' -Body (@{pin=$pin;name='EpicVMWeb'}|ConvertTo-Json -Compress) -SkipCertificateCheck -TimeoutSec 5
            if ($response.status -eq $true) { break }
            if ($response.status -ne $false) { throw 'Seat returned an invalid pairing response.' }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'Seat rejected the pairing PIN.' }
            Start-Sleep -Milliseconds 250
        } while ($true)
        Initialize-EpicVMHostGaming
        Write-EpicVMGameJson (Join-Path $script:HostGamingRoot ($account + '.pending-pair.json')) @{ids=$existingIds;expires=[DateTime]::UtcNow.AddMinutes(2).ToString('o')}
        return @{ok=$true;paired=$true}
    } finally { $auth.password=$null; $session=$null }
}

function Complete-EpicVMHostGamingPair($Request) {
    $account = Get-EpicVMHostGamingAccount ([string]$Request.owner)
    $pendingPath = Join-Path $script:HostGamingRoot ($account + '.pending-pair.json')
    if (-not (Test-Path -LiteralPath $pendingPath)) { throw 'No pending stream pairing for this owner.' }
    $pending = Get-Content -LiteralPath $pendingPath -Raw | ConvertFrom-Json
    if ([DateTime]$pending.expires -lt [DateTime]::UtcNow) { throw 'Stream pairing expired.' }
    $existingIds = $pending.ids
    $view = Get-EpicVMHostGamingView
    $seats = @($view.seats | Where-Object { $_.accountName -ieq $account -and $_.status -in @('Ready','Streaming') })
    if ($seats.Count -ne 1) { throw 'The owner has no ready seat.' }
    $auth = Get-EpicVMApolloAuth ([int]$seats[0].portBase)
    try {
        $base = "https://127.0.0.1:$([int]$seats[0].portBase+1)"
        $session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()
        Invoke-WebRequest -Uri "$base/api/login" -Method Post -WebSession $session -ContentType 'application/json' -Body (@{username=$auth.username;password=$auth.password}|ConvertTo-Json -Compress) -SkipCertificateCheck -TimeoutSec 10 | Out-Null
        # Apollo gives replacement clients view-only rights. Identify only the
        # client created by this pairing, then grant desktop launch and input.
        $paired = @()
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            $clients = Invoke-RestMethod -Uri "$base/api/clients/list" -WebSession $session -SkipCertificateCheck -TimeoutSec 10
            $paired = @($clients.named_certs | Where-Object { $_.uuid -notin $existingIds })
            if ($paired.Count) { break }
            Start-Sleep -Milliseconds 250
        }
        if ($paired.Count -ne 1 -or $paired[0].name -notmatch '^EpicVMWeb( \(\d+\))?$') { throw 'Could not identify the newly paired stream client.' }
        $client = $paired[0]
        $updated = Invoke-RestMethod -Uri "$base/api/clients/update" -Method Post -WebSession $session -ContentType 'application/json' -Body (@{
            uuid=$client.uuid;name=$client.name;perm=0x07001F00
            display_mode=$client.display_mode;enable_legacy_ordering=$client.enable_legacy_ordering
            allow_client_commands=$false;always_use_virtual_display=$false
        } | ConvertTo-Json -Compress) -SkipCertificateCheck -TimeoutSec 10
        if ($updated.status -ne $true) { throw 'Seat rejected stream launch permissions.' }
        Remove-Item -LiteralPath $pendingPath -Force
        return @{ok=$true;paired=$true}
    } finally { $auth.password=$null; $session=$null }
}
function Get-EpicVMHostGamingView {
    $policy = Get-EpicVMHostingPolicy
    $hosting = @{paused=[bool]$policy.paused;maxSeats=[int]$policy.maxSeats;seatCount=0;full=$false}
    $installed = [bool](Get-Service MultiSeatService -ErrorAction SilentlyContinue)
    $service = Get-Service MultiSeatService -ErrorAction SilentlyContinue
    $games = @(Get-EpicVMHostGamingCatalog | ForEach-Object { @{id=$_.id;title=$_.title;available=(Test-Path -LiteralPath $_.executable -PathType Leaf)} })
    if (-not $service -or $service.Status -ne 'Running') {
        return @{ok=$true;apiVersion=3;hosting=$hosting;installed=$installed;ready=$false;service=if($service){$service.Status.ToString()}else{'Missing'};games=$games;seats=@()}
    }
    $auth = Invoke-EpicVMMultiSeat GET '/api/system/auth'
    if ($auth.authEnabled -ne $true) { throw 'MultiSeat API authentication must be enabled.' }
    $displays = Invoke-EpicVMMultiSeat GET '/api/system/displays'
    $seats = @(Invoke-EpicVMMultiSeat GET '/api/seats/')
    $hosting.seatCount = $seats.Count
    $hosting.full = $hosting.maxSeats -gt 0 -and $seats.Count -ge $hosting.maxSeats
    $existingSupport = $false
    try { $existingSupport = (Invoke-EpicVMMultiSeat GET '/api/accounts/epicvm-existing-support').ephemeralCredentials -eq $true } catch {}
    # Without SudoVDA, Apollo can capture the physical desktop. Fail closed.
    return @{ok=$true;apiVersion=3;hosting=$hosting;supportsExistingLocalAccounts=$existingSupport;installed=$true;ready=($displays.sudoVdaFound -eq $true);service='Running';games=$games;seats=@($seats | ForEach-Object { @{id=$_.id;accountName=$_.accountName;epicvmOwned=(Test-EpicVMHostSeatOwnership ([string]$_.accountName));status=$_.status;portBase=$_.portBase;sessionId=$_.sessionId;errorMessage=$_.errorMessage} })}
}

function Register-EpicVMHostGame($Request) {
    $id = [string]$Request.id
    $title = [string]$Request.title
    if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$' -or -not $title -or $title.Length -gt 120) { throw 'Invalid game identity.' }
    $path = [IO.Path]::GetFullPath([string]$Request.executable)
    if ($path -notmatch '^[A-Za-z]:\\' -or [IO.Path]::GetExtension($path) -ine '.exe' -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Choose an installed executable on this host.' }
    if ($path -match '(?i)\\(Users|AppData|Windows)\\') { throw 'Choose a machine-wide installation outside user profiles and Windows.' }
    $games = @(Get-EpicVMHostGamingCatalog | Where-Object { $_.id -ne $id })
    $games += @{id=$id;title=$title;executable=$path}
    Write-EpicVMGameJson $script:HostGamingCatalog $games
    return @{ok=$true;games=@($games | ForEach-Object { @{id=$_.id;title=$_.title;available=$true} })}
}

function Unregister-EpicVMHostGame($Request) {
    $id = [string]$Request.id
    if ($id -notmatch '^[a-z0-9][a-z0-9-]{0,63}$') { throw 'Invalid game identity.' }
    $games = @(Get-EpicVMHostGamingCatalog | Where-Object { $_.id -ne $id })
    Write-EpicVMGameJson $script:HostGamingCatalog $games
    return @{ok=$true;games=@($games | ForEach-Object { @{id=$_.id;title=$_.title;available=(Test-Path -LiteralPath $_.executable -PathType Leaf)} })}
}

function Start-EpicVMHostSession($Request, [switch]$Desktop) {
    $account = Get-EpicVMHostGamingAccount ([string]$Request.owner)
    $assignment = Get-EpicVMExistingAccountAssignment ([string]$Request.owner)
    $expectedSid = if ($assignment) { [string]$assignment['accountSid'] } else { '' }
    if ([string]$Request['accountSid'] -cne $expectedSid) { throw 'The Windows account assignment changed. Refresh your workspace.' }
    if ($assignment -and (-not $Request['windowsPassword'] -or ([string]$Request['windowsPassword']).Length -gt 256)) { throw 'Enter the Windows password for this desktop, not its PIN.' }
    $id = ''
    $game = $null
    if (-not $Desktop) {
        $id = [string]$Request.gameId
        $games = @(Get-EpicVMHostGamingCatalog | Where-Object { $_.id -eq $id })
        if ($games.Count -ne 1) { throw 'Game is not in the host catalog.' }
        $game = $games[0]
        if (-not (Test-Path -LiteralPath $game.executable -PathType Leaf)) { throw 'The host game is unavailable.' }
    }
    $view = Get-EpicVMHostGamingView
    if (-not $view.ready) { throw 'Native gaming is not ready on this host.' }
    $seats = @($view.seats | Where-Object { $_.accountName -ieq $account })
    if ($seats.Count -gt 1) { throw 'More than one seat owns this account. Administrator recovery is required.' }
    if (-not $assignment -and $seats.Count -eq 1 -and $seats[0].status -eq 'Error') {
        # MultiSeat retains failed records for inspection. Retire only this
        # owner's failed seat before asking it to allocate a fresh one.
        Invoke-EpicVMMultiSeat DELETE ('/api/seats/' + $seats[0].id) | Out-Null
        $seats = @()
    }
    $newSeat = $false
    $policy = if (Get-Command Get-EpicVMHostingPolicy -ErrorAction SilentlyContinue) { Get-EpicVMHostingPolicy } else { @{paused=$false;maxSeats=0;width=1920;height=1080;fps=60} }
    if (-not $seats.Count) {
        if ($policy.paused) { throw 'The host has paused new desktop sessions. Existing desktops can still reconnect.' }
        if ([int]$policy.maxSeats -gt 0 -and @($view.seats).Count -ge [int]$policy.maxSeats) { throw 'The host has reached its desktop session limit.' }
    }
    if ($assignment) {
        try {
            $seat = Invoke-EpicVMMultiSeat POST '/api/seats/epicvm-existing' @{accountName=$account;accountSid=$assignment.accountSid;password=[string]$Request.windowsPassword;width=[int]$policy.width;height=[int]$policy.height;fps=[int]$policy.fps}
        } finally { $Request.windowsPassword = $null }
        $newSeat = -not $seats.Count
    } elseif (-not $seats.Count) {
        $accounts = @(Invoke-EpicVMMultiSeat GET '/api/accounts/')
        if ($account -notin @($accounts | ForEach-Object { $_.username })) {
            # A fresh seat password is sent only to the local service, which
            # protects it. No operator or launcher credentials are copied.
            $password = [Convert]::ToBase64String([Security.Cryptography.RandomNumberGenerator]::GetBytes(36)) + 'aA1!'
            try { Invoke-EpicVMMultiSeat POST '/api/accounts/' @{username=$account;password=$password} | Out-Null }
            finally { $password = $null }
        }
        $seat = Invoke-EpicVMMultiSeat POST '/api/seats/' @{accountName=$account;width=[int]$policy.width;height=[int]$policy.height;fps=[int]$policy.fps}
        $newSeat = $true
    } else {
        $seat = Invoke-EpicVMMultiSeat GET ('/api/seats/' + $seats[0].id)
    }
    try {
        if ($seat.status -notin @('Ready','Streaming')) { throw 'The seat is not ready to launch a game.' }
        $auth = Get-EpicVMApolloAuth ([int]$seat.portBase) -Create
        $auth.password = $null
        $sid = [string]$seat.id
        if (-not $Desktop) {
            Invoke-EpicVMMultiSeat POST "/api/seats/$sid/launch" @{executablePath=$game.executable;workingDirectory=(Split-Path -Parent $game.executable)} | Out-Null
        }
        return @{ok=$true;kind=if($Desktop){'desktop'}else{'game'};gameId=$id;seatId=$sid;status=$seat.status;portBase=$seat.portBase;streamHost=$env:COMPUTERNAME}
    } catch {
        if ($newSeat -and $seat.id) { try { Invoke-EpicVMMultiSeat DELETE ('/api/seats/' + $seat.id) | Out-Null } catch {} }
        throw
    }
}

function Start-EpicVMHostGame($Request) { return Start-EpicVMHostSession $Request }

function Start-EpicVMHostDesktop($Request) { return Start-EpicVMHostSession $Request -Desktop }

function Reveal-EpicVMHostAccountCredential($Request) {
    if (Get-EpicVMExistingAccountAssignment ([string]$Request.owner)) { throw 'Existing Windows account passwords are never saved or revealed by EpicVM.' }
    $account = Get-EpicVMHostGamingAccount ([string]$Request.owner)
    $accounts = @(Invoke-EpicVMMultiSeat GET '/api/accounts/')
    if ($account -notin @($accounts | Where-Object { $_.isManaged -eq $true } | ForEach-Object { $_.username })) {
        throw 'The owner has no managed Windows account.'
    }
    $result = Invoke-EpicVMMultiSeat POST ("/api/accounts/$account/credential/reveal")
    if (-not $result.password) { throw 'The seat account credential is unavailable.' }
    return @{ok=$true;accountName=$account;password=[string]$result.password}
}

function Stop-EpicVMHostGame($Request) {
    $account = Get-EpicVMHostGamingAccount ([string]$Request.owner)
    $view = Get-EpicVMHostGamingView
    foreach ($seat in @($view.seats | Where-Object { $_.accountName -ieq $account })) {
        Invoke-EpicVMMultiSeat DELETE ('/api/seats/' + $seat.id) | Out-Null
    }
    return @{ok=$true;status='stopped'}
}

function Recover-EpicVMHostGaming($Request) {
    $seatId = [string]$Request.seatId
    if ($seatId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Invalid seat identity.' }
    $view = Get-EpicVMHostGamingView
    $owned = @($view.seats | Where-Object { $_.id -eq $seatId -and (Test-EpicVMHostSeatOwnership ([string]$_.accountName)) })
    if ($owned.Count -ne 1) { throw 'Seat is not managed by EpicVM.' }
    Invoke-EpicVMMultiSeat DELETE ('/api/seats/' + $seatId) | Out-Null
    return @{ok=$true;status='recovered';seatId=$seatId}
}

$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-EpicVMUpdateImpact($Paths) {
    if(@($Paths | Where-Object {$_ -match '^scripts/(HostStorage|local_lan|host_runtime|manage_host_runtime|supervise_host_direct_streams|provision_direct_stream|host_stream_gateway|direct_stream_auth|write_direct_stream_caddy|Start-EpicVMLocalGateway|stream_recovery|stream_network)\.'}).Count){return 'desktops-must-end'}
    if(@($Paths | Where-Object {$_ -like 'control/*'}).Count){return 'control-restart'}
    return 'agent-only'
}
function Test-EpicVMUpdatePath([string]$Path) {
    if($Path -notmatch '^[a-zA-Z0-9_.-]+(/[a-zA-Z0-9_.-]+)+$' -or $Path.Split('/') -contains '..' -or $Path.Split('/') -contains '.'){return $false}
    if($Path -match '^(ui|control)/'){return $true}
    return $Path -match '^scripts/(local_lan\.py|HostStorage\.ps1|HostUpdates\.ps1|Update-EpicVMHost\.ps1|Setup-EpicVMHost\.ps1|Install-EpicVMHostRuntime\.ps1|agent_update_wait\.py|WINDOWS-HOST-UPDATES\.md|host_runtime\.py|manage_host_runtime\.py|supervise_host_direct_streams\.py|provision_direct_stream\.py|host_stream_gateway\.py|direct_stream_auth\.py|write_direct_stream_caddy\.py|Start-EpicVMLocalGateway\.ps1|stream_recovery\.js|stream_network\.js)$'
}
function Assert-EpicVMPlainPath([string]$Path) {
    $candidate=[IO.Path]::GetFullPath($Path)
    $item=Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
    while(-not $item){$candidate=Split-Path $candidate;if(-not $candidate){return};$item=Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue}
    while($item){
        if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Update paths cannot traverse links or junctions.'}
        $item=if($item.PSIsContainer){$item.Parent}else{$item.Directory}
    }
}
function Expand-EpicVMUpdate([string]$PackagePath,[string]$Stage) {
    Assert-EpicVMPlainPath $PackagePath
    $zip=[IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        $entries=@{};[long]$total=0
        foreach($entry in $zip.Entries){
            if($entry.FullName.EndsWith('/')){continue}
            if($entries.ContainsKey($entry.FullName)){throw 'Duplicate package entry.'}
            if($entry.FullName -ne 'release.json' -and -not(Test-EpicVMUpdatePath $entry.FullName)){throw 'Package includes an unsupported destination.'}
            $total+=$entry.Length
            if($total -gt 1GB -or $zip.Entries.Count -gt 3000){throw 'Package exceeds the supported size.'}
            $entries[$entry.FullName]=$entry
        }
        if(-not $entries.ContainsKey('release.json') -or $entries['release.json'].Length -gt 1MB){throw 'Missing or oversized release manifest.'}
        $reader=New-Object IO.StreamReader($entries['release.json'].Open())
        try{$manifest=$reader.ReadToEnd() | ConvertFrom-Json}finally{$reader.Dispose()}
        if($manifest.schema -ne 1 -or $manifest.product -ne 'EpicVM Host' -or $manifest.version -notmatch '^\d+\.\d+\.\d+([.-][a-zA-Z0-9.-]+)?$'){throw 'Unsupported release manifest.'}
        if(-not @($manifest.files).Count){throw 'Empty update package.'}
        $listed=@{}
        foreach($file in $manifest.files){
            if(-not(Test-EpicVMUpdatePath $file.path) -or $file.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $listed.ContainsKey($file.path)){throw 'Invalid or duplicate release file.'}
            if(-not $entries.ContainsKey($file.path)){throw 'Release file is missing.'}
            $listed[$file.path]=$true
        }
        if($listed.Count -ne $entries.Count-1){throw 'Package has unlisted files.'}
        if(Test-Path -LiteralPath $Stage){throw 'Use a new staging directory.'}
        New-Item -ItemType Directory -Path $Stage | Out-Null
        foreach($file in $manifest.files){
            $destination=Join-Path $Stage $file.path
            New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entries[$file.path],$destination)
            if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $file.sha256){throw 'Package integrity check failed.'}
        }
        [IO.File]::WriteAllText((Join-Path $Stage 'release.json'),($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        return $manifest
    }finally{$zip.Dispose()}
}
function Get-EpicVMChangedFiles($Manifest,[string]$Stage,[string]$InstallRoot) {
    Assert-EpicVMPlainPath $InstallRoot
    foreach($file in $Manifest.files){
        $target=Join-Path $InstallRoot $file.path
        Assert-EpicVMPlainPath $target
        if(-not(Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ine $file.sha256){$file}
    }
}
function Get-EpicVMTransactionTarget($File,[string]$InstallRoot,[string]$StateRoot) {
    if($File.stateMirror){
        if($File.path -notmatch '^runtime-code/(host_stream_gateway|direct_stream_auth)\.py$' -or -not $StateRoot){throw 'Invalid mirrored runtime destination.'}
        return Join-Path $StateRoot (Split-Path $File.path -Leaf)
    }
    return Join-Path $InstallRoot $File.path
}
function Invoke-EpicVMFileTransaction($Files,[string]$Stage,[string]$InstallRoot,[string]$Backup,[scriptblock]$Before,[scriptblock]$Verify,[scriptblock]$RestoreServices,[string]$StateRoot) {
    if(Test-Path -LiteralPath $Backup){throw 'Update backup already exists.'}
    New-Item -ItemType Directory -Path $Backup | Out-Null
    $journal=@()
    foreach($file in $Files){
        if(-not(Test-EpicVMUpdatePath $file.path) -and -not($file.path -eq 'release.json' -and $file.metadata) -and -not $file.stateMirror){throw 'Invalid transaction destination.'}
        $target=Get-EpicVMTransactionTarget $file $InstallRoot $StateRoot;Assert-EpicVMPlainPath $target
        $existed=Test-Path -LiteralPath $target
        if($existed){$copy=Join-Path $Backup $file.path;New-Item -ItemType Directory -Path (Split-Path $copy) -Force | Out-Null;Copy-Item -LiteralPath $target -Destination $copy}
        $journal+=@{path=$file.path;stateMirror=[bool]$file.stateMirror;existed=$existed;oldHash=if($existed){(Get-FileHash -LiteralPath $target).Hash}else{$null};newHash=$file.sha256}
    }
    [IO.File]::WriteAllText((Join-Path $Backup 'journal.json'),(ConvertTo-Json -InputObject $journal -Depth 6))
    $applied=@()
    try {
        & $Before
        foreach($file in $Files){
            $source=Join-Path $Stage $file.path;$target=Get-EpicVMTransactionTarget $file $InstallRoot $StateRoot
            if(-not $file.deleteFile -and (Get-FileHash -LiteralPath $source).Hash -ine $file.sha256){throw 'Staged update changed after verification.'}
            $entry=$journal | Where-Object {$_.path -eq $file.path}
            if($entry.existed -and (Get-FileHash -LiteralPath $target).Hash -ne $entry.oldHash){throw 'Installed file changed during update.'}
            New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
            $applied+=,$entry
            if($file.deleteFile){Remove-Item -LiteralPath $target -Force}
            else{Copy-Item -LiteralPath $source -Destination $target -Force;if((Get-FileHash -LiteralPath $target).Hash -ine $file.sha256){throw 'Installed file integrity check failed.'}}
        }
        & $Verify
    }catch{
        $original=$_
        try {
            & $Before
            foreach($entry in $applied){
                $target=Get-EpicVMTransactionTarget $entry $InstallRoot $StateRoot
                if($entry.existed){Copy-Item -LiteralPath (Join-Path $Backup $entry.path) -Destination $target -Force}
                elseif(Test-Path -LiteralPath $target){Remove-Item -LiteralPath $target -Force}
            }
        }finally{& $RestoreServices}
        throw $original
    }
}

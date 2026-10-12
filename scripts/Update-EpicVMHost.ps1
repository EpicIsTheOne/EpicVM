#Requires -RunAsAdministrator
[CmdletBinding()]
param([string]$PackagePath,[string]$ExpectedPackageSha256,[string]$RollbackId,[int]$AgentPid=0,[string]$ResultPath,
      [string]$InstallRoot='C:\Program Files\EpicVM',[string]$StateRoot='C:\ProgramData\EpicVM\host-runtime',
      [string]$UpdateRoot='C:\ProgramData\EpicVM\updates\host-releases')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'HostStorage.ps1')
if(-not $PSBoundParameters.ContainsKey('StateRoot')){$StateRoot=Join-Path (Get-EpicVMDataRoot) 'host-runtime'}
. (Join-Path $PSScriptRoot 'HostUpdates.ps1')
$lock=$null;$transaction=$null;$oldRelease=$null;$releasePath=Join-Path $InstallRoot 'release.json'
$jobId=[Guid]::NewGuid().ToString('N');$job=Join-Path $UpdateRoot $jobId
function Write-UpdateResult($Value){
    $json=$Value | ConvertTo-Json -Depth 8
    if($lock){[IO.File]::WriteAllText((Join-Path $UpdateRoot 'last-update.json'),$json,[Text.UTF8Encoding]::new($false))}
    if($ResultPath){[IO.File]::WriteAllText($ResultPath+'.new',$json,[Text.UTF8Encoding]::new($false));Move-Item -LiteralPath ($ResultPath+'.new') -Destination $ResultPath -Force}
}
try {
    if($ResultPath){
        if([IO.Path]::GetFileName($ResultPath) -notmatch '^epicvm-update-[a-f0-9]{32}\.json$' -or [IO.Path]::GetFullPath((Split-Path $ResultPath)).TrimEnd('\') -ine [IO.Path]::GetTempPath().TrimEnd('\')){throw 'Use a new result file in the updater user temp directory.'}
        Assert-EpicVMPlainPath $ResultPath
        if(Test-Path -LiteralPath $ResultPath){throw 'Update result file already exists.'}
    }
    if([bool]$PackagePath -eq [bool]$RollbackId){throw 'Choose one update package or rollback ID.'}
    Assert-EpicVMPlainPath $InstallRoot;Assert-EpicVMPlainPath $UpdateRoot
    New-Item -ItemType Directory -Path $UpdateRoot -Force | Out-Null
    & icacls.exe $UpdateRoot /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    if($LASTEXITCODE -ne 0){throw 'Could not protect the update directory.'}
    $lock=[IO.File]::Open((Join-Path $UpdateRoot 'update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    New-Item -ItemType Directory -Path $job | Out-Null
    if(Test-Path -LiteralPath $releasePath){$oldRelease=Get-Content -LiteralPath $releasePath -Raw | ConvertFrom-Json;Copy-Item -LiteralPath $releasePath -Destination (Join-Path $job 'previous-release.json')}
    $stage=Join-Path $job 'stage'
    $removals=@()
    if($PackagePath){
        Assert-EpicVMPlainPath $PackagePath
        $protectedPackage=Join-Path $job 'package.zip'
        Copy-Item -LiteralPath $PackagePath -Destination $protectedPackage
        if($ExpectedPackageSha256 -and ($ExpectedPackageSha256 -notmatch '^[a-fA-F0-9]{64}$' -or (Get-FileHash -LiteralPath $protectedPackage).Hash -ine $ExpectedPackageSha256)){throw 'The selected package changed after it was reviewed. No files were installed.'}
        $manifest=Expand-EpicVMUpdate $protectedPackage $stage
        $files=@(Get-EpicVMChangedFiles $manifest $stage $InstallRoot)
        foreach($file in @($manifest.files | Where-Object {$_.path -in @('scripts/host_stream_gateway.py','scripts/direct_stream_auth.py')})){
            $mirror='runtime-code/'+(Split-Path $file.path -Leaf)
            $mirrorTarget=Join-Path $StateRoot (Split-Path $file.path -Leaf);Assert-EpicVMPlainPath $mirrorTarget
            if((Test-Path -LiteralPath $mirrorTarget) -and (Get-FileHash -LiteralPath $mirrorTarget).Hash -ieq $file.sha256){continue}
            New-Item -ItemType Directory -Path (Join-Path $stage 'runtime-code') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $stage $file.path) -Destination (Join-Path $stage $mirror)
            $files+=@{path=$mirror;sha256=$file.sha256;stateMirror=$true}
        }
    }else{
        if($RollbackId -notmatch '^[a-f0-9]{32}$'){throw 'Invalid rollback ID.'}
        $prior=Join-Path $UpdateRoot $RollbackId;Assert-EpicVMPlainPath $prior
        if(-not(Test-Path -LiteralPath (Join-Path $prior 'completed.json'))){throw 'This update is not available for rollback.'}
        $journal=Get-Content -LiteralPath (Join-Path $prior 'backup/journal.json') -Raw | ConvertFrom-Json
        New-Item -ItemType Directory -Path $stage | Out-Null;$files=@()
        foreach($entry in $journal){
            if($entry.path -eq 'release.json'){continue}
            if(-not(Test-EpicVMUpdatePath $entry.path) -and -not $entry.stateMirror){throw 'Invalid rollback destination.'}
            $target=Get-EpicVMTransactionTarget $entry $InstallRoot $StateRoot;Assert-EpicVMPlainPath $target
            if(-not(Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target).Hash -ine $entry.newHash){throw 'Installed files changed since this update. Refusing an unsafe rollback.'}
            if($entry.existed){
                $source=Join-Path $prior ('backup/'+$entry.path)
                if((Get-FileHash -LiteralPath $source).Hash -ine $entry.oldHash){throw 'Rollback backup integrity check failed.'}
                $destination=Join-Path $stage $entry.path;New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
                Copy-Item -LiteralPath $source -Destination $destination
                $files+=@{path=$entry.path;sha256=$entry.oldHash;stateMirror=$entry.stateMirror}
            }else{$removals+=@{path=$entry.path;deleteFile=$true;sha256=$null;stateMirror=$entry.stateMirror}}
        }
        $manifest=if(Test-Path -LiteralPath (Join-Path $prior 'previous-release.json')){Get-Content -LiteralPath (Join-Path $prior 'previous-release.json') -Raw | ConvertFrom-Json}else{@{version='legacy';files=@()}}
    }
    $impact=Get-EpicVMUpdateImpact (@($files | ForEach-Object {$_.path})+@($removals | ForEach-Object {$_.path}))
    if(@(($files+$removals) | Where-Object {$_.stateMirror}).Count){$impact='desktops-must-end'}
    [IO.File]::WriteAllText((Join-Path $stage 'release.json'),($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    $files+=@{path='release.json';sha256=(Get-FileHash -LiteralPath (Join-Path $stage 'release.json')).Hash;metadata=$true}
    if($impact -eq 'desktops-must-end'){
        $key=[IO.File]::ReadAllText('C:\ProgramData\MultiSeat\api-key.txt').Trim()
        $seats=Invoke-RestMethod -Uri 'http://127.0.0.1:9550/api/seats/' -Headers @{'X-MultiSeat-Key'=$key} -TimeoutSec 10
        $key=$null;if(@($seats).Count){throw 'End active desktops before installing or rolling back an update that changes streaming code. No desktops were ended.'}
    }
    if($AgentPid){
        $agent=Get-Process -Id $AgentPid -ErrorAction SilentlyContinue
        if($agent -and $agent.Path -ne (Join-Path $InstallRoot 'ui/EpicVM.Agent.exe')){throw 'Unexpected Agent process.'}
        if($agent -and -not $agent.WaitForExit(60000)){throw 'Close the Agent before updating. No files were changed.'}
    }
    if(@(Get-Process EpicVM.Agent -ErrorAction SilentlyContinue | Where-Object {$_.Path -eq (Join-Path $InstallRoot 'ui/EpicVM.Agent.exe')}).Count){throw 'Close every Agent window before updating.'}
    $services=@();if($impact -ne 'agent-only'){$services+='EpicVMHostControl'};if($impact -eq 'desktops-must-end'){$services+='EpicVMHostRuntime'}
    $wasRunning=@($services | Where-Object {(Get-Service $_).Status -eq 'Running'})
    $stop={
        foreach($name in $services){if((Get-Service $name).Status -ne 'Stopped'){Stop-Service $name -ErrorAction Stop;(Get-Service $name).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))}}
        if($impact -eq 'desktops-must-end'){
            $gatewayPath=Join-Path $StateRoot 'host_stream_gateway.py';$pythonPath=Join-Path $InstallRoot 'python/python.exe'
            foreach($process in Get-CimInstance Win32_Process -Filter "Name='python.exe'"){
                if($process.ExecutablePath -ieq $pythonPath -and $process.CommandLine -match ('(?:^|[ "''])'+[regex]::Escape($gatewayPath)+'(?:[ "'']|$)')){Stop-Process -Id $process.ProcessId -ErrorAction Stop}
            }
        }
    }
    $start={foreach($name in $wasRunning){Start-Service $name -ErrorAction Stop;(Get-Service $name).WaitForStatus('Running',[TimeSpan]::FromSeconds(30))}}
    $verify={
        & $start
        if($impact -eq 'desktops-must-end' -and $wasRunning -contains 'EpicVMHostRuntime'){
            $healthy=$false
            foreach($attempt in 1..15){try{$response=Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:8090/health' -TimeoutSec 2;if($response.StatusCode -eq 200){$healthy=$true;break}}catch{};Start-Sleep -Seconds 2}
            if(-not $healthy){throw 'Updated streaming gateway did not become healthy.'}
        }
        if((Get-Service EpicVMHostControl).Status -eq 'Running'){
            $probePath=Join-Path $job 'probe.json'
            $probe=Start-Process (Join-Path $InstallRoot 'ui/EpicVM.Agent.exe') -ArgumentList '--status-file',$probePath -WindowStyle Hidden -Wait -PassThru
            if($probe.ExitCode -ne 0){throw 'Updated Agent could not read host control.'}
            Remove-Item -LiteralPath $probePath
        }
    }
    Invoke-EpicVMFileTransaction ($files+$removals) $stage $InstallRoot (Join-Path $job 'backup') $stop $verify $start $StateRoot
    $result=@{id=$jobId;status='succeeded';version=$manifest.version;message=if($RollbackId){'Rollback completed.'}else{'Update installed.'};impact=$impact;rollbackAvailable=(-not $RollbackId -and $files.Count -gt 0);finishedAt=[DateTimeOffset]::UtcNow.ToString('O')}
    [IO.File]::WriteAllText((Join-Path $job 'completed.json'),($result | ConvertTo-Json))
    [IO.File]::WriteAllText((Join-Path $UpdateRoot 'last-successful-update.json'),($result | ConvertTo-Json))
    Write-UpdateResult $result
    Write-Output $result.message
}catch{
    if(Test-Path -LiteralPath $UpdateRoot){Write-UpdateResult @{id=$jobId;status='failed';message=$_.Exception.Message;rollbackAvailable=$false;finishedAt=[DateTimeOffset]::UtcNow.ToString('O')}}
    throw
}finally{if($lock){$lock.Dispose()}}

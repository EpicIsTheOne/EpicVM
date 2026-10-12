BeforeAll {
    . (Join-Path $PSScriptRoot '../HostUpdates.ps1')
    function Make-Package($Path,$Destination='ui/EpicVM.Agent.dll',$Content='candidate',$Expected=$null) {
        $zip=[IO.Compression.ZipFile]::Open($Path,[IO.Compression.ZipArchiveMode]::Create)
        try {
            $entry=$zip.CreateEntry($Destination);$writer=New-Object IO.StreamWriter($entry.Open());try{$writer.Write($Content)}finally{$writer.Dispose()}
            $hash=if($Expected){$Expected}else{[BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Content))).Replace('-','').ToLowerInvariant()}
            $manifest=@{schema=1;product='EpicVM Host';version='0.1.0';files=@(@{path=$Destination;sha256=$hash})}
            $entry=$zip.CreateEntry('release.json');$writer=New-Object IO.StreamWriter($entry.Open());try{$writer.Write(($manifest|ConvertTo-Json -Depth 8))}finally{$writer.Dispose()}
        }finally{$zip.Dispose()}
    }
}
Describe 'Release package boundaries' {
    It 'validates and stages a release with matching hashes' {
        $zip=Join-Path $TestDrive 'good.zip';Make-Package $zip
        $manifest=Expand-EpicVMUpdate $zip (Join-Path $TestDrive 'stage-good')
        $manifest.version | Should -Be '0.1.0'
        Get-Content (Join-Path $TestDrive 'stage-good/ui/EpicVM.Agent.dll') | Should -Be 'candidate'
    }
    It 'rejects corrupted payload before any installation' {
        $zip=Join-Path $TestDrive 'bad.zip';Make-Package $zip -Expected ('0'*64)
        {Expand-EpicVMUpdate $zip (Join-Path $TestDrive 'stage-bad')} | Should -Throw '*integrity*'
    }
    It 'rejects traversal and private destinations' {
        foreach($path in @('ui/../outside.dll','ui/./wrong.dll','C:/Windows/test','scripts/signing.key','host-runtime/sync.token','ui/test:stream','ui/test\other')){Test-EpicVMUpdatePath $path | Should -BeFalse}
    }
    It 'classifies restart impact deterministically' {
        Get-EpicVMUpdateImpact @('ui/EpicVM.Agent.dll') | Should -Be 'agent-only'
        Get-EpicVMUpdateImpact @('control/EpicVM.Control.dll') | Should -Be 'control-restart'
        Get-EpicVMUpdateImpact @('scripts/host_runtime.py') | Should -Be 'desktops-must-end'
        Get-EpicVMUpdateImpact @('scripts/Update-EpicVMHost.ps1') | Should -Be 'agent-only'
    }
    It 'ignores unchanged installed payloads' {
        $root=Join-Path $TestDrive 'same';New-Item -ItemType Directory -Path (Join-Path $root 'ui') -Force | Out-Null
        $file=Join-Path $root 'ui/Agent.dll';[IO.File]::WriteAllText($file,'same')
        $manifest=@{files=@(@{path='ui/Agent.dll';sha256=(Get-FileHash $file).Hash})}
        @(Get-EpicVMChangedFiles $manifest $root $root).Count | Should -Be 0
    }
}
Describe 'File update transactions' {
    BeforeEach {
        $root=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'));$stage=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'));$backup=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'ui'),(Join-Path $stage 'ui') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'ui/Agent.dll'),'previous')
        [IO.File]::WriteAllText((Join-Path $stage 'ui/Agent.dll'),'next')
        [IO.File]::WriteAllText((Join-Path $stage 'ui/new.dll'),'new')
        [IO.File]::WriteAllText((Join-Path $root 'private.key'),'private sentinel')
        $files=@(@{path='ui/Agent.dll';sha256=(Get-FileHash (Join-Path $stage 'ui/Agent.dll')).Hash},@{path='ui/new.dll';sha256=(Get-FileHash (Join-Path $stage 'ui/new.dll')).Hash})
    }
    It 'backs up replaced files and preserves private state' {
        Invoke-EpicVMFileTransaction $files $stage $root $backup {} {} {}
        Get-Content (Join-Path $root 'ui/Agent.dll') | Should -Be 'next'
        Get-Content (Join-Path $backup 'ui/Agent.dll') | Should -Be 'previous'
        Get-Content (Join-Path $root 'private.key') | Should -Be 'private sentinel'
    }
    It 'restores old files and removes newly created files after verification failure' {
        {Invoke-EpicVMFileTransaction $files $stage $root $backup {} {throw 'probe failed'} {}} | Should -Throw '*probe failed*'
        Get-Content (Join-Path $root 'ui/Agent.dll') | Should -Be 'previous'
        Test-Path (Join-Path $root 'ui/new.dll') | Should -BeFalse
        Get-Content (Join-Path $root 'private.key') | Should -Be 'private sentinel'
    }
    It 'refuses a staged file changed after package verification' {
        [IO.File]::WriteAllText((Join-Path $stage 'ui/Agent.dll'),'tampered')
        {Invoke-EpicVMFileTransaction $files $stage $root $backup {} {} {}} | Should -Throw '*changed after verification*'
        Get-Content (Join-Path $root 'ui/Agent.dll') | Should -Be 'previous'
    }
    It 'rolls metadata back together with binaries' {
        [IO.File]::WriteAllText((Join-Path $root 'release.json'),'old version')
        [IO.File]::WriteAllText((Join-Path $stage 'release.json'),'new version')
        $files+=@{path='release.json';metadata=$true;sha256=(Get-FileHash (Join-Path $stage 'release.json')).Hash}
        {Invoke-EpicVMFileTransaction $files $stage $root $backup {} {throw 'unhealthy'} {}} | Should -Throw
        Get-Content (Join-Path $root 'release.json') | Should -Be 'old version'
    }
    It 'updates only the two mirrored code files and restores them on failure' {
        $state=Join-Path $TestDrive ([Guid]::NewGuid().ToString('N'));New-Item -ItemType Directory -Path $state,(Join-Path $stage 'runtime-code') | Out-Null
        [IO.File]::WriteAllText((Join-Path $state 'host_stream_gateway.py'),'old gateway')
        [IO.File]::WriteAllText((Join-Path $state 'signing.key'),'preserve key')
        [IO.File]::WriteAllText((Join-Path $stage 'runtime-code/host_stream_gateway.py'),'new gateway')
        $files+=@{path='runtime-code/host_stream_gateway.py';stateMirror=$true;sha256=(Get-FileHash (Join-Path $stage 'runtime-code/host_stream_gateway.py')).Hash}
        {Invoke-EpicVMFileTransaction $files $stage $root $backup {} {throw 'probe failed'} {} $state} | Should -Throw
        Get-Content (Join-Path $state 'host_stream_gateway.py') | Should -Be 'old gateway'
        Get-Content (Join-Path $state 'signing.key') | Should -Be 'preserve key'
        {Get-EpicVMTransactionTarget @{path='runtime-code/signing.key';stateMirror=$true} $root $state} | Should -Throw
    }
}

[CmdletBinding()]
param([Parameter(Mandatory)][string]$PackageRoot,[Parameter(Mandatory)][string]$OutputPath,[string]$Version='0.1.0',[switch]$IncludeRuntime)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'HostUpdates.ps1')
if(Test-Path -LiteralPath $OutputPath){throw 'Choose a new package output path.'}
$files=@()
foreach($directory in @('ui','control')){
    foreach($file in Get-ChildItem -LiteralPath (Join-Path $PackageRoot $directory) -File -Recurse){
        $relative=$file.FullName.Substring([IO.Path]::GetFullPath($PackageRoot).TrimEnd('\').Length+1).Replace('\','/')
        if(-not(Test-EpicVMUpdatePath $relative)){throw 'Unsupported package file.'}
        $files+=@{path=$relative;sha256=(Get-FileHash -LiteralPath $file.FullName).Hash.ToLowerInvariant()}
    }
}
$maintenance=@('HostStorage.ps1','HostUpdates.ps1','Update-EpicVMHost.ps1','Setup-EpicVMHost.ps1','Install-EpicVMHostRuntime.ps1','agent_update_wait.py','WINDOWS-HOST-UPDATES.md')
$runtime=@('local_lan.py','host_runtime.py','manage_host_runtime.py','supervise_host_direct_streams.py','provision_direct_stream.py','host_stream_gateway.py','direct_stream_auth.py','write_direct_stream_caddy.py','Start-EpicVMLocalGateway.ps1','stream_recovery.js','stream_network.js')
foreach($name in ($maintenance+$(if($IncludeRuntime){$runtime}else{@()}))){
    $file=Join-Path $PackageRoot ('scripts/'+$name)
    $files+=@{path='scripts/'+$name;sha256=(Get-FileHash -LiteralPath $file).Hash.ToLowerInvariant()}
}
$manifest=@{schema=1;product='EpicVM Host';version=$Version;createdAt=[DateTimeOffset]::UtcNow.ToString('O');files=$files}
if($Version -notmatch '^\d+\.\d+\.\d+([.-][a-zA-Z0-9.-]+)?$'){throw 'Invalid release version.'}
$archive=[IO.Compression.ZipFile]::Open([IO.Path]::GetFullPath($OutputPath),[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach($file in $files){[IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,(Join-Path $PackageRoot $file.path),$file.path,[IO.Compression.CompressionLevel]::Optimal) | Out-Null}
    $entry=$archive.CreateEntry('release.json');$writer=New-Object IO.StreamWriter($entry.Open(),[Text.UTF8Encoding]::new($false))
    try{$writer.Write(($manifest | ConvertTo-Json -Depth 8))}finally{$writer.Dispose()}
}finally{$archive.Dispose()}
Write-Output ('Created EpicVM Host '+$Version+' update package. No host credentials or private state included.')

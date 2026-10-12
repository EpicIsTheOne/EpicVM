BeforeAll {
 Import-Module "$PSScriptRoot/../scripts/HostComponents.psm1" -Force
 Add-Type -AssemblyName System.IO.Compression.FileSystem
 function ZipFixture($path,$entries){$zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create);try{foreach($name in $entries){$e=$zip.CreateEntry($name);$w=New-Object IO.StreamWriter($e.Open());$w.Write('fixture');$w.Dispose()}}finally{$zip.Dispose()}}
}
Describe 'Verified host component installation' {
 It 'rejects traversal and duplicate archive entries before extraction' {
  foreach($names in @(@('../outside.exe'),@('app.exe','APP.exe'),@('/absolute.exe'),@('C:/outside.exe'))){
   $zip=Join-Path $TestDrive ([guid]::NewGuid().ToString('N')+'.zip');ZipFixture $zip $names
   {Expand-EpicVMComponentArchive $zip (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))} | Should -Throw
  }
  Test-Path (Join-Path $TestDrive 'outside.exe') | Should -BeFalse
 }
 It 'extracts ordinary component files inside the destination' {
  $zip=Join-Path $TestDrive 'good.zip';ZipFixture $zip @('payload/app.exe','LICENSE')
  $dest=Expand-EpicVMComponentArchive $zip (Join-Path $TestDrive 'good')
  Get-Content (Join-Path $dest 'payload/app.exe') | Should -Be 'fixture'
 }
 It 'rejects a modified download and unknown installer publisher' {
  $path=Join-Path $TestDrive 'installer.exe';Set-Content $path 'fixture'
  $asset=[pscustomobject]@{sha256=(Get-FileHash $path).Hash.ToLowerInvariant();kind='zip'}
  Test-EpicVMComponentAsset $asset $path | Should -BeTrue
  Add-Content $path 'tamper';Test-EpicVMComponentAsset $asset $path | Should -BeFalse
  $asset=[pscustomobject]@{sha256=(Get-FileHash $path).Hash.ToLowerInvariant();kind='installer';publisher='Nefarius'}
  InModuleScope HostComponents -Parameters @{asset=$asset;path=$path} {
   Mock Get-AuthenticodeSignature { @{Status='Valid';SignerCertificate=@{Subject='CN=Unrelated Vendor'}} }
   Test-EpicVMComponentAsset $asset $path | Should -BeFalse
  }
 }
 It 'rejects a locally rewritten release lock' {
  $path=Join-Path $TestDrive 'lock.json';Set-Content $path '{"schema":1,"architecture":"x64","components":[]}'
  {Read-EpicVMComponentLock $path} | Should -Throw '*supported release*'
 }
 It 'handles driver reboot exit codes and refuses failed installers' {
  InModuleScope HostComponents {
   Mock Start-Process { @{ExitCode=3010} }
   (Invoke-EpicVMVerifiedDriverInstaller 'fixture.exe').rebootRequired | Should -BeTrue
   Mock Start-Process { @{ExitCode=1603} }
   {Invoke-EpicVMVerifiedDriverInstaller 'fixture.exe'} | Should -Throw '*1603*'
  }
 }
}

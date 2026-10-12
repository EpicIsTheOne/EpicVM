BeforeAll { . "$PSScriptRoot/../scripts/Start-EpicVMRoblox.ps1" -NoStart }
Describe 'Per-account Roblox desktop launcher' {
    It 'discovers each app only in the provided account payload directory' {
        $root=Join-Path $TestDrive 'Versions'
        New-Item -ItemType Directory -Force (Join-Path $root 'old'),(Join-Path $root 'new') | Out-Null
        Set-Content (Join-Path $root 'old/RobloxStudioBeta.exe') 'studio'
        Set-Content (Join-Path $root 'new/RobloxPlayerBeta.exe') 'player'
        Find-EpicVMRobloxExecutable -App Studio -VersionsRoot $root | Should -Be (Join-Path $root 'old/RobloxStudioBeta.exe')
        Find-EpicVMRobloxExecutable -App Player -VersionsRoot $root | Should -Be (Join-Path $root 'new/RobloxPlayerBeta.exe')
        Find-EpicVMRobloxExecutable -App Player -VersionsRoot (Join-Path $TestDrive 'other-account') | Should -BeNullOrEmpty
    }
    It 'rejects unsigned installers and other publishers' {
        Mock Get-AuthenticodeSignature { @{Status='Valid';SignerCertificate=@{Subject='CN=Someone, O=Someone'}} }
        Test-EpicVMRobloxPublisher 'fixture.exe' | Should -BeFalse
        Mock Get-AuthenticodeSignature { @{Status='NotSigned';SignerCertificate=@{Subject='O=Roblox Corporation'}} }
        Test-EpicVMRobloxPublisher 'fixture.exe' | Should -BeFalse
        Mock Get-AuthenticodeSignature { @{Status='Valid';SignerCertificate=@{Subject='CN=Roblox Corporation, O=Roblox Corporation, C=US'}} }
        Test-EpicVMRobloxPublisher 'fixture.exe' | Should -BeTrue
    }
}

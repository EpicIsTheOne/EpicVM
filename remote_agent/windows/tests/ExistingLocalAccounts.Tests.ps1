BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'EpicVM.Agent.ps1') -NoStart
}
Describe 'Existing local Windows account boundary' {
    BeforeEach {
        Mock Get-EpicVMExistingAccountMappings { @{'portal:alice'=@{accountName='FriendDesktop';accountSid='S-1-5-21-123-1001'}} }
        Mock Get-LocalUser { [pscustomobject]@{Name='FriendDesktop';Enabled=$true;PrincipalSource='Local'} }
        Mock Get-EpicVMHostGamingView { @{ready=$true;supportsExistingLocalAccounts=$true;seats=@(@{id='fixture';accountName='FriendDesktop';status='Ready';portBase=48100})} }
        Mock Invoke-EpicVMMultiSeat { throw 'Unexpected seat request' }
        Mock Get-EpicVMApolloAuth { @{password='fixture'} }
    }
    It 'rejects an account converted to Microsoft authentication' {
        Mock Get-LocalUser { [pscustomobject]@{Name='FriendDesktop';Enabled=$true;PrincipalSource='MicrosoftAccount'} }
        { Get-EpicVMHostGamingAccount 'portal:alice' } | Should -Throw '*changed or is unavailable*'
    }
    It 'rejects a renamed or replaced Windows account' {
        Mock Get-LocalUser { [pscustomobject]@{Name='Changed';Enabled=$true;PrincipalSource='Local'} }
        { Get-EpicVMHostGamingAccount 'portal:alice' } | Should -Throw '*changed or is unavailable*'
    }
    It 'requires the password even with a ready desktop' {
        { Start-EpicVMHostDesktop @{owner='portal:alice';accountSid='S-1-5-21-123-1001'} } | Should -Throw '*Windows password*'
        Should -Invoke Invoke-EpicVMMultiSeat -Times 0
    }
    It 'refuses stale server assignments' {
        { Start-EpicVMHostDesktop @{owner='portal:alice';accountSid='S-1-5-21-123-1002';windowsPassword='fixture'} } | Should -Throw '*assignment changed*'
        Should -Invoke Invoke-EpicVMMultiSeat -Times 0
    }
    It 'authenticates ready-seat reuse through the temporary credential endpoint' {
        Mock Invoke-EpicVMMultiSeat { @{id='fixture';accountName='FriendDesktop';status='Ready';portBase=48100} } -ParameterFilter {$Method -eq 'POST' -and $Path -eq '/api/seats/epicvm-existing' -and $Payload.password -eq 'fixture' -and $Payload.accountSid -eq 'S-1-5-21-123-1001'}
        $request = @{owner='portal:alice';accountSid='S-1-5-21-123-1001';windowsPassword='fixture'}
        (Start-EpicVMHostDesktop $request).seatId | Should -Be 'fixture'
        $request.windowsPassword | Should -BeNullOrEmpty
        Should -Invoke Invoke-EpicVMMultiSeat -Times 1
    }
    It 'rejects assigning an account while the old desktop is running' {
        { Set-EpicVMExistingAccountAssignment @{owner='portal:alice';accountSid=''} } | Should -Throw '*End the affected*'
    }
    It 'never reveals an existing account password' {
        { Reveal-EpicVMHostAccountCredential @{owner='portal:alice'} } | Should -Throw '*never saved or revealed*'
        Should -Invoke Invoke-EpicVMMultiSeat -Times 0
    }
    It 'recovers an assigned local seat after verifying its SID' {
        Mock Get-LocalUser { [pscustomobject]@{Name='FriendDesktop';SID=[pscustomobject]@{Value='S-1-5-21-123-1001'}} }
        Mock Get-EpicVMHostGamingView { @{seats=@(@{id='11111111-1111-1111-1111-111111111111';accountName='FriendDesktop'})} }
        Mock Invoke-EpicVMMultiSeat { $null } -ParameterFilter {$Method -eq 'DELETE'}
        (Recover-EpicVMHostGaming @{seatId='11111111-1111-1111-1111-111111111111'}).status | Should -Be 'recovered'
        Should -Invoke Invoke-EpicVMMultiSeat -Times 1 -ParameterFilter {$Method -eq 'DELETE'}
    }
    It 'refuses recovery when the mapped SID no longer owns the account' {
        Mock Get-LocalUser { $null }
        Mock Get-EpicVMHostGamingView { @{seats=@(@{id='11111111-1111-1111-1111-111111111111';accountName='FriendDesktop'})} }
        { Recover-EpicVMHostGaming @{seatId='11111111-1111-1111-1111-111111111111'} } | Should -Throw '*not managed*'
        Should -Invoke Invoke-EpicVMMultiSeat -Times 0
    }
    It 'keeps unrelated local accounts outside EpicVM ownership' {
        (Test-EpicVMHostSeatOwnership 'UnassignedLocal') | Should -BeFalse
        (Test-EpicVMHostSeatOwnership 'EpicVM_alice') | Should -BeTrue
    }
}

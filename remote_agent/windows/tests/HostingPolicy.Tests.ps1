BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'EpicVM.Agent.ps1') -NoStart
}
Describe 'Local operator hosting policy' {
    BeforeEach {
        $script:HostingPolicyFile = Join-Path $TestDrive 'hosting-policy.json'
        Mock Get-EpicVMHostGamingAccount { 'EpicVM_alice' }
        Mock Get-EpicVMExistingAccountAssignment { $null }
        Mock Get-EpicVMHostGamingView { @{ready=$true;seats=@()} }
        Mock Invoke-EpicVMMultiSeat { throw 'No mutation expected' }
    }
    It 'keeps the previous unlimited default when no policy exists' {
        (Get-EpicVMHostingPolicy).maxSeats | Should -Be 0
        (Get-EpicVMHostingPolicy).paused | Should -BeFalse
    }
    It 'refuses a new seat while paused without creating accounts' {
        '{"paused":true}' | Set-Content $script:HostingPolicyFile
        { Start-EpicVMHostDesktop @{owner='portal:alice'} } | Should -Throw '*paused*'
        Should -Invoke Invoke-EpicVMMultiSeat -Times 0
    }
    It 'enforces the configured limit at the host boundary' {
        '{"maxSeats":1}' | Set-Content $script:HostingPolicyFile
        Mock Get-EpicVMHostGamingView { @{ready=$true;seats=@(@{accountName='EpicVM_bob';status='Ready'})} }
        { Start-EpicVMHostDesktop @{owner='portal:alice'} } | Should -Throw '*limit*'
        Should -Invoke Invoke-EpicVMMultiSeat -Times 0
    }
    It 'permits reconnect to an existing seat while paused and at capacity' {
        '{"paused":true,"maxSeats":1}' | Set-Content $script:HostingPolicyFile
        Mock Get-EpicVMHostGamingView { @{ready=$true;seats=@(@{accountName='EpicVM_alice';status='Ready';id='fixture';portBase=48100})} }
        Mock Invoke-EpicVMMultiSeat { @{accountName='EpicVM_alice';status='Ready';id='fixture';portBase=48100} } -ParameterFilter {$Method -eq 'GET'}
        Mock Get-EpicVMApolloAuth { @{password='fixture'} }
        (Start-EpicVMHostDesktop @{owner='portal:alice'}).seatId | Should -Be 'fixture'
        Should -Invoke Invoke-EpicVMMultiSeat -Times 0 -ParameterFilter {$Method -ne 'GET'}
    }
}

Describe 'Hosting policy status' {
    BeforeEach {
        $script:HostingPolicyFile = Join-Path $TestDrive 'view-policy.json'
        '{"paused":true,"maxSeats":1}' | Set-Content $script:HostingPolicyFile
        Mock Get-Service { @{Status='Running'} }
        Mock Get-EpicVMHostGamingCatalog { @() }
        Mock Test-EpicVMHostSeatOwnership { $true }
        Mock Invoke-EpicVMMultiSeat {
            switch ($Path) {
                '/api/system/auth' { @{authEnabled=$true} }
                '/api/system/displays' { @{sudoVdaFound=$true} }
                '/api/seats/' { @(@{id='fixture';accountName='EpicVM_alice';status='Ready';portBase=48100;sessionId=2;errorMessage=$null}) }
                '/api/accounts/epicvm-existing-support' { @{ephemeralCredentials=$true} }
            }
        }
    }
    It 'reports paused, occupied, and full using the enforced seat count' {
        $result = Get-EpicVMHostGamingView
        $result.hosting.paused | Should -BeTrue
        $result.hosting.full | Should -BeTrue
        $result.hosting.seatCount | Should -Be 1
        $result.hosting.maxSeats | Should -Be 1
        $result.ready | Should -BeTrue
    }
    It 'reports an unlimited host without claiming it is full' {
        '{"paused":false,"maxSeats":0}' | Set-Content $script:HostingPolicyFile
        (Get-EpicVMHostGamingView).hosting.full | Should -BeFalse
    }
}

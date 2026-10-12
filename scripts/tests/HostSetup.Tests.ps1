BeforeAll {
    $setup=Join-Path $PSScriptRoot '../Setup-EpicVMHost.ps1'
    function Get-LocalUser { param($Name) @{Name=$Name} }
    function Get-Service { param($Name) if($Name -eq 'EpicVMHostRuntime'){return $null};@{Status='Running'} }
}
Describe 'Host setup preflight' {
    It 'rejects incomplete configuration before installation' {
        $config=Join-Path $TestDrive 'missing.json';'{}' | Set-Content $config
        {& $setup -ConfigurationFile $config -PackageRoot $TestDrive -CheckOnly} | Should -Throw '*Missing setup setting*'
    }
    It 'rejects credentials in host origins before installation' {
        $config=Join-Path $TestDrive 'invalid.json'
        @{operatorName='Operator';hostId='host';portalOrigin='https://user:password@example.com';publicOrigin='https://host.example.com';stateBundle=$TestDrive} | ConvertTo-Json | Set-Content $config
        {& $setup -ConfigurationFile $config -PackageRoot $TestDrive -CheckOnly} | Should -Throw '*HTTPS host origins*'
    }
    It 'reports missing enrollment/package prerequisites without creating install folders' {
        $config=Join-Path $TestDrive 'preflight.json'
        @{operatorName='Operator';hostId='host';portalOrigin='https://portal.example.com';publicOrigin='https://host.example.com';stateBundle=$TestDrive} | ConvertTo-Json | Set-Content $config
        {& $setup -ConfigurationFile $config -PackageRoot $TestDrive -CheckOnly} | Should -Throw '*Host package is missing*'
    }
    It 'all update and setup scripts parse in Windows PowerShell syntax' {
        foreach($name in @('HostUpdates.ps1','Update-EpicVMHost.ps1','Setup-EpicVMHost.ps1','New-EpicVMHostUpdatePackage.ps1')){
            $errors=$null;$tokens=$null;[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot ('../'+$name)),[ref]$tokens,[ref]$errors) | Out-Null
            @($errors).Count | Should -Be 0
        }
    }
}

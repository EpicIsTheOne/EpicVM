BeforeAll { . "$PSScriptRoot/../remote_agent/windows/EpicVM.Agent.ps1" -NoStart }
Describe 'Multiseat-only adapter profile' {
 It 'reports no VM creation and lists no VMs without Hyper-V' {
   $provider=New-EpicVMProvider -Config @{Provider='MultiSeat'}
   $caps=Get-EpicVMProviderCapabilities $provider
   $caps.provider | Should -Be 'multiseat'
   $caps.create_vm | Should -BeFalse
   @(& $provider.GetVMs).Count | Should -Be 0
   { & $provider.CreateVM @{} } | Should -Throw '*disabled*'
   $state=New-EpicVMAgentState -Config @{Provider='MultiSeat';VmRoot='C:\EpicVM'} -Token 'fixture-token' -Provider $provider
   $state.Provisioning | Should -BeNullOrEmpty
   (Invoke-EpicVMApiRequest -State $state -Method POST -Path '/v1/vms' -Headers @{Authorization='Bearer fixture-token'} -Body @{}).StatusCode | Should -Be 403
 }
}

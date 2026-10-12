$storageSource=Join-Path $PSScriptRoot 'HostStorage.ps1'
if(Test-Path -LiteralPath $storageSource){. $storageSource}
$script:HostingPolicyFile = if(Get-Command Get-EpicVMDataRoot -ErrorAction SilentlyContinue){Join-Path (Get-EpicVMDataRoot) 'host-runtime\hosting-policy.json'}else{'C:\ProgramData\EpicVM\host-runtime\hosting-policy.json'}
function Get-EpicVMHostingPolicy {
    $defaults = @{paused=$false;maxSeats=0;width=1920;height=1080;fps=60}
    if (Test-Path -LiteralPath $script:HostingPolicyFile) {
        $policy = Get-Content -LiteralPath $script:HostingPolicyFile -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        foreach ($key in @($defaults.Keys)) { if ($policy.ContainsKey($key)) { $defaults[$key] = $policy[$key] } }
    }
    return $defaults
}

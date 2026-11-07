# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Checks, source by source, that the SharePoint storage of the target absorbs the data, margin included (procedure CMP-CAPACITY).

.DESCRIPTION
    Uses the real quota read in sharePointSettings (StorageQuota, in MB), not the estimate of the capacity check (1 TB plus 10 GB per license).
    Used: sum of the sites table of the target. Need: sites of the source, minus the sites excluded by SPO-INACTIVE, plus the
    StorageMarginPercent setting. OneDrives do not count in this quota.
    Read only: a CSV for the customer. In an -Apply run, the script reads the real quota on the target again and redoes the calculation.
    Limit: the usage shown does not include the changes of the last 24 to 48 hours, and the source grows until the cutover.
#>
$c = Open-TcRemediation

$InactiveFile = 'SPO-INACTIVE'
$excludedItems = @{}
if (Test-TcDecisionFile $InactiveFile) {
    foreach ($l in Read-TcDecisionRow $InactiveFile) { if ((Get-TcMember $l 'Decision') -in 'Read only', 'Archive', 'Delete') { $excludedItems[((Get-TcText $l 'Site')).TrimEnd('/').ToLowerInvariant()] = 1 } }
}

function Get-SiteTotalMb {
    param([string]$Target)
    $m = (Get-TcMember (@(Get-TcRemediationTable $Target 'sites' | Where-Object { -not $excludedItems[([string]$_['Url']).TrimEnd('/').ToLowerInvariant()] } | ForEach-Object { [double]$_['Storage MB'] }) | Measure-Object -Sum) 'Sum')
    return [double]$(if ($m) { $m } else { 0 })
}

$MarginPercent = [double](Get-TcRemediationOption 'StorageMarginPercent')
$quotaMb = [double](Get-TcRemediationValue 'Target' 'sharePointSettings' 'StorageQuota' 0)
$usedMb = Get-SiteTotalMb 'Target'

$rows = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $sourceMb = Get-SiteTotalMb $t
    $needMb = $sourceMb * (1 + $MarginPercent / 100)
    $freeMb = $quotaMb - $usedMb
    Write-TcRemediationNote ("Real quota of the target: {0:N0} GB, used {1:N0} GB, free {2:N0} GB" -f ($quotaMb / 1024), ($usedMb / 1024), ($freeMb / 1024))
    Write-TcRemediationNote ("Source: {0:N0} GB, need with {1} % margin: {2:N0} GB" -f ($sourceMb / 1024), $MarginPercent, ($needMb / 1024))
    if ($quotaMb -le 0) { Write-TcRemediationAlert 'Real quota missing from sharePointSettings: run the SharePoint collection again' }
    elseif ($needMb -gt $freeMb) { Write-TcRemediationAlert ("Not enough capacity: {0:N0} GB short. The customer must buy storage or exclude sites" -f (($needMb - $freeMb) / 1024)) }
    [pscustomobject]@{ Source = $t; 'Target quota GB' = [math]::Round($quotaMb / 1024, 1); 'Target used GB' = [math]::Round($usedMb / 1024, 1); 'Free GB' = [math]::Round($freeMb / 1024, 1)
                       'Source GB' = [math]::Round($sourceMb / 1024, 1); 'Margin %' = $MarginPercent; 'Need GB' = [math]::Round($needMb / 1024, 1); Enough = $(if ($needMb -le $freeMb) { 'Yes' } else { 'No' }) }
}
Export-TcRemediationReport -Name 'capacity-by-source' -Rows @($rows) | Out-Null

Invoke-TcRemediationPlan -Verify {
    param($t)
    $realMb = [double](Get-TcMember (Invoke-TcServiceCommand -Tenant 'Target' -Service Pnp -Command 'Get-PnPTenant') 'StorageQuota')
    $needMb = (Get-SiteTotalMb $t) * (1 + $MarginPercent / 100)
    if ($needMb -le ($realMb - $usedMb)) { New-TcRemediationResult OK ("quota read {0:N0} GB: the need of {1:N0} GB fits" -f ($realMb / 1024), ($needMb / 1024)) }
    else { New-TcRemediationResult Blocking ("quota read {0:N0} GB: the need of {1:N0} GB does not fit" -f ($realMb / 1024), ($needMb / 1024)) }
}
Close-TcRemediation

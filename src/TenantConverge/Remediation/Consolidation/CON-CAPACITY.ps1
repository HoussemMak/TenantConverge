# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Adds up the SharePoint capacity of all sources and has the customer answer confirmed (procedure CON-CAPACITY).

.DESCRIPTION
    The capacity check handles one source at a time: only the total gives the true picture if pre-copies move in parallel.
    Same calculation as CMP-CAPACITY, on all sources, with the real quota of the target and the StorageMarginPercent setting.
    Read only: a CSV, and a row to decide in decisions\CON-CAPACITY.csv to keep the customer answer.
    Redo it if the exclusions, volumes or licenses change.
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
$Sources = @(Get-TcSourceRole)
$quotaMb = [double](Get-TcRemediationValue 'Target' 'sharePointSettings' 'StorageQuota' 0)
$usedMb = Get-SiteTotalMb 'Target'

$rows = [System.Collections.Generic.List[object]]::new()
$totalMb = 0
foreach ($t in $Sources) {
    if ($t -in $c.Tenants) { Write-TcRemediationTenant $t }
    $mo = Get-SiteTotalMb $t
    $totalMb += $mo
    if ($t -in $c.Tenants) { Write-TcRemediationNote ("{0:N0} GB to copy" -f ($mo / 1024)) }
    $rows.Add([pscustomobject]@{ Source = $t; 'Volume GB' = [math]::Round($mo / 1024, 1); 'Total GB' = [math]::Round($totalMb / 1024, 1) })
}
$needMb = $totalMb * (1 + $MarginPercent / 100)
$freeMb = $quotaMb - $usedMb
$enough = $needMb -le $freeMb
if ('Target' -in $c.Tenants) { Write-TcRemediationTenant 'Target' }
Write-TcRemediationNote ("Real quota {0:N0} GB, used {1:N0} GB, free {2:N0} GB" -f ($quotaMb / 1024), ($usedMb / 1024), ($freeMb / 1024))
Write-TcRemediationNote ("All sources {0:N0} GB, need with {1} % margin {2:N0} GB, total after consolidation {3:N0} GB" -f ($totalMb / 1024), $MarginPercent, ($needMb / 1024), (($usedMb + $needMb) / 1024))
if (-not $enough) { Write-TcRemediationAlert ("Not enough capacity for the total: {0:N0} GB short" -f (($needMb - $freeMb) / 1024)) }
Export-TcRemediationReport -Name 'capacity-total' -Rows @($rows) | Out-Null

$row = [ordered]@{ Subject = 'SharePoint storage of the target'; 'Need GB' = [math]::Round($needMb / 1024, 1); 'Free GB' = [math]::Round($freeMb / 1024, 1); Proposal = $(if ($enough) { 'No purchase' } else { 'Buy storage' }) }
Get-TcDecision -Name 'CON-CAPACITY' -Proposal @($row) -Key 'Subject' -Choice 'No purchase', 'Buy storage', 'Exclude sites' | Out-Null

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $realMb = [double](Get-TcMember (Invoke-TcServiceCommand -Tenant 'Target' -Service Pnp -Command 'Get-PnPTenant') 'StorageQuota')
    if ($needMb -le ($realMb - $usedMb)) { New-TcRemediationResult OK ("quota read {0:N0} GB: the total fits" -f ($realMb / 1024)) } else { New-TcRemediationResult Blocking ("quota read {0:N0} GB: the total does not fit" -f ($realMb / 1024)) }
}
Close-TcRemediation

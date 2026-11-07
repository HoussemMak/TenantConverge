# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Works out the total license need and its staggering in the order of the cutovers (procedure CON-LICENSES).

.DESCRIPTION
    Read only. Buys nothing and connects to nothing. For each source:
      - the high estimate of the plan: enabled and licensed member accounts of the source;
      - the need from the matrix: rows Create of type User, the validated matrix if it exists, otherwise the draft;
      - the maximum need: the same, plus the rows To review of type User, except likely duplicates and external accounts.
    The available count comes from the licenses table of the target. The order of the sources is the one of the project; the licenses
    must be there before PREP-02, not only before the cutover. Run again at each change of the matrices.
    The order itself is followed in CMP-LICENSES.
#>
$c = Open-TcRemediation

$Sku = Get-TcRemediationLicense

$skuRow = Get-TcRemediationTable 'Target' 'licenses' | Where-Object { $_['SKU'] -eq $Sku } | Select-Object -First 1
$availableCount = if ($skuRow) { [int]$skuRow['Available'] } else { 0 }
$rows = [System.Collections.Generic.List[object]]::new()
$total = 0
$rank = 0
foreach ($t in @(@((Get-TcSourceRole)) | Where-Object { $_ -in $c.Tenants })) {
    Write-TcRemediationTenant $t 'Need of the source'
    $m = Import-TcSourceMatrix $t
    $estimate = @(Get-TcRemediationTable $t 'users' | Where-Object { $_['Type'] -eq 'Member' -and (ConvertTo-TcBoolean $_['Enabled']) -and [int]('0' + $_['License count']) -gt 0 }).Count
    $users = @((Get-TcMember $m 'Rows') | Where-Object { (Get-TcMember $_ 'Type') -eq 'User' -and (Get-TcMember $_ 'Source UPN') -notmatch '#EXT#' })
    $create = @($users | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Create' }).Count
    $toValidate = @($users | Where-Object { (Get-TcMember $_ 'Decision') -eq 'To review' -and (Get-TcMember $_ 'Notes') -notmatch 'likely duplicate' }).Count
    $rank++
    $total += $create + $toValidate
    $rows.Add([ordered]@{ Order = $rank; Source = $t; Matrix = (Get-TcMember $m 'State'); 'High estimate of the plan' = $estimate; 'To create' = $create; 'To validate' = $toValidate; 'Maximum need' = ($create + $toValidate); 'Maximum total' = $total; 'To order at most (total)' = [math]::Max(0, $total - $availableCount) })
    Write-TcRemediationNote ("High estimate {0}; matrix ({1}): {2} to create, {3} to validate" -f $estimate, (Get-TcMember $m 'State'), $create, $toValidate)
}

if ($rows.Count) {
    Write-TcRemediationTenant 'Target' 'Available licenses'
    $estimate = (Get-TcMember (@($rows | ForEach-Object { $_['High estimate of the plan'] }) | Measure-Object -Sum) 'Sum')
    $closed = (Get-TcMember (@($rows | ForEach-Object { $_['To create'] }) | Measure-Object -Sum) 'Sum')
    Write-TcRemediationNote ("{0}: {1} available in the target; high estimate {2}; to create according to the matrices {3}; at most {4}" -f $Sku, $availableCount, [int]$estimate, [int]$closed, $total)
    if ($skuRow) { Write-TcRemediationNote ("{0}: {1} purchased, {2} consumed" -f $Sku, $skuRow['Purchased'], $skuRow['Consumed']) } else { Write-TcRemediationNote ("{0} is not yet present in the target" -f $Sku) }
    Export-TcRemediationReport -Name 'licenses-staggering' -Rows @($rows) | Out-Null
}

Invoke-TcRemediationPlan
Close-TcRemediation

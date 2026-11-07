# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Confirms that each prefixed target address is free in the target, recycle bin included (procedure CMP-SITE-URLS).

.DESCRIPTION
    Depends on CON-SITES: reads decisions\CON-SITES.csv. Compares each address with the sites of the target in the snapshot and recalls
    the address collisions of the plan, which the prefix must resolve. Gives one CSV per source.
    In an -Apply run, the script reads the target again: Get-PnPTenantSite and Get-PnPTenantRecycleBinItem, because a deleted site keeps
    its address.
    The address file stays the reference for the copy tool.
    Limits: warning the owners stays a human action. Favorites and internal links need a review.
#>
$c = Open-TcRemediation

$FileName = 'CON-SITES'
$addresses = if (Test-TcDecisionFile $FileName) { @(Read-TcDecisionRow $FileName) } else { @() }
$takenItems = @{}
foreach ($s in Get-TcRemediationTable 'Target' 'sites') { $takenItems[([string]$s['Url']).TrimEnd('/').ToLowerInvariant()] = 1 }

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $collisions = @(Get-TcRemediationPlanAction -Procedure 'CMP-SITE-URLS' -Tenant $t | ForEach-Object { (Get-TcMember $_ 'items') })
    $ofTenant = @($addresses | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t })
    if (-not $ofTenant.Count) { Write-TcRemediationAlert 'Target addresses missing: run CON-SITES first'; continue }
    $rows = foreach ($a in $ofTenant) {
        [pscustomobject]@{ 'Source site' = $a.'Source site'; 'Target address' = $a.'Target address'; Excluded = $a.Excluded; 'State' = $(if ($takenItems[([string]$a.'Target address').TrimEnd('/').ToLowerInvariant()]) { 'Taken' } else { 'Free' }) }
    }
    $consumed = @($rows | Where-Object { (Get-TcMember $_ 'State') -eq 'Taken' })
    Write-TcRemediationNote ("{0} address collision(s) according to the plan; {1} prefixed address(es), {2} already taken" -f $collisions.Count, @($rows).Count, $consumed.Count)
    foreach ($o in $consumed) { Write-TcRemediationAlert ("Target address already taken in the target: {0}" -f (Get-TcMember $o 'Target address')) }
    $f = Export-TcRemediationReport -Name "checked-addresses-$t" -Rows @($rows)
    Add-TcManualAction -Tenant $t -Object 'Site owners' -Description ("Warn the owners: the address of {0} site(s) changes" -f @($rows).Count) `
        -Instruction @("List: $f", 'Announce the new address in the communication plan. Favorites, internal links and linked files need a review.')
}

$script:TcRemediationRun['TargetSites'] = $null
$script:TcRemediationRun['TargetRecycleBin'] = $null
Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($null -eq $script:TcRemediationRun['TargetSites']) {
        $script:TcRemediationRun['TargetSites'] = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Pnp -Command 'Get-PnPTenantSite' | ForEach-Object { ((Get-TcText $_ 'Url')).TrimEnd('/').ToLowerInvariant() })
        $script:TcRemediationRun['TargetRecycleBin'] = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Pnp -Command 'Get-PnPTenantRecycleBinItem' | ForEach-Object { ((Get-TcText $_ 'Url')).TrimEnd('/').ToLowerInvariant() })
    }
    $wantedItems = @($addresses | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | ForEach-Object { ((Get-TcText $_ 'Target address')).TrimEnd('/').ToLowerInvariant() })
    $liveOnes = @($wantedItems | Where-Object { $_ -in $script:TcRemediationRun['TargetSites'] })
    $deletedOnes = @($wantedItems | Where-Object { $_ -in $script:TcRemediationRun['TargetRecycleBin'] })
    if ($liveOnes.Count) { New-TcRemediationResult Blocking ("{0} address(es) already taken in the target: {1}" -f $liveOnes.Count, ($liveOnes -join ' ; ')) } else { New-TcRemediationResult OK ("{0} free address(es) among the sites of the target" -f $wantedItems.Count) }
    if ($deletedOnes.Count) { New-TcRemediationResult Blocking ("{0} address(es) in the recycle bin of the target: {1}" -f $deletedOnes.Count, ($deletedOnes -join ' ; ')) } else { New-TcRemediationResult OK 'no address in the recycle bin of the tenant' }
}
Close-TcRemediation

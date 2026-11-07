# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has Bookings and Viva Engage decided and prepares the carry-over of Planner (procedure AUT-SERVICES).

.DESCRIPTION
    Reads bookings, vivaCommunities and plans. decisions\AUT-SERVICES.csv says for each page and each community: Recreate, Export or Drop.
    Planner plans go in a CSV for the POC: they follow the teams depending on the chosen tool.
    Limits: Microsoft does not allow creating a Bookings page in application mode. Each kept page is therefore a human action; the script
    then reads the target again and says which are present.
    No API carries Viva Engage over or exports a community in this frame.
    The public address of a page changes when it is recreated, and upcoming appointments must be checked with the owner.
#>
$c = Open-TcRemediation

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $bookings = @(Get-TcRemediationTable $t 'bookings')
    $viva = @(Get-TcRemediationTable $t 'vivaCommunities')
    $plans = @(Get-TcRemediationTable $t 'plannerPlans')
    Write-TcRemediationNote ("{0} Bookings page(s), {1} Viva Engage community(ies), {2} Planner plan(s)" -f $bookings.Count, $viva.Count, $plans.Count)
    if ($plans.Count) {
        $f = Export-TcRemediationReport -Name "plans-planner-$t" -Rows @($plans)
        Add-TcManualAction -Tenant $t -Object 'Planner' -Description ("Validate the copy of {0} plan(s) during the POC" -f $plans.Count) -Instruction @("List: $f", 'Record the result in the POC report with the chosen tool.')
    }
    foreach ($b in $bookings) { [ordered]@{ Tenant = $t; Service = 'Bookings'; Name = $b['Name']; Proposal = '' } }
    foreach ($v in $viva) { [ordered]@{ Tenant = $t; Service = 'Viva Engage'; Name = $v['Name']; Proposal = '' } }
}
$decisions = @(Get-TcDecision -Name 'AUT-SERVICES' -Proposal @($proposals) -Key 'Tenant', 'Service', 'Name' -Choice 'Recreate', 'Export', 'Drop')

foreach ($d in $decisions) {
    if ((Get-TcMember $d 'Service') -eq 'Bookings' -and (Get-TcMember $d 'Decision') -eq 'Recreate') {
        Add-TcManualAction -Tenant 'Target' -Object (Get-TcMember $d 'Name') -Description ("Recreate the Bookings page {0} in the target" -f (Get-TcMember $d 'Name')) `
            -Instruction @('Read the services, staff and availability in the source, then recreate the page in the target.', 'Check the upcoming appointments, then announce the new public address to the clients who use it.')
    }
    if ((Get-TcMember $d 'Service') -eq 'Viva Engage' -and (Get-TcMember $d 'Decision') -in 'Recreate', 'Export') {
        Add-TcManualAction -Tenant (Get-TcMember $d 'Tenant') -Object (Get-TcMember $d 'Name') -Description ("{0} the Viva Engage community {1}" -f (Get-TcMember $d 'Decision'), (Get-TcMember $d 'Name')) -Instruction @('No native migration: to handle in Viva Engage with the owner of the community.')
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $wantedItems = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Service') -eq 'Bookings' -and (Get-TcMember $_ 'Decision') -eq 'Recreate' } | ForEach-Object { (Get-TcMember $_ 'Name') })
    if (-not $wantedItems.Count) { return }
    $presentOnes = @(Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/solutions/bookingBusinesses' -All | ForEach-Object { (Get-TcMember $_ 'displayName') })
    foreach ($n in $wantedItems) { if ($n -in $presentOnes) { New-TcRemediationResult OK "page $n present in the target" } else { New-TcRemediationResult Warning "page $n not recreated in the target yet" } }
}
Close-TcRemediation

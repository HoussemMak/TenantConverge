# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the customer rule on empty or inactive sites and makes the excluded ones read-only (procedure SPO-INACTIVE).

.DESCRIPTION
    The list comes from the migration plan: empty or inactive sites of each tenant, with owner, size and link to a group or team.
    decisions\SPO-INACTIVE.csv says what to do with each site:
      Read only : the site is excluded from the copy and locked, to reveal a forgotten use before the cutover;
      Keep      : nothing changes;
      Archive, Delete: target only, before the migrated sites arrive.
    CON-SITES, CMP-CAPACITY, CON-CAPACITY and SPO-LARGE-SITES read this file again to take out the excluded sites.
    Limits: the last change does not measure reads. Archive needs Microsoft 365 Archive.
    The backup confirmation stays to be done by a person.
#>
$c = Open-TcRemediation

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    if (-not (Test-TcCollectionComplete $t 'sites')) { Write-TcRemediationAlert 'Incomplete site collection: the list may be partial' }
    $sites = @{}
    foreach ($s in Get-TcRemediationTable $t 'sites') { $sites[([string]$s['Url']).TrimEnd('/').ToLowerInvariant()] = $s }
    $items = @(Get-TcRemediationPlanAction -Procedure 'SPO-INACTIVE' -Tenant $t | ForEach-Object { (Get-TcMember $_ 'items') } | ForEach-Object { ($_ -split ' - ')[0] })
    Write-TcRemediationNote ("{0} empty or inactive site(s) to rule on" -f $items.Count)
    foreach ($u in $items) {
        $s = $sites[$u.TrimEnd('/').ToLowerInvariant()]
        [ordered]@{ Tenant = $t; Site = $u; Title = $s['Title']; 'Owner' = $s['Owner']; 'Storage MB' = $s['Storage MB']; 'Days inactive' = $s['Days inactive']; Group = $s['Group']
                    'Linked team' = $(if (ConvertTo-TcBoolean $s['Teams']) { 'Yes' } else { 'No' }); Proposal = $(if ($t -eq 'Target') { '' } else { 'Read only' }) }
    }
}
$decisions = @(Get-TcDecision -Name 'SPO-INACTIVE' -Proposal @($proposals) -Key 'Tenant', 'Site' -Choice 'Read only', 'Keep', 'Archive', 'Delete')

foreach ($d in $decisions) {
    $t = (Get-TcMember $d 'Tenant')
    switch ((Get-TcMember $d 'Decision')) {
        'Read only' {
            Add-TcCommandAction -Tenant $t -Service Pnp -Command 'Set-PnPTenantSite' -Parameters @{ Identity = (Get-TcMember $d 'Site'); LockState = 'ReadOnly' } -Object (Get-TcMember $d 'Site') `
                -Description ("Set {0} to read only" -f (Get-TcMember $d 'Site')) `
                -Test {
                    param($a)
                    $s = Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Get-PnPTenantSite' -Parameters @{ Identity = $a.parameters.Identity }
                    $a.undo = @{ command = 'Set-PnPTenantSite'; parameters = @{ Identity = $a.parameters.Identity; LockState = (Get-TcText $s 'LockState') } }
                    return (Get-TcText $s 'LockState') -eq 'ReadOnly'
                }
        }
        'Archive' {
            if ($t -ne 'Target') { Write-TcRemediationAlert ("{0}: Archive applies to the target only; for a source, decide Read only" -f (Get-TcMember $d 'Site')); continue }
            Add-TcCommandAction -Tenant $t -Service Pnp -Command 'Set-PnPSiteArchiveState' -Parameters @{ Identity = (Get-TcMember $d 'Site'); ArchiveState = 'Archived'; Force = $true } -Object (Get-TcMember $d 'Site') `
                -Description ("Archive {0}" -f (Get-TcMember $d 'Site')) `
                -Test { param($a) (Get-TcText (Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Get-PnPTenantSite' -Parameters @{ Identity = $a.parameters.Identity }) 'ArchiveStatus') -match '^(Recently|Fully)Archived$' } `
                -Undo @{ command = 'Set-PnPSiteArchiveState'; parameters = @{ Identity = (Get-TcMember $d 'Site'); ArchiveState = 'Enabled'; Force = $true } }
        }
        'Delete' {
            if ($t -ne 'Target') { Write-TcRemediationAlert ("{0}: Delete applies to the target only; for a source, decide Read only" -f (Get-TcMember $d 'Site')); continue }
            if ((Get-TcMember $d 'Group')) {
                # a group site goes away with its group: Remove-PnPTenantSite does not apply
                Add-TcGraphAction -Tenant $t -Method DELETE -Uri "v1.0/groups/$((Get-TcMember $d 'Group'))" -Object (Get-TcMember $d 'Site') -Description ("Delete the group of the site {0}" -f (Get-TcMember $d 'Site')) `
                    -Test { param($a) -not @(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/groups?`$filter=id eq '{0}'&`$select=id" -f ($a.uri -split '/')[-1]) -All).Count } `
                    -Undo @{ type = 'Graph'; tenant = $t; method = 'POST'; uri = "v1.0/directory/deletedItems/$((Get-TcMember $d 'Group'))/restore" }
            }
            else {
                Add-TcCommandAction -Tenant $t -Service Pnp -Command 'Remove-PnPTenantSite' -Parameters @{ Url = (Get-TcMember $d 'Site'); Force = $true } -Object (Get-TcMember $d 'Site') `
                    -Description ("Delete {0} (tenant recycle bin)" -f (Get-TcMember $d 'Site')) `
                    -Test { param($a) -not (@(Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Get-PnPTenantSite') | Where-Object { (Get-TcMember $_ 'Url') -eq $a.parameters.Url }) } `
                    -Undo @{ command = 'Restore-PnPTenantRecycleBinItem'; parameters = @{ Url = (Get-TcMember $d 'Site'); Force = $true } }
            }
        }
    }
}

foreach ($t in @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -in 'Read only', 'Archive', 'Delete' } | ForEach-Object { (Get-TcMember $_ 'Tenant') } | Select-Object -Unique)) {
    Add-TcManualAction -Tenant $t -Object 'Backup tool' -Description "Confirm the backup tool coverage of the sites set aside and record the decision" `
        -Instruction @('Confirm in writing that the backup tool covers these sites until closure.', 'An excluded site disappears with the source: keep the customer confirmation in the register.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $l = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Read only' })
    if (-not $l.Count) { return }
    $ok = 0
    foreach ($d in $l) { if ((Get-TcText (Invoke-TcServiceCommand -Tenant $t -Service Pnp -Command 'Get-PnPTenantSite' -Parameters @{ Identity = (Get-TcMember $d 'Site') }) 'LockState') -eq 'ReadOnly') { $ok++ } }
    if ($ok -eq $l.Count) { New-TcRemediationResult OK "$ok site(s) read only" } else { New-TcRemediationResult Blocking ("{0} site(s) out of {1} read only" -f $ok, $l.Count) }
}
Close-TcRemediation

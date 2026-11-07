# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Gives each OneDrive a decision, in particular those of inactive accounts, and prepares their copy (procedure SPO-ONEDRIVE).

.DESCRIPTION
    Reads oneDrive, users and the identity matrix. The copy goes through a third-party tool: the script gives the order, the volumes and
    the target account.
    decisions\SPO-ONEDRIVE.csv says for each OneDrive: Copy, Copy to the manager, Export or Drop.
    For the two decisions that go through a manager, the account goes in the Note column: the script names it administrator of the OneDrive.
    Giving access to a OneDrive exposes personal data: the script also requires the Decision maker column.
    decisions\SPO-ONEDRIVE-RETENTION.csv says if the retention of orphaned OneDrives of the source extends to that of the target.
    Limit: the pre-copy starts in the chosen tool, largest first.
#>
$c = Open-TcRemediation

$targetRetention = [int](Get-TcRemediationValue 'Target' 'sharePointSettings' 'OrphanedPersonalSitesRetentionPeriod' 0)

$retentionRows = [System.Collections.Generic.List[object]]::new()
$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    if (-not (Test-TcCollectionComplete $t 'oneDrive')) { Write-TcRemediationAlert 'OneDrive collection incomplete: the list may be partial' }
    $activeOnes = @{}
    foreach ($u in Get-TcRemediationTable $t 'users') { if (ConvertTo-TcBoolean $u['Enabled']) { $activeOnes[([string]$u['UPN']).ToLowerInvariant()] = 1 } }
    $matrix = @{}
    foreach ($m in @(Get-TcRemediationIdentity $t | ForEach-Object { (Get-TcMember $_ 'rows') })) { $matrix[((Get-TcText $m 'Source UPN')).ToLowerInvariant()] = $m }
    $list = @(Get-TcRemediationTable $t 'oneDrive' | Where-Object { $_['Url'] } | Sort-Object { - [double]$_['Storage MB'] })
    $orphans = @($list | Where-Object { $_['Owner'] -and -not $activeOnes[([string]$_['Owner']).ToLowerInvariant()] })
    Write-TcRemediationNote ("{0} OneDrive(s), {1:N1} GB, {2} with no active owner" -f $list.Count, ((Get-TcMember (@($list | ForEach-Object { [double]$_['Storage MB'] }) | Measure-Object -Sum) 'Sum') / 1024), $orphans.Count)

    $retention = [int](Get-TcRemediationValue $t 'sharePointSettings' 'OrphanedPersonalSitesRetentionPeriod' 0)
    if ($retention -and $retention -lt $targetRetention) {
        $retentionRows.Add([ordered]@{ Tenant = $t; 'Current retention (days)' = $retention; 'Target retention (days)' = $targetRetention; Proposal = 'Extend' })
    }

    $rank = 0
    foreach ($o in $list) {
        $rank++
        $p = ([string]$o['Owner']).ToLowerInvariant()
        $m = $matrix[$p]
        $active = [bool]$activeOnes[$p]
        [ordered]@{ Tenant = $t; Order = $rank; OneDrive = $o['Url']; 'Owner' = $o['Owner']; 'Volume GB' = [math]::Round([double]$o['Storage MB'] / 1024, 2); 'Days inactive' = $o['Days inactive']
                    'Active account' = $(if ($active) { 'Yes' } else { 'No' }); Matrix = $(if ($m) { (Get-TcMember $m 'Decision') } else { 'Missing' }); 'Target account' = $(if ($m) { (Get-TcMember $m 'Target UPN') } else { '' })
                    Proposal = $(if ($active -and $m -and (Get-TcMember $m 'Decision') -in 'Create', 'Duplicate') { 'Copy' } else { '' }) }
    }
}
$decisions = @(Get-TcDecision -Name 'SPO-ONEDRIVE' -Proposal @($proposals) -Key 'Tenant', 'OneDrive' -Choice 'Copy', 'Copy to the manager', 'Export', 'Drop')
$chosenPolicies = @(Get-TcDecision -Name 'SPO-ONEDRIVE-RETENTION' -Proposal @($retentionRows) -Key 'Tenant' -Choice 'Extend', 'Keep')

foreach ($r in $chosenPolicies | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Extend' }) {
    Add-TcCommandAction -Tenant (Get-TcMember $r 'Tenant') -Service Pnp -Command 'Set-PnPTenant' -Parameters @{ OrphanedPersonalSitesRetentionPeriod = $targetRetention } -Object 'OrphanedPersonalSitesRetentionPeriod' `
        -Description ("Extend the retention of orphaned OneDrives to {0} days" -f $targetRetention) `
        -Test {
            param($a)
            $p = Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Get-PnPTenant'
            $a.undo = @{ command = 'Set-PnPTenant'; parameters = @{ OrphanedPersonalSitesRetentionPeriod = [int](Get-TcMember $p 'OrphanedPersonalSitesRetentionPeriod') } }
            return [int](Get-TcMember $p 'OrphanedPersonalSitesRetentionPeriod') -ge $a.parameters.OrphanedPersonalSitesRetentionPeriod
        }
}

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -in 'Copy to the manager', 'Export' }) {
    $manager = ((Get-TcText $d 'Note')).Trim()
    if ($manager -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { Write-TcRemediationAlert ("{0}: the Note column must give the account of the manager" -f (Get-TcMember $d 'OneDrive')); continue }
    if (-not (Get-TcMember $d 'Decision maker')) { Write-TcRemediationAlert ("{0}: access not given, the Decision maker column must keep the trace of the customer approval" -f (Get-TcMember $d 'OneDrive')); continue }
    Add-TcCommandAction -Tenant (Get-TcMember $d 'Tenant') -Service Pnp -Command 'Set-PnPTenantSite' -Parameters @{ Identity = (Get-TcMember $d 'OneDrive'); Owners = @($manager) } -Object (Get-TcMember $d 'OneDrive') `
        -Description ("Give {0} access to the OneDrive {1}" -f $manager, (Get-TcMember $d 'OneDrive')) `
        -Undo @{ command = 'Remove-PnPSiteCollectionAdmin'; parameters = @{ Owners = @($manager) }; url = (Get-TcMember $d 'OneDrive') } `
        -Test {
            param($a)
            $who = $a.parameters.Owners[0]
            return [bool](@(Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Get-PnPSiteCollectionAdmin' -Url $a.parameters.Identity) | Where-Object { (Get-TcMember $_ 'Email') -eq $who -or (Get-TcMember $_ 'LoginName') -like "*|$who" })
        }
}

foreach ($t in $c.Tenants) {
    $byUrl = @{}
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t }) { $byUrl[$d.OneDrive] = (Get-TcMember $d 'Decision') }
    $copyRows = @($proposals | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | ForEach-Object {
        $l = [pscustomobject]$_
        $l | Add-Member -NotePropertyName 'Decision' -NotePropertyValue ([string]$byUrl[(Get-TcMember $_ 'OneDrive')]) -PassThru })
    $f = Export-TcRemediationReport -Name "onedrive-copy-plan-$t" -Rows $copyRows
    Add-TcManualAction -Tenant $t -Object 'OneDrive pre-copy' -Description "Start the pre-copy of the OneDrives in the chosen tool, largest first" `
        -Instruction @("List, order and target accounts: $f", 'Only the rows decided Copy or Copy to the manager go into the copy.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    New-TcRemediationResult Info ("retention of orphaned OneDrives: {0} days" -f (Get-TcMember (Invoke-TcServiceCommand -Tenant $t -Service Pnp -Command 'Get-PnPTenant') 'OrphanedPersonalSitesRetentionPeriod'))
    $l = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t })
    New-TcRemediationResult Info ("{0} OneDrive(s) decided" -f (Get-TcCount $l))
}
Close-TcRemediation

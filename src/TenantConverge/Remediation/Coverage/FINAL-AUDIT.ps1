# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Produces the final audit of each source tenant: what is left, subscriptions, services (procedure FINAL-AUDIT).

.DESCRIPTION
    Report final-audit-<tenant>.csv: one row per category, with the number of objects and what to confirm. The script reads the last
    snapshot: run Invoke-TcAssessment just before for an up-to-date state. It writes nothing.

    Azure: a read role can be missing in the sources. An empty table therefore does not prove there is no subscription: the script says
    so. Closing the Azure subscriptions is done in the portal, by a person.
    This audit comes before TENANT-CLOSURE and LICENSE-REMOVAL.
#>
$c = Open-TcRemediation

function Get-RestRow {
    param([string]$Tenant, [string]$Category, [int]$Number, [string]$ToConfirm = '')
    return [ordered]@{ Tenant = $Tenant; 'Category' = $Category; Number = $Number; 'State' = $(if ($Number) { 'To review' } else { 'Nothing read' }); 'To confirm' = $ToConfirm }
}

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $u = @(Get-TcRemediationTable $t 'users')
    $activeMembers = @($u | Where-Object { $_['Type'] -eq 'Member' -and (ConvertTo-TcBoolean $_['Enabled']) })
    $licenses = @(Get-TcRemediationTable $t 'licenses')
    $paid = @($licenses | Where-Object { [int]$_['Purchased'] -lt 10000 })
    $azure = @(Get-TcRemediationTable $t 'azureSubscriptions')
    $l = [System.Collections.Generic.List[object]]::new()
    $l.Add((Get-RestRow $t 'Active member accounts' $activeMembers.Count 'All blocked, except kept accounts (post-cutover check).'))
    $l.Add((Get-RestRow $t 'Blocked member accounts' @($u | Where-Object { $_['Type'] -eq 'Member' -and -not (ConvertTo-TcBoolean $_['Enabled']) }).Count))
    $l.Add((Get-RestRow $t 'Guest accounts' @($u | Where-Object { $_['Type'] -eq 'Guest' }).Count))
    $l.Add((Get-RestRow $t 'Mailboxes' @(Get-TcRemediationTable $t 'mailboxes').Count 'Data reconciled and backup in place.'))
    $l.Add((Get-RestRow $t 'Groups' @(Get-TcRemediationTable $t 'groups').Count))
    $l.Add((Get-RestRow $t 'SharePoint sites' @(Get-TcRemediationTable $t 'sites').Count 'Content copied, no more activity.'))
    $l.Add((Get-RestRow $t 'OneDrive' @(Get-TcRemediationTable $t 'oneDrive').Count))
    $l.Add((Get-RestRow $t 'Teams' @(Get-TcRemediationTable $t 'teams').Count))
    $l.Add((Get-RestRow $t 'Registered applications' @(Get-TcRemediationTable $t 'applications').Count 'The applications of this module go with Remove-TcAccess.'))
    $l.Add((Get-RestRow $t 'Devices managed by Intune' @(Get-TcRemediationTable $t 'managedDevices').Count 'Re-enrolled in the target or removed.'))
    $l.Add((Get-RestRow $t 'Autopilot devices' @(Get-TcRemediationTable $t 'autopilotDevices').Count 'Removed from the source before their registration in the target.'))
    $l.Add((Get-RestRow $t 'Phone numbers' @(Get-TcRemediationTable $t 'phoneNumbers').Count))
    $l.Add((Get-RestRow $t 'Power Platform environments' @(Get-TcRemediationTable $t 'powerEnvironments').Count))
    $l.Add((Get-RestRow $t 'Custom domains' @(Get-TcRemediationTable $t 'domains' | Where-Object { -not $_['Initial'] }).Count 'All moved to the target.'))
    $l.Add((Get-RestRow $t 'Paid subscriptions' $paid.Count (($paid | ForEach-Object { '{0} ({1})' -f $_['SKU'], $_['Purchased'] }) -join ', ')))
    $l.Add((Get-RestRow $t 'Azure subscriptions read' $azure.Count 'To check in the Azure portal: the read does not have the required role.'))
    [void](Export-TcRemediationReport -Name "audit-final-$t" -Rows $l.ToArray())
    Write-TcRemediationNote ("{0} active member(s), {1} mailbox(es), {2} site(s), {3} paid subscription(s)" -f $activeMembers.Count, @(Get-TcRemediationTable $t 'mailboxes').Count, @(Get-TcRemediationTable $t 'sites').Count, $paid.Count)
    if (-not $azure.Count) { Write-TcRemediationAlert "${t}: no Azure subscription read, which does not prove there is none. Check in the portal." }
    if (-not (Test-TcCollectionComplete $t 'users')) { Write-TcRemediationAlert "${t}: user collection incomplete, the audit is not reliable." }
}

Invoke-TcRemediationPlan
Close-TcRemediation

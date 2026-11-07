# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Cleans a source tenant, object by object, on decision and on written authorization (procedure TENANT-CLOSURE).

.DESCRIPTION
    The target is refused: this script only touches the sources. If the target is asked for, it stops before any action.

    Two decisions are required:
      - decisions\TENANT-CLOSURE.csv: one row per tenant. Enter Allowed, the decision maker, the date and the reference of the written
        document in Note. If a field is missing, no action is planned for this tenant.
      - decisions\TENANT-CLOSURE-OBJECTS.csv: one row per object. Delete or Keep.
        A proposal is not a decision. It only aims at blocked accounts and guests, groups and applications.

    Order: applications, groups, accounts, domains. All the actions are critical: a failure stops the rest of the plan.
    Never listed: emergency accounts, kept accounts, migration team accounts, the applications of this module (Remove-TcAccess removes them).
    Accounts and Microsoft 365 groups stay in the recycle bin for 30 days: Undo-TcRemediation restores them within this delay.
    Distribution lists are not deleted through Graph: they go away with the tenant.

    Deleting the tenant has no API: it is done in the Microsoft Entra admin center, once all subscriptions are deprovisioned, by a person.
    Keep to the Microsoft grace periods.
#>
$c = Open-TcRemediation

if ('Target' -in $c.Tenants) {
    throw 'This is the target tenant: this script refuses to handle it. No action, no decision.'
}

$authorizations = @(Get-TcDecision -Name 'TENANT-CLOSURE' -Proposal @($c.Tenants | ForEach-Object { [ordered]@{ Tenant = $_; Object = 'Written authorization to close (reference in Note)' } }) -Key 'Tenant' -Choice 'Allowed')

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $apps = @(Get-TcRemediationTable $t 'applications' | Where-Object { $_['Name'] -notmatch (Get-TcRemediationOption 'ProtectedApplicationPattern') })
    $groups = @(Get-TcRemediationTable $t 'groups' | Where-Object { $_['Type'] -in 'Microsoft 365', 'Security' })
    $accounts = @(Get-TcRemediationTable $t 'users' | Where-Object { -not (Test-TcProtectedAccount $_['UPN'] $i) })
    $domains = @(Get-TcRemediationTable $t 'domains' | Where-Object { -not $_['Initial'] })
    Write-TcRemediationNote ("Read: {0} application(s), {1} group(s), {2} account(s), {3} custom domain(s)" -f $apps.Count, $groups.Count, $accounts.Count, $domains.Count)
    foreach ($x in $apps) { [ordered]@{ Tenant = $t; Rank = '1'; Type = 'Application'; Object = $x['Name']; Id = $x['AppId']; Proposal = 'Delete' } }
    foreach ($x in $groups) { [ordered]@{ Tenant = $t; Rank = '2'; Type = "Group $($x['Type'])"; Object = $x['Name']; Id = $x['Id']; Proposal = 'Delete' } }
    foreach ($x in $accounts) { [ordered]@{ Tenant = $t; Rank = '3'; Type = "Account $($x['Type'])"; Object = $x['UPN']; Id = $x['Id']; Proposal = $(if ($x['Type'] -eq 'Guest' -or -not (ConvertTo-TcBoolean $x['Enabled'])) { 'Delete' } else { '' }) } }
    foreach ($x in $domains) { [ordered]@{ Tenant = $t; Rank = '4'; Type = 'Domain'; Object = $x['Domain']; Id = $x['Domain']; Proposal = '' } }
}
$decisions = @(Get-TcDecision -Name 'TENANT-CLOSURE-OBJECTS' -Proposal @($proposals) -Key 'Tenant', 'Type', 'Id' -Choice 'Delete', 'Keep')

foreach ($t in $c.Tenants) {
    $a = $authorizations | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | Select-Object -First 1
    if (-not $a -or -not $a.'Decision maker' -or -not $a.Date -or -not ([string]$a.Note).Trim()) {
        Write-TcRemediationAlert "${t}: no complete written authorization (decision, decision maker, date, reference). No action planned."
        continue
    }
    Write-TcRemediationNote ("{0}: authorization by {1} on {2}, reference {3}" -f $t, $a.'Decision maker', $a.Date, $a.Note)
    $i = Get-TcRemediationTenant $t
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Delete' } | Sort-Object Rank, Object) {
        if ((Get-TcMember $d 'Rank') -eq '3' -and (Test-TcProtectedAccount (Get-TcMember $d 'Object') $i)) { Write-TcRemediationAlert ("{0} is a protected account: decision Delete ignored" -f (Get-TcMember $d 'Object')); continue }
        switch ((Get-TcMember $d 'Rank')) {
            '1' {
                $uri = "v1.0/applications(appId='$((Get-TcMember $d 'Id'))')"
                Add-TcGraphAction -Tenant $t -Method DELETE -Uri $uri -Object (Get-TcMember $d 'Object') -Description "Remove the application $((Get-TcMember $d 'Object'))" -Critical -Reason 'Application can be restored for 30 days from the deleted applications of Entra.' -Test { param($x) Test-TcGraphAbsent -Tenant (Get-TcMember $x 'tenant') -Uri (Get-TcMember $x 'uri') }
            }
            '2' {
                $uri = "v1.0/groups/$((Get-TcMember $d 'Id'))"
                if ((Get-TcMember $d 'Type') -eq 'Microsoft 365 group') {
                    Add-TcGraphAction -Tenant $t -Method DELETE -Uri $uri -Object (Get-TcMember $d 'Object') -Description "Delete the group $((Get-TcMember $d 'Object'))" -Critical -Undo @{ type = 'Graph'; tenant = $t; method = 'POST'; uri = "v1.0/directory/deletedItems/$((Get-TcMember $d 'Id'))/restore" } -Test { param($x) Test-TcGraphAbsent -Tenant (Get-TcMember $x 'tenant') -Uri (Get-TcMember $x 'uri') }
                }
                else {
                    Add-TcGraphAction -Tenant $t -Method DELETE -Uri $uri -Object (Get-TcMember $d 'Object') -Description "Delete the security group $((Get-TcMember $d 'Object'))" -Critical -Reason 'A deleted security group cannot be restored.' -Test { param($x) Test-TcGraphAbsent -Tenant (Get-TcMember $x 'tenant') -Uri (Get-TcMember $x 'uri') }
                }
            }
            '3' {
                $uri = "v1.0/users/$((Get-TcMember $d 'Id'))"
                Add-TcGraphAction -Tenant $t -Method DELETE -Uri $uri -Object (Get-TcMember $d 'Object') -Description "Delete the account $((Get-TcMember $d 'Object'))" -Critical -Undo @{ type = 'Graph'; tenant = $t; method = 'POST'; uri = "v1.0/directory/deletedItems/$((Get-TcMember $d 'Id'))/restore" } -Test { param($x) Test-TcGraphAbsent -Tenant (Get-TcMember $x 'tenant') -Uri (Get-TcMember $x 'uri') }
            }
            '4' {
                $uri = "v1.0/domains/$((Get-TcMember $d 'Id'))"
                Add-TcGraphAction -Tenant $t -Method DELETE -Uri $uri -Object (Get-TcMember $d 'Object') -Description "Remove the domain $((Get-TcMember $d 'Object'))" -Critical -Reason 'To go back: add the domain again and verify it again.' -Test { param($x) Test-TcGraphAbsent -Tenant (Get-TcMember $x 'tenant') -Uri (Get-TcMember $x 'uri') }
            }
        }
    }
    Add-TcManualAction -Tenant $t -Object "Deletion of tenant $t" -Description "Delete the tenant $t in the Microsoft Entra admin center" -Who 'Customer and migration team' -Instruction @(
        'Check: invoices paid, subscriptions canceled then deprovisioned (CLOSE-05), Azure subscriptions deleted, one Global Administrator left.',
        'Run Remove-TcAccess for this tenant, then, in Microsoft Entra: Overview, Manage tenants, Delete.',
        'No API allows this deletion.')
}

Invoke-TcRemediationPlan
Close-TcRemediation

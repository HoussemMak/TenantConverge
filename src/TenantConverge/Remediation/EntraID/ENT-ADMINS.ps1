# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Reduces the permanent Global Administrators, account by account, according to the customer decisions (procedure ENT-ADMINS).

.DESCRIPTION
    The first preview creates decisions\ENT-ADMINS.csv: one row per account that holds the role, with a proposal. Only the rows
    marked Remove are applied.
    Guards, whatever the decisions:
      - emergency accounts and the accounts that run the migration keep the role;
      - in each tenant, at least two Global Administrators stay in place.
#>
$c = Open-TcRemediation

$GlobalAdminId = '62e90394-69f5-4237-9190-012177145e10'
$AdminMinimum = 2

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Global Administrators read'
    $i = Get-TcRemediationTenant $t
    $activeOnes = @(Get-TcRemediationTable $t 'adminRoles' | Where-Object { $_['Role'] -eq 'Global Administrator' -and $_['Assignment'] -eq 'Enabled' -and $_['Principal type'] -eq 'user' })
    Write-TcRemediationNote ("{0} active assignment(s) of the Global Administrator role" -f $activeOnes.Count)
    foreach ($r in $activeOnes) {
        $u = Get-TcRemediationTable $t 'users' | Where-Object { $_['UPN'] -eq $r['Principal'] } | Select-Object -First 1
        [ordered]@{ Tenant = $t; Account = $r['Principal']; Name = $(if ($u) { $u['Name'] }); 'Days inactive' = $(if ($u) { $u['Days inactive'] })
                    Proposal = $(if (Test-TcProtectedAccount $r['Principal'] $i) { 'Keep' } else { '' }) }
    }
}

$decisions = @(Get-TcDecision -Name 'ENT-ADMINS' -Proposal @($proposals) -Key 'Tenant', 'Account' -Choice 'Remove', 'Keep')

foreach ($t in $c.Tenants) {
    $i = Get-TcRemediationTenant $t
    $activeOnes = @(Get-TcRemediationTable $t 'adminRoles' | Where-Object { $_['Role'] -eq 'Global Administrator' -and $_['Assignment'] -eq 'Enabled' -and $_['Principal type'] -eq 'user' })
    $remaining = $activeOnes.Count
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Remove' }) {
        if (Test-TcProtectedAccount (Get-TcMember $d 'Account') $i) { Write-TcRemediationAlert ("{0}: {1} is a protected account, the Remove decision is ignored" -f $t, (Get-TcMember $d 'Account')); continue }
        if ($remaining - 1 -lt $AdminMinimum) { Write-TcRemediationAlert ("{0}: {1} keeps the role, otherwise fewer than {2} Global Administrators would remain" -f $t, (Get-TcMember $d 'Account'), $AdminMinimum); continue }
        $remaining--
        Add-TcBlockAction -Tenant $t -Service Graph -Object (Get-TcMember $d 'Account') -Description ("Remove the Global Administrator role from {0}" -f (Get-TcMember $d 'Account')) -Data @{ Account = (Get-TcMember $d 'Account'); Role = $GlobalAdminId } `
            -Test {
                param($a)
                $list = @(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '{0}'&`$expand=principal" -f $a.data.Role) -All)
                $a.data.Attribution = $list | Where-Object { (Get-TcMember (Get-TcMember $_ 'principal') 'userPrincipalName') -eq $a.data.Account } | Select-Object -First 1
                return -not $a.data.Attribution
            } `
            -Block {
                param($a)
                $x = $a.data.Attribution
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'POST'; uri = 'v1.0/roleManagement/directory/roleAssignments'; body = @{ principalId = (Get-TcMember $x 'principalId'); roleDefinitionId = (Get-TcMember $x 'roleDefinitionId'); directoryScopeId = (Get-TcMember $x 'directoryScopeId') } }
                Invoke-TcGraph -Tenant $a.tenant -Method DELETE -Uri ("v1.0/roleManagement/directory/roleAssignments/{0}" -f (Get-TcMember $x 'id'))
            }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $n = @(Invoke-TcGraph -Tenant $t -Uri ("v1.0/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '{0}'" -f $GlobalAdminId) -All).Count
    if ($n -lt 5) { New-TcRemediationResult OK "$n role assignment(s), below the threshold of five" } else { New-TcRemediationResult Warning "$n role assignments: the goal is fewer than five" }
}
Close-TcRemediation

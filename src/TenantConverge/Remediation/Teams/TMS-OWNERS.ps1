# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Adds the owners named by the customer to the teams that have fewer than two (procedure TMS-OWNERS).

.DESCRIPTION
    Reads teamMembership and teams. decisions\TMS-OWNERS.csv has one row per team: Add, with the account in the Note column (several
    accounts separated by a semicolon), or Not applicable.
    The script goes through Microsoft Graph: adding to the team with the owner role makes the account member and owner.
    Guards: an emergency account or a migration team account is never named owner, and a note that is not an address is refused.
    Limit: carrying the mapping into the copy plan is done in the chosen tool, so that owners follow in the target.
#>
$c = Open-TcRemediation

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    if (-not (Test-TcCollectionComplete $t 'teamComposition')) { Write-TcRemediationAlert 'Team collection incomplete: the list may be partial' }
    $teams = @(Get-TcRemediationTable $t 'teams')
    $rows = @(Get-TcRemediationTable $t 'teamComposition' | Where-Object { [int]$_['Owners'] -lt 2 })
    Write-TcRemediationNote ("{0} team(s) out of {1} have fewer than two owners" -f $rows.Count, $teams.Count)
    foreach ($l in $rows) {
        $e = $teams | Where-Object { $_['Name'] -ceq $l['Team'] } | Select-Object -First 1
        if (-not $e) { Write-TcRemediationAlert ("Team with no identifier in the snapshot: {0}" -f $l['Team']); continue }
        [ordered]@{ Tenant = $t; Id = $e['Id']; 'Team' = $l['Team']; 'Owners' = $l['Owners']; Members = $l['Members']; Proposal = '' }
    }
}
$decisions = @(Get-TcDecision -Name 'TMS-OWNERS' -Proposal @($proposals) -Key 'Tenant', 'Id' -Choice 'Add', 'Not applicable')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Add' }) {
    $accounts = @(((Get-TcText $d 'Note')) -split '[;, ]+' | Where-Object { $_ })
    if (-not $accounts.Count) { Write-TcRemediationAlert ("{0}: the Note column must give the account to add" -f (Get-TcMember $d 'Team')); continue }
    foreach ($account in $accounts) {
        if ($account -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { Write-TcRemediationAlert ("{0}: {1} is not an account address" -f (Get-TcMember $d 'Team'), $account); continue }
        if ((Test-TcProtectedAccount -Account ([string]$account))) { Write-TcRemediationAlert ("{0}: {1} is a protected account, it does not become an owner" -f (Get-TcMember $d 'Team'), $account); continue }
        Add-TcGraphAction -Tenant (Get-TcMember $d 'Tenant') -Method POST -Uri "v1.0/teams/$((Get-TcMember $d 'Id'))/members" `
            -Body @{ '@odata.type' = '#microsoft.graph.aadUserConversationMember'; roles = @('owner'); 'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$account')" } `
            -Object (Get-TcMember $d 'Team') -Description ("Name {0} owner of {1}" -f $account, (Get-TcMember $d 'Team')) `
            -Test {
                param($a)
                $id = ($a.uri -split '/')[2]
                $upn = ($a.body['user@odata.bind'] -replace "^.*users\('", '') -replace "'\)$", ''
                return $upn -in @(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/groups/{0}/owners?`$select=userPrincipalName" -f $id) -All | ForEach-Object { (Get-TcMember $_ 'userPrincipalName') })
            }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $l = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Add' })
    if (-not $l.Count) { return }
    $short = @($l | Where-Object { @(Invoke-TcGraph -Tenant $t -Uri ("v1.0/groups/{0}/owners?`$select=id" -f (Get-TcMember $_ 'Id')) -All).Count -lt 2 })
    if ($short.Count) { New-TcRemediationResult Warning ("{0} team(s) out of {1} still have fewer than two owners" -f $short.Count, $l.Count) } else { New-TcRemediationResult OK ("{0} team(s) have at least two owners" -f $l.Count) }
}
Close-TcRemediation

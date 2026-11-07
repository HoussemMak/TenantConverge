# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Handles the risky or compromised accounts, according to the conclusion of the inquiry on each (procedure ENT-RISK).

.DESCRIPTION
    decisions\ENT-RISK.csv: one row per account flagged by Identity Protection, with no proposal, because only an inquiry can
    conclude: examine the detections and sign-ins, then enter Compromised or False alarm.
    No risk is closed and no password is reset without this decision.
      - False alarm: the risk is dismissed. Note the reason in the Note column.
      - Compromised: the account is confirmed compromised, its password reset, its sessions revoked, then its inbox rules, consents
        and authentication methods are read into exports\ for review.
    A synced account is reset in on-premises AD: a reset done in Entra would not hold. The script waits for the change before revoking
    the sessions.

    The password of a cloud account is generated here and encrypted with DPAPI in secrets\ in the log folder.
    Warn the user first: they must sign in again everywhere.
    Emergency accounts and migration team accounts are never touched. IDENTITY-MATRIX takes the result into the Notes column.

    Limits: removing an inbox rule, a consent or a method stays a human decision, after reviewing the export.
#>
$c = Open-TcRemediation

$RiskUri = 'v1.0/identityProtection/riskyUsers'

function Get-RiskEntry {
    <# Current risk entry; an account with no entry no longer has a risk. #>
    param([string]$Tenant, [string]$Id)
    try { return (Invoke-TcGraph -Tenant $Tenant -Uri "$RiskUri/$Id") }
    catch { if ((Get-TcErrorText $_) -match '404|NotFound') { return @{ riskState = 'none' } }; throw }
}

function Test-PasswordReplaced {
    <# Risk cleared, or password changed after the last risk update: running again does not reset twice. #>
    param([string]$Tenant, [string]$Id)
    $r = Get-RiskEntry $Tenant $Id
    if ((Get-TcMember $r 'riskState') -notin 'atRisk', 'confirmedCompromised') { return $true }
    $u = Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/users/{0}?`$select=lastPasswordChangeDateTime" -f $Id)
    return [bool]((Get-TcMember $u 'lastPasswordChangeDateTime') -and [datetime](Get-TcMember $u 'lastPasswordChangeDateTime') -gt [datetime](Get-TcMember $r 'riskLastUpdatedDateTime'))
}

$targets = @{}
foreach ($s in (Get-TcSourceRole)) {
    foreach ($l in (Get-TcMember (Get-TcRemediationIdentity $s) 'rows')) {
        if ((Get-TcMember $l 'Decision') -eq 'Duplicate' -and (Get-TcMember $l 'Target UPN')) { $targets[$l.'Target UPN'.ToLowerInvariant()] = 1 }
        if ((Get-TcMember $l 'Notes') -match 'likely duplicate of ([^\s;]+)') { $targets[$Matches[1].ToLowerInvariant()] = 1 }
    }
}

$proposals = @(foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Accounts flagged by Identity Protection'
    if ($t -ne 'Target') { Write-TcRemediationNote 'The snapshot carries at-risk accounts for the target only'; continue }
    if (-not (Test-TcCollectionComplete $t 'riskyUsers')) { Write-TcRemediationAlert 'Incomplete at-risk account collection: the list may be partial' }
    $risks = @(Get-TcRemediationTable $t 'riskyUsers')
    $i = Get-TcRemediationTenant $t
    $details = (@($risks | Group-Object { '{0} {1}' -f $_['Level'], $_['State'] } | ForEach-Object { '{0}: {1}' -f (Get-TcMember $_ 'Name'), (Get-TcCount $_) }) -join ' - ')
    Write-TcRemediationNote ("{0} account(s) flagged; {1}" -f $risks.Count, $details)
    foreach ($r in $risks) {
        if (Test-TcProtectedAccount $r['UPN'] $i) { Write-TcRemediationAlert ("{0} is a protected account: to examine by hand" -f $r['UPN']); continue }
        $u = Get-TcRemediationTable $t 'users' | Where-Object { $_['UPN'] -eq $r['UPN'] } | Select-Object -First 1
        [ordered]@{ Tenant = $t; Account = $r['UPN']; Id = $(if ($u) { $u['Id'] }); Level = $r['Level']; 'State' = $r['State']; 'Updated' = $r['Updated']
                    'Synced' = $(if ($u -and (ConvertTo-TcBoolean $u['Synced'])) { 'Yes' } else { 'No' }); 'Duplicate target' = $(if ($targets[([string]$r['UPN']).ToLowerInvariant()]) { 'Yes' } else { 'No' }); Proposal = '' }
    }
})

$decisions = @(Get-TcDecision -Name 'ENT-RISK' -Proposal $proposals -Key 'Account' -Choice 'Compromised', 'False alarm')

$IdByAccount = @{}
foreach ($d in $decisions) {
    if (Test-TcProtectedAccount (Get-TcMember $d 'Account') (Get-TcRemediationTenant (Get-TcMember $d 'Tenant'))) { Write-TcRemediationAlert ("{0} is a protected account: decision ignored" -f (Get-TcMember $d 'Account')); continue }
    if (-not (Get-TcMember $d 'Id')) { Write-TcRemediationAlert ("{0}: account missing from the snapshot, to handle in the portal" -f (Get-TcMember $d 'Account')); continue }
    $t = (Get-TcMember $d 'Tenant')
    $IdByAccount[$d.Account] = (Get-TcMember $d 'Id')

    if ((Get-TcMember $d 'Decision') -eq 'False alarm') {
        if (-not (Get-TcMember $d 'Note')) { Write-TcRemediationAlert ("{0}: the reason for the false alarm is missing from the Note column, the risk is not ignored" -f (Get-TcMember $d 'Account')); continue }
        Add-TcGraphAction -Tenant $t -Method POST -Uri "$RiskUri/dismiss" -Body @{ userIds = @((Get-TcMember $d 'Id')) } -Object (Get-TcMember $d 'Account') -Description ("Ignore the risk of {0}: false alarm" -f (Get-TcMember $d 'Account')) `
            -Test { param($a) (Get-TcMember (Get-RiskEntry $a.tenant $a.body.userIds[0]) 'riskState') -notin 'atRisk', 'confirmedCompromised' } -Undo $null -Reason 'An ignored risk cannot be restored through the API.'
        continue
    }

    Add-TcGraphAction -Tenant $t -Method POST -Uri "$RiskUri/confirmCompromised" -Body @{ userIds = @((Get-TcMember $d 'Id')) } -Object (Get-TcMember $d 'Account') -Description ("Confirm the compromise of {0}" -f (Get-TcMember $d 'Account')) `
        -Test { param($a) (Get-TcMember (Get-RiskEntry $a.tenant $a.body.userIds[0]) 'riskState') -in 'confirmedCompromised', 'remediated', 'dismissed' } -Undo $null -Reason 'The Identity Protection report keeps this state; lifting it goes through a documented false alarm.'

    if ((Get-TcMember $d 'Synced') -eq 'Yes') {
        Add-TcManualAction -Tenant $t -Object (Get-TcMember $d 'Account') -Minutes 60 -Description ("Reset the password of {0} in the on-premises AD" -f (Get-TcMember $d 'Account')) `
            -Instruction @('Synced account: the reset is done in the on-premises AD, then synchronization carries it over.', 'The script watches the date of the change and then revokes the sessions.') `
            -WaitUntil { param($a) Test-PasswordReplaced $a.tenant $IdByAccount[$a.object] }
    }
    else {
        Add-TcBlockAction -Tenant $t -Service Graph -Object (Get-TcMember $d 'Account') -Description ("Reset the password of {0}" -f (Get-TcMember $d 'Account')) -Data @{ Id = (Get-TcMember $d 'Id') } `
            -Reason 'A replaced password cannot be restored.' `
            -Test { param($a) Test-PasswordReplaced $a.tenant $a.data.Id } `
            -Block {
                param($a)
                $passwordValue = Get-TcRandomPassword -Length 24
                Save-TcRemediationSecret -Name ("reset-{0}" -f $a.data.Id) -Value $passwordValue
                Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri ("v1.0/users/{0}" -f $a.data.Id) -Body @{ passwordProfile = @{ forceChangePasswordNextSignIn = $true; password = $passwordValue } }
            }
    }

    Add-TcBlockAction -Tenant $t -Service Graph -Object (Get-TcMember $d 'Account') -Description ("Revoke the sessions of {0}" -f (Get-TcMember $d 'Account')) -Data @{ Id = (Get-TcMember $d 'Id') } -Reason 'A revoked session cannot be restored.' `
        -Test {
            param($a)
            $u = Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users/{0}?`$select=signInSessionsValidFromDateTime,lastPasswordChangeDateTime" -f $a.data.Id)
            return [bool]((Get-TcMember $u 'signInSessionsValidFromDateTime') -and (Get-TcMember $u 'lastPasswordChangeDateTime') -and [datetime](Get-TcMember $u 'signInSessionsValidFromDateTime') -gt [datetime](Get-TcMember $u 'lastPasswordChangeDateTime'))
        } `
        -Block { param($a) Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri ("v1.0/users/{0}/revokeSignInSessions" -f $a.data.Id) }

    Add-TcBlockAction -Tenant $t -Service Graph -Object (Get-TcMember $d 'Account') -Description ("Read the inbox rules, consents and methods of {0}" -f (Get-TcMember $d 'Account')) -Data @{ Id = (Get-TcMember $d 'Id'); Account = (Get-TcMember $d 'Account') } -Reason 'Read only.' `
        -Block {
            param($a)
            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($r in Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users/{0}/mailFolders/inbox/messageRules" -f $a.data.Id) -All) {
                $rows.Add([ordered]@{ Account = $a.data.Account; Nature = 'Inbox rule'; Name = (Get-TcMember $r 'displayName'); Active = (Get-TcMember $r 'isEnabled'); Details = ((Get-TcMember $r 'actions') | ConvertTo-Json -Depth 6 -Compress) })
            }
            foreach ($g in Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/oauth2PermissionGrants?`$filter=principalId eq '{0}'" -f $a.data.Id) -All) {
                $rows.Add([ordered]@{ Account = $a.data.Account; Nature = 'Consent'; Name = (Get-TcMember $g 'clientId'); Active = ''; Details = (Get-TcMember $g 'scope') })
            }
            foreach ($m in Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users/{0}/authentication/methods" -f $a.data.Id) -All) {
                $rows.Add([ordered]@{ Account = $a.data.Account; Nature = 'Method'; Name = $m['@odata.type']; Active = ''; Details = (Get-TcMember $m 'id') })
            }
            Export-TcRemediationReport -Name ("account-review-{0}" -f $a.data.Id) -Rows @($rows) | Out-Null
        }

    Add-TcManualAction -Tenant $t -Object (Get-TcMember $d 'Account') -Description ("Review the snapshot of {0} and remove what is not legitimate" -f (Get-TcMember $d 'Account')) `
        -Instruction @(("Snapshot: {0}" -f (Join-Path $c.Folder ("exports/account-review-{0}.csv" -f (Get-TcMember $d 'Id')))), 'Remove the forwardings, deletions, consents and methods that the user does not recognize. A malicious rule would follow the account into the copy.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $remaining = @(Invoke-TcGraph -Tenant $t -Uri ("{0}?`$filter=riskState eq 'atRisk'" -f $RiskUri) -All)
    $known = @($decisions | ForEach-Object { (Get-TcMember $_ 'Account') })
    $others = @($remaining | Where-Object { (Get-TcMember $_ 'userPrincipalName') -notin $known })
    if ($remaining.Count) { New-TcRemediationResult Warning ("{0} account(s) still at risk, of which {1} with no decision" -f $remaining.Count, $others.Count) } else { New-TcRemediationResult OK 'no more at-risk accounts' }
}
Close-TcRemediation

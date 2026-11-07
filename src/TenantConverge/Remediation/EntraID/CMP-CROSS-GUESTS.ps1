# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Handles the guests of the target that carry an address of a migrated domain, before the domains are assigned (procedure CMP-CROSS-GUESTS).

.DESCRIPTION
    decisions\CMP-CROSS-GUESTS.csv: one row per guest, choices Delete, Convert or Purge.
      - Delete: the guest is removed during the cutover, before the domains are assigned to target accounts. Deleting too early cuts their
        access: it is planned only once the cutover is open in decisions\CMP-CROSS-GUESTS-CUTOVER.csv (one row per source, decision Open).
      - Convert: the guest becomes an internal account and serves as the single account. The UPN after conversion column can be edited and
        stays. IDENTITY-MATRIX then enters Duplicate to this new UPN. It needs a license to get a mailbox. The initial password is
        encrypted with DPAPI in secrets\ in the log folder.
      - Purge: to decide after a deletion, only if the address stays taken. It is final.

    In an -Apply run, the script first reads the groups and teams of each guest into exports\cross-guest-access-<source>.csv: these
    memberships do not come back on their own on the migrated account. Keep this file for after the domains are assigned.

    Limits: conversion goes through a beta Graph endpoint. A person must give the access back to the migrated account.
#>
$c = Open-TcRemediation

$DecisionName = 'CMP-CROSS-GUESTS'
$DecisionKey = @('Tenant', 'Id')
$TargetDomain = (Get-TcMember (Get-TcRemediationTenant 'Target') 'InitialDomain')

function Test-AccountMissing {
    param([string]$Id)
    return -not @(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/users?`$filter=id eq '{0}'&`$select=id" -f $Id) -All).Count
}

$entries = Read-TcDecisionEntry $DecisionName $DecisionKey
$guests = @(Get-TcRemediationTable 'Target' 'users' | Where-Object { $_['Type'] -eq 'Guest' })
$byTenant = @{}
$proposals = @(foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Guests of the target on the domains of the source'
    $reason = '({0})' -f ((Get-TcMember (Get-TcRemediationTenant $t) 'Domains') | ForEach-Object { [regex]::Escape($_) } | Join-String -Separator '|')
    $draft = @{}
    foreach ($l in (Get-TcMember (Get-TcRemediationIdentity $t) 'rows')) { if ((Get-TcMember $l 'Target UPN')) { $draft[$l.'Target UPN'.ToLowerInvariant()] = (Get-TcMember $l 'Decision') } }
    $concerned = @($guests | Where-Object { (([string]$_['UPN']) + ' ' + ([string]$_['Email'])).ToLowerInvariant() -match $reason })
    $byTenant[$t] = @($concerned | Where-Object { -not (Test-TcProtectedAccount -Account ([string]$_['UPN'])) })
    Write-TcRemediationNote ("{0} guest(s) of the target have an address from this source; {1} protected account(s) set aside" -f $concerned.Count, ($concerned.Count - (Get-TcCount $byTenant[$t])))
    foreach ($u in $byTenant[$t]) {
        $s = $entries[(Get-TcDecisionKey ([pscustomobject]@{ Tenant = $t; Id = $u['Id'] }) $DecisionKey)]
        [ordered]@{ Tenant = $t; Id = $u['Id']; Name = $u['Name']; Email = $u['Email']; 'Invitation state' = $u['Invitation state']; 'Days inactive' = $u['Days inactive']
                    'Matrix' = [string]$draft[([string]$u['Email']).ToLowerInvariant()]
                    'UPN after conversion' = $(if ($s -and (Get-TcMember $s 'UPN after conversion')) { (Get-TcMember $s 'UPN after conversion') } else { '{0}@{1}' -f (Get-TcAddressPrefix $u['Email']).ToLowerInvariant(), $TargetDomain })
                    Proposal = $(if ($draft[([string]$u['Email']).ToLowerInvariant()] -eq 'Create') { 'Delete' } else { '' }) }
    }
})

$decisions = @(Get-TcDecision -Name $DecisionName -Proposal $proposals -Key $DecisionKey -Choice 'Delete', 'Convert', 'Purge')
$openOnes = @(Get-TcDecision -Name 'CMP-CROSS-GUESTS-CUTOVER' -Proposal @($c.Tenants | ForEach-Object { [ordered]@{ Tenant = $_; Object = 'Cutover started, before the domains are assigned to target accounts'; Proposal = '' } }) -Key 'Tenant' -Choice 'Open' | ForEach-Object { (Get-TcMember $_ 'Tenant') })

foreach ($t in $c.Tenants) {
    if ((Get-TcCount $byTenant[$t])) {
        Add-TcBlockAction -Tenant 'Target' -Service Graph -Object "Guest access ($t)" -Description ("Read the groups and teams of {0} cross-tenant guest(s) of {1}" -f (Get-TcCount $byTenant[$t]), $t) `
            -Data @{ Source = $t; Accounts = @($byTenant[$t] | ForEach-Object { @{ Id = $_['Id']; Email = $_['Email'] } }) } -Reason 'Read only.' `
            -Block {
                param($a)
                $rows = @(foreach ($x in $a.data.Accounts) {
                    if (Test-AccountMissing (Get-TcMember $x 'Id')) { continue }
                    foreach ($g in Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users/{0}/memberOf?`$select=id,displayName" -f (Get-TcMember $x 'Id')) -All) { [ordered]@{ Email = (Get-TcMember $x 'Email'); Group = (Get-TcMember $g 'displayName'); GroupId = (Get-TcMember $g 'id'); Type = $g['@odata.type'] } }
                })
                if ($rows.Count) { Export-TcRemediationReport -Name ("cross-guest-access-{0}" -f $a.data.Source) -Rows $rows | Out-Null }
            }
    }

    $toDelete = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Delete' })
    if ($toDelete.Count -and $t -notin $openOnes) { Write-TcRemediationNote ("{0}: {1} deletion(s) decided, waiting for the cutover to open (CMP-CROSS-GUESTS-CUTOVER.csv)" -f $t, $toDelete.Count) }
    elseif ($toDelete.Count) {
        foreach ($d in $toDelete) {
            Add-TcGraphAction -Tenant 'Target' -Method DELETE -Uri "v1.0/users/$((Get-TcMember $d 'Id'))" -Object (Get-TcMember $d 'Email') -Description ("Delete the guest {0} before the domains are assigned to target accounts" -f (Get-TcMember $d 'Email')) `
                -Test { param($a) Test-AccountMissing ($a.uri -replace '^.*/', '') } `
                -Undo @{ type = 'Graph'; tenant = 'Target'; method = 'POST'; uri = "v1.0/directory/deletedItems/$((Get-TcMember $d 'Id'))/restore" }
        }
        Add-TcManualAction -Tenant 'Target' -Object "Access restored ($t)" -Description ("After the domains are assigned to target accounts, give the migrated accounts of {0} the access of {1} deleted guest(s) again" -f $t, $toDelete.Count) `
            -Instruction @('Start from exports\cross-guest-access of the snapshot. Deletion removes memberships: they do not come back by themselves.')
    }

    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Purge' }) {
        Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Email') -Description ("Permanently delete the guest {0}: its address stays taken" -f (Get-TcMember $d 'Email')) -Data @{ Id = (Get-TcMember $d 'Id') } `
            -Reason 'Permanent deletion: irreversible.' `
            -Test {
                param($a)
                if (-not (Test-AccountMissing $a.data.Id)) { throw "Account still active: decide Delete first." }
                try { Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/directory/deletedItems/{0}" -f $a.data.Id) | Out-Null; return $false }
                catch { if ((Get-TcErrorText $_) -match '404|NotFound') { return $true }; throw }
            } `
            -Block { param($a) Invoke-TcGraph -Tenant $a.tenant -Method DELETE -Uri ("v1.0/directory/deletedItems/{0}" -f $a.data.Id) }
    }

    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Convert' }) {
        if (-not (Get-TcMember $d 'UPN after conversion')) { Write-TcRemediationAlert ("{0}: UPN after conversion is empty for {1}" -f $t, (Get-TcMember $d 'Email')); continue }
        Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Email') -Description ("Convert the guest {0} to the internal account {1}" -f (Get-TcMember $d 'Email'), (Get-TcMember $d 'UPN after conversion')) -Data @{ Id = (Get-TcMember $d 'Id'); Upn = (Get-TcMember $d 'UPN after conversion') } `
            -Reason 'Conversion to an internal account has no documented reverse operation.' `
            -Test { param($a) (Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users/{0}?`$select=userType" -f $a.data.Id)) 'userType') -eq 'Member' } `
            -Block {
                param($a)
                $passwordValue = Get-TcRandomPassword -Length 24
                Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri ("beta/users/{0}/convertExternalToInternalMemberUser" -f $a.data.Id) -Body @{ userPrincipalName = $a.data.Upn; passwordProfile = @{ password = $passwordValue; forceChangePasswordNextSignIn = $true } } | Out-Null
                Save-TcRemediationSecret -Name ("conversion-{0}" -f $a.data.Id) -Value $passwordValue | Out-Null
            }
    }
    $converted = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Convert' }).Count
    if ($converted) {
        Add-TcManualAction -Tenant 'Target' -Object "Licenses of converted accounts ($t)" -Description ("Check the license of {0} converted account(s) of {1}" -f $converted, $t) `
            -Instruction @('A converted account needs a license to get a mailbox. Check it before running IDENTITY-MATRIX again, which registers them as Duplicate.')
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -notin $openOnes) { return }
    $domains = (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')
    $remaining = @(Invoke-TcGraph -Tenant 'Target' -Uri "v1.0/users?`$filter=userType eq 'Guest'&`$select=id,mail" -All | Where-Object { (Get-TcAddressDomain (Get-TcMember $_ 'mail')) -in $domains })
    if ($remaining.Count) { New-TcRemediationResult Blocking ("{0} guest(s) still have an address from this source: the step that assigns domains to target accounts will fail" -f $remaining.Count) } else { New-TcRemediationResult OK 'no more guests on the domains of this source' }
}
Close-TcRemediation

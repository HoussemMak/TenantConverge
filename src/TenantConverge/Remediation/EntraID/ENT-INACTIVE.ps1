# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the inactive accounts settled and applies in the target what is decided (procedure ENT-INACTIVE).

.DESCRIPTION
    Same rule as the finding of the plan: enabled member accounts with no sign-in for the InactiveDays setting (or ever),
    created at least that long ago.

    Sources: decisions\ENT-INACTIVE.csv, choices Create or Exclude. Nothing is written to a source: these decisions feed the
    matrix (ID-02, IDENTITY-MATRIX). Accounts that are also likely duplicates are settled in CON-IDENTITIES.csv
    (CON-IDENTITIES). For each excluded account, the script asks to decide what happens to its data.

    Target: decisions\ENT-INACTIVE-TARGET.csv, choices Keep, Disable or Delete. Delete aims at an account already disabled: it is a
    second decision, entered after the agreed delay. A synced account is handled in on-premises AD.

    Guards, whatever the decisions: emergency accounts, kept accounts and migration team accounts are never touched; a target
    account that a duplicate points to is neither disabled nor deleted.

    Limits: the last sign-in comes from the snapshot, also check non-interactive sign-ins before excluding. While the reports of a
    source are concealed, the mailbox size stays empty there (AUT-CONCEALED-REPORTS, then a new snapshot).
#>
$c = Open-TcRemediation

$Threshold = [int](Get-TcRemediationOption 'InactiveDays')

function Test-AccountsDisabled {
    param([object[]]$Accounts)
    foreach ($x in $Accounts) {
        $u = @(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/users?`$filter=id eq '{0}'&`$select=accountEnabled" -f (Get-TcMember $x 'Id')) -All)
        if ($u.Count -and (Get-TcMember $u[0] 'accountEnabled')) { return $false }
    }
    return $true
}

$matrix = @{}
$duplicateTargets = @{}
foreach ($s in (Get-TcSourceRole)) {
    foreach ($l in (Get-TcMember (Get-TcRemediationIdentity $s) 'rows')) {
        $likely = if ((Get-TcMember $l 'Notes') -match 'likely duplicate of ([^\s;]+)') { $Matches[1] } else { '' }
        $matrix[("{0}|{1}" -f $s, (Get-TcMember $l 'Source UPN').ToLowerInvariant())] = @{ Decision = (Get-TcMember $l 'Decision'); Duplicate = ((Get-TcMember $l 'Decision') -eq 'Duplicate' -or $likely -or (Get-TcMember $l 'Source UPN') -match '#EXT#') }
        if ((Get-TcMember $l 'Decision') -eq 'Duplicate' -and (Get-TcMember $l 'Target UPN')) { $duplicateTargets[$l.'Target UPN'.ToLowerInvariant()] = 1 }
        if ($likely) { $duplicateTargets[$likely.ToLowerInvariant()] = 1 }
    }
}

$sourceProperties = [System.Collections.Generic.List[object]]::new()
$targetProperty = [System.Collections.Generic.List[object]]::new()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Accounts with no recent sign-in'
    $i = Get-TcRemediationTenant $t
    $memberRows = @(Get-TcRemediationTable $t 'users' | Where-Object { $_['Type'] -eq 'Member' -and (ConvertTo-TcBoolean $_['Enabled']) })
    $inactive = @($memberRows | Where-Object { ([int]$_['Days inactive'] -ge $Threshold -or [int]$_['Days inactive'] -eq -1) -and [int]('0' + $_['Days since creation']) -ge $Threshold })
    $never = @($inactive | Where-Object { [int]$_['Days inactive'] -eq -1 }).Count
    $protected = @($inactive | Where-Object { Test-TcProtectedAccount $_['UPN'] $i })
    $mailboxes = Get-TcRowIndex (Get-TcRemediationTable $t 'mailboxes') 'UPN'
    $usage = Get-TcRowIndex (Get-TcRemediationTable $t 'mailboxUsage') 'UPN'
    $onedrive = Get-TcRowIndex (Get-TcRemediationTable $t 'oneDrive') 'Owner'
    Write-TcRemediationNote ("Of {0} active member accounts, {1} have not signed in for {2} days or more, including {3} never; {4} protected account(s) set aside" -f $memberRows.Count, $inactive.Count, $Threshold, $never, $protected.Count)
    if (ConvertTo-TcBoolean (Get-TcRemediationValue $t 'reportSettings' 'Names concealed in reports')) { Write-TcRemediationNote 'Concealed reports: mailbox size stays empty until AUT-CONCEALED-REPORTS and a new snapshot' }

    $duplicates = 0
    foreach ($u in $inactive | Where-Object { -not (Test-TcProtectedAccount $_['UPN'] $i) }) {
        $k = ([string]$u['UPN']).ToLowerInvariant()
        $b = $mailboxes[$k]
        $o = $onedrive[$k]
        $base = [ordered]@{ Tenant = $t; Account = $u['UPN']; Name = $u['Name']; 'Days inactive' = $(if ([int]$u['Days inactive'] -eq -1) { 'never' } else { $u['Days inactive'] }); Licenses = $u['Licenses']
                            'Mailbox type' = $(if ($b) { $b['Type'] }); 'Mailbox GB' = $(if ($usage[$k]) { $usage[$k]['Size GB'] }); 'OneDrive GB' = $(if ($o) { [math]::Round([double]$o['Storage MB'] / 1024, 2) }) }
        if ($t -eq 'Target') {
            $target = [bool]$duplicateTargets[$k]
            $base.Id = $u['Id']
            $base['Synced'] = $(if (ConvertTo-TcBoolean $u['Synced']) { 'Yes' } else { 'No' })
            $base['Duplicate target'] = $(if ($target) { 'Yes' } else { 'No' })
            $base.Proposal = $(if ($target -or ($b -and $b['Type'] -ne 'UserMailbox')) { 'Keep' } else { '' })
            $targetProperty.Add($base)
        }
        else {
            $m = $matrix["$t|$k"]
            if ($m -and (Get-TcMember $m 'Duplicate')) { $duplicates++; continue }
            $base.Draft = $(if ($m) { (Get-TcMember $m 'Decision') } else { 'missing from the matrix' })
            $base.Proposal = $(if ([int]$u['Days inactive'] -eq -1 -and -not [int]('0' + $u['License count'])) { 'Exclude' } else { '' })
            $sourceProperties.Add($base)
        }
    }
    if ($duplicates) { Write-TcRemediationNote ("{0} inactive account(s) are also likely duplicates: to settle in CON-IDENTITIES.csv" -f $duplicates) }
}

$sourceDecisions = @(Get-TcDecision -Name 'ENT-INACTIVE' -Proposal @($sourceProperties) -Key 'Tenant', 'Account' -Choice 'Create', 'Exclude')
$targetDecision = @(Get-TcDecision -Name 'ENT-INACTIVE-TARGET' -Proposal @($targetProperty) -Key 'Account' -Choice 'Keep', 'Disable', 'Delete')

foreach ($t in $c.Tenants | Where-Object { $_ -ne 'Target' }) {
    $excludedItems = @($sourceDecisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Exclude' })
    if (-not $excludedItems.Count) { continue }
    $f = Export-TcRemediationReport -Name "excluded-accounts-$t" -Rows $excludedItems
    Add-TcManualAction -Tenant $t -Object 'Data of excluded accounts' -Who 'Customer' -Description ("Decide what happens to the mailbox and OneDrive of {0} excluded account(s)" -f $excludedItems.Count) `
        -Instruction @("List: $f", 'The data of an excluded account is not copied: it disappears with the source tenant. Have it decided before closing (see SPO-ONEDRIVE).')
}

$toHandleInAd = [System.Collections.Generic.List[object]]::new()
$targetInfo = Get-TcRemediationTenant 'Target'
foreach ($d in $targetDecision | Where-Object { (Get-TcMember $_ 'Decision') -in 'Disable', 'Delete' }) {
    if (Test-TcProtectedAccount (Get-TcMember $d 'Account') $targetInfo) { Write-TcRemediationAlert ("{0} is a protected account: decision ignored" -f (Get-TcMember $d 'Account')); continue }
    if ($duplicateTargets[(Get-TcMember $d 'Account').ToLowerInvariant()]) { Write-TcRemediationAlert ("{0} is targeted by a duplicate: decision {1} ignored until CON-IDENTITIES has set it aside" -f (Get-TcMember $d 'Account'), (Get-TcMember $d 'Decision')); continue }
    if ((Get-TcMember $d 'Synced') -eq 'Yes') { $toHandleInAd.Add($d); continue }
    $uri = "v1.0/users/$((Get-TcMember $d 'Id'))"
    if ((Get-TcMember $d 'Decision') -eq 'Disable') {
        Add-TcGraphAction -Tenant 'Target' -Method PATCH -Uri $uri -Body @{ accountEnabled = $false } -Object (Get-TcMember $d 'Account') -Description ("Disable the inactive account {0}" -f (Get-TcMember $d 'Account')) `
            -Test { param($a) -not (Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri ('{0}?$select=accountEnabled' -f $a.uri)) 'accountEnabled') } `
            -Undo @{ type = 'Graph'; tenant = 'Target'; method = 'PATCH'; uri = $uri; body = @{ accountEnabled = $true } }
    }
    else {
        Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Account') -Description ("Delete the disabled account {0}" -f (Get-TcMember $d 'Account')) -Data @{ Id = (Get-TcMember $d 'Id') } `
            -Undo @{ type = 'Graph'; tenant = 'Target'; method = 'POST'; uri = "v1.0/directory/deletedItems/$((Get-TcMember $d 'Id'))/restore" } `
            -Test { param($a) -not @(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users?`$filter=id eq '{0}'&`$select=id" -f $a.data.Id) -All).Count } `
            -Block {
                param($a)
                if ((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users/{0}?`$select=accountEnabled" -f $a.data.Id)) 'accountEnabled')) { throw "Account still active: decide Disable first, then respect the agreed delay." }
                Invoke-TcGraph -Tenant $a.tenant -Method DELETE -Uri ("v1.0/users/{0}" -f $a.data.Id)
            }
    }
}

if ($toHandleInAd.Count) {
    $f = Export-TcRemediationReport -Name 'inactive-accounts-on-premises' -Rows @($toHandleInAd)
    Add-TcManualAction -Tenant 'Target' -Object 'Synced accounts' -Description ("Handle {0} inactive account(s) synced from on-premises AD" -f $toHandleInAd.Count) -Minutes 0 `
        -Instruction @("List: $f", 'These accounts come from on-premises AD: disable or remove them there, Graph would refuse the change. Run the script again after the synchronization for the check.') `
        -WaitUntil { Test-AccountsDisabled @($toHandleInAd) }
}

Invoke-TcRemediationPlan
Close-TcRemediation

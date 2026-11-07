# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Reproduces in the target the mailbox delegations confirmed by the customer (procedure EXO-PERMISSIONS).

.DESCRIPTION
    Source tenants (PREP-03). Run it after the domains are assigned: mailboxes and delegates are aimed at by their final UPN. A mailbox or a
    delegate missing from the target postpones the action, to pick up after its cutover.

    Data read: mailboxPermissions, mailboxes and users of the source, matrix. In the snapshot, a delegate can be a UPN, an alias or an
    identifier: it is resolved to the source account, then to its target through the matrix. For SendAs, the mailbox is read under its
    Exchange name (encoded accents, suffix _xxxxxxxxxx or timestamp): the name is normalized before the search. A right with no mailbox
    or matrix row goes to exports\unresolved-rights-<tenant>.csv and raises an alert.
    Full access to shared mailboxes is not carried over here: CMP-SHARED-MAILBOXES does it for merges. A mailbox still To review in the
    matrix stays pending: the script counts these rights, they show in the decisions file once the matrix is validated.
    A resource is aimed at under the prefixed name EXO-ROOMS gives it. On a synced mailbox of the target, send on behalf is an attribute
    managed in on-premises AD: the action is postponed and says so.

    Decision: decisions\EXO-PERMISSIONS.csv, one row per delegation: Reproduce or Drop. One more row, (calendars), decides for the whole
    source: calendar rights are not in the snapshot and are read at run time.

    Limits: the name of the Calendar folder follows the language of the mailbox, it is read on both sides. Reading calendar rights goes
    through ObjectId, because the addresses of the source changed. Automapping is on, as the procedure says. The form of the User field of
    Get-MailboxFolderPermission stays to confirm at the first test.
#>
$c = Open-TcRemediation

$CalendarRow = '(calendars)'

function Test-ObjectFound {
    param([string]$Command, [hashtable]$Values)
    try { return [bool](Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command $Command -Parameters $Values) } catch { return $false }
}

function Find-DecisionRow {
    param([string]$Tenant, [string]$Upn)
    return (@((Get-TcMember (Get-TcRemediationIdentity $Tenant) 'rows')) | Where-Object { $_['Source UPN'] -eq $Upn } | Select-Object -First 1)
}

function Get-ExchangeName {
    <# Display name behind an Exchange name: accents encoded twice, suffix _xxxxxxxxxx or a 14-digit timestamp. #>
    param([string]$Value)
    return ([System.Net.WebUtility]::HtmlDecode([System.Net.WebUtility]::HtmlDecode($Value)) -replace '_[0-9a-f]{10}$', '' -replace '\d{14}$', '').Trim()
}

function Find-SourceMailbox {
    <# Source mailbox from a value read: address, UPN, ObjectId, alias, display name or Exchange name. #>
    param([string]$Tenant, [string]$Value)
    $name = Get-ExchangeName $Value
    return (Get-TcRemediationTable $Tenant 'mailboxes' | Where-Object { $_['Primary address'] -eq $Value -or $_['UPN'] -eq $Value -or $_['ObjectId'] -eq $Value -or $_['Alias'] -eq $Value -or $_['Name'] -eq $Value -or $_['Name'] -eq $name -or $_['Alias'] -eq $name } | Select-Object -First 1)
}

function Find-SourceAccount {
    <# UPN of the source account of a delegate as read: UPN, alias, ObjectId, or display name for calendars. #>
    param([string]$Tenant, [string]$Value)
    $b = Find-SourceMailbox $Tenant $Value
    if ($b) { return $b['UPN'] }
    $u = Get-TcRemediationTable $Tenant 'users' | Where-Object { $_['UPN'] -eq $Value -or $_['Id'] -eq $Value -or $_['Name'] -eq $Value } | Select-Object -First 1
    if ($u) { return $u['UPN'] }
    return $Value
}

function Find-DelegateTarget {
    param([string]$Tenant, [string]$Value)
    $l = Find-DecisionRow $Tenant (Find-SourceAccount $Tenant $Value)
    if (-not $l -or $l['Decision'] -notin 'Create', 'Duplicate') { return $null }
    return $l['Target UPN']
}

# All sources are always read: a partial decisions file would lose the rows waiting for the other wave.
$proposals = foreach ($t in (Get-TcSourceRole)) {
    $chosen = $t -in $c.Tenants
    if ($chosen) { Write-TcRemediationTenant $t }
    $rights = @(Get-TcRemediationTable $t 'mailboxPermissions')
    if (-not $rights.Count -and -not (Test-TcCollectionComplete $t 'mailboxPermissions')) { if ($chosen) { Write-TcRemediationAlert 'Permission collection incomplete: run Invoke-TcAssessment again' }; continue }
    $i = Get-TcRemediationTenant $t
    $covered = 0; $pending = 0; $noDelegate = 0
    $unresolved = [System.Collections.Generic.List[object]]::new()
    $rows = foreach ($p in $rights) {
        $b = Find-SourceMailbox $t $p['Mailbox']
        $l = if ($b) { Find-DecisionRow $t $b['UPN'] }
        if (-not $l) { $unresolved.Add([pscustomobject][ordered]@{ 'Mailbox' = $p['Mailbox']; 'Delegate' = $p['User']; Right = $p['Right'] }); continue }
        if ($l['Decision'] -notin 'Create', 'Duplicate') { if ($l['Decision'] -ne 'Exclude') { $pending++ }; continue }
        if ($b['Type'] -eq 'SharedMailbox' -and $p['Right'] -match 'FullAccess') { $covered++; continue }
        $delegate = Find-DelegateTarget $t $p['User']
        if (-not $delegate) { $noDelegate++ }
        $target = if ($l['Type'] -eq 'Resource') { '{0}-{1}' -f (Get-TcMember $i 'Prefix'), $b['Name'] } else { $l['Target UPN'] }
        [ordered]@{ Tenant = $t; 'Mailbox' = $b['Primary address']; 'Delegate' = $p['User']; Right = $p['Right']; 'Target mailbox' = $target; 'Target delegate' = $delegate; Proposal = $(if ($delegate) { 'Reproduce' } else { '' }) }
    }
    if ($chosen) { Write-TcRemediationNote ("{0} right(s) read: {1} to confirm, {2} with no target account for the delegate; {3} covered by PREP-05; {4} waiting for the matrix; {5} with no mailbox or no matrix row" -f $rights.Count, @($rows).Count, $noDelegate, $covered, $pending, $unresolved.Count) }
    if ($chosen -and $unresolved.Count) {
        Export-TcRemediationReport -Name "unresolved-permissions-$t" -Rows @($unresolved) | Out-Null
        Write-TcRemediationAlert ("{0} right(s) point to a mailbox missing from the snapshot or the matrix: review by hand" -f $unresolved.Count)
    }
    $rows
    [ordered]@{ Tenant = $t; 'Mailbox' = $CalendarRow; 'Delegate' = 'All'; Right = 'Calendar'; 'Target mailbox' = 'Read at run time'; 'Target delegate' = 'Read at run time'; Proposal = 'Reproduce' }
}

$decisions = @(Get-TcDecision -Name 'EXO-PERMISSIONS' -Proposal @($proposals) -Key 'Tenant', 'Mailbox', 'Delegate', 'Right' -Choice 'Reproduce', 'Drop')
$chosenPolicies = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -in $c.Tenants -and (Get-TcMember $_ 'Decision') -eq 'Reproduce' })

foreach ($d in $chosenPolicies | Where-Object { (Get-TcMember $_ 'Mailbox') -ne $CalendarRow }) {
    $mailbox = (Get-TcMember $d 'Target mailbox')
    $delegate = (Get-TcMember $d 'Target delegate')
    if (-not $delegate) { Write-TcRemediationAlert ("{0}: delegate {1} has no target account, right {2} not carried over" -f (Get-TcMember $d 'Mailbox'), (Get-TcMember $d 'Delegate'), (Get-TcMember $d 'Right')); continue }
    switch -Regex ((Get-TcMember $d 'Right')) {
        'FullAccess' {
            Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Add-MailboxPermission' -Parameters @{ Identity = $mailbox; User = $delegate; AccessRights = 'FullAccess'; AutoMapping = $true } -Object ("{0} / {1}" -f $mailbox, $delegate) `
                -Description ("Full access of {0} to {1}" -f $delegate, $mailbox) `
                -Test {
                    param($a)
                    if (-not (Test-ObjectFound 'Get-Mailbox' @{ Identity = $a.parameters.Identity })) { return Test-TcPostponed $a ("mailbox {0} missing from the target" -f $a.parameters.Identity) }
                    if (-not (Test-ObjectFound 'Get-Recipient' @{ Identity = $a.parameters.User })) { return Test-TcPostponed $a ("delegate {0} missing from the target" -f $a.parameters.User) }
                    return (Test-ObjectFound 'Get-MailboxPermission' @{ Identity = $a.parameters.Identity; User = $a.parameters.User })
                } `
                -Undo @{ command = 'Remove-MailboxPermission'; parameters = @{ Identity = $mailbox; User = $delegate; AccessRights = 'FullAccess' } }
        }
        'SendAs' {
            Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Add-RecipientPermission' -Parameters @{ Identity = $mailbox; Trustee = $delegate; AccessRights = 'SendAs' } -Object ("{0} / {1}" -f $mailbox, $delegate) `
                -Description ("Send as {0} for {1}" -f $mailbox, $delegate) `
                -Test {
                    param($a)
                    if (-not (Test-ObjectFound 'Get-Mailbox' @{ Identity = $a.parameters.Identity })) { return Test-TcPostponed $a ("mailbox {0} missing from the target" -f $a.parameters.Identity) }
                    if (-not (Test-ObjectFound 'Get-Recipient' @{ Identity = $a.parameters.Trustee })) { return Test-TcPostponed $a ("delegate {0} missing from the target" -f $a.parameters.Trustee) }
                    return (Test-ObjectFound 'Get-RecipientPermission' @{ Identity = $a.parameters.Identity; Trustee = $a.parameters.Trustee })
                } `
                -Undo @{ command = 'Remove-RecipientPermission'; parameters = @{ Identity = $mailbox; Trustee = $delegate; AccessRights = 'SendAs' } }
        }
        'SendOnBehalf' {
            Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Set-Mailbox' -Parameters @{ Identity = $mailbox; GrantSendOnBehalfTo = @{ Add = $delegate } } -Object ("{0} / {1}" -f $mailbox, $delegate) `
                -Description ("Send on behalf of {0} for {1}" -f $mailbox, $delegate) `
                -Test {
                    param($a)
                    try { $m = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-Mailbox' -Parameters @{ Identity = $a.parameters.Identity } } catch { return Test-TcPostponed $a ("mailbox {0} missing from the target" -f $a.parameters.Identity) }
                    try { $r = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-Recipient' -Parameters @{ Identity = $a.parameters.GrantSendOnBehalfTo.Add } } catch { return Test-TcPostponed $a ("delegate {0} missing from the target" -f $a.parameters.GrantSendOnBehalfTo.Add) }
                    $names = @((Get-TcText $r 'Name'), (Get-TcText $r 'DisplayName'), (Get-TcText $r 'Alias'), (Get-TcText $r 'Identity'), (Get-TcText $r 'ExternalDirectoryObjectId'), (Get-TcText $r 'PrimarySmtpAddress'))
                    if (@((Get-TcMember $m 'GrantSendOnBehalfTo') | Where-Object { [string]$_ -in $names }).Count) { return $true }
                    if ((Get-TcMember $m 'IsDirSynced')) { return Test-TcPostponed $a ("{0} is synced: send on behalf is added in on-premises AD" -f $a.parameters.Identity) }
                    return $false
                } `
                -Undo @{ command = 'Set-Mailbox'; parameters = @{ Identity = $mailbox; GrantSendOnBehalfTo = @{ Remove = $delegate } } }
        }
    }
}

foreach ($d in $chosenPolicies | Where-Object { (Get-TcMember $_ 'Mailbox') -eq $CalendarRow }) {
    $t = (Get-TcMember $d 'Tenant')
    $mailboxes = @(Get-TcRemediationTable $t 'mailboxes' | Where-Object { $_['Type'] -eq 'UserMailbox' } | ForEach-Object {
        $l = Find-DecisionRow $t $_['UPN']
        if ($l -and $l['Decision'] -in 'Create', 'Duplicate') { @{ Source = $_['ObjectId']; Target = $l['Target UPN'] } }
    })
    Add-TcBlockAction -Tenant 'Target' -Service Exo -Object "Calendars $t" -Data @{ Source = $t; Mailboxes = $mailboxes } -Description ("Reproduce the calendar rights of {0} mailbox(es) of {1}" -f $mailboxes.Count, $t) `
        -Block {
            param($a)
            $x = $a.data
            $rights = [System.Collections.Generic.List[object]]::new()
            foreach ($b in (Get-TcMember $x 'Mailboxes')) {
                $folder = Invoke-TcServiceCommand -Tenant (Get-TcMember $x 'Source') -Service Exo -Command 'Get-MailboxFolderStatistics' -Parameters @{ Identity = (Get-TcMember $b 'Source'); FolderScope = 'Calendar' } | Select-Object -First 1
                if (-not $folder) { continue }
                foreach ($p in @(Invoke-TcServiceCommand -Tenant (Get-TcMember $x 'Source') -Service Exo -Command 'Get-MailboxFolderPermission' -Parameters @{ Identity = ('{0}:\{1}' -f (Get-TcMember $b 'Source'), (Get-TcMember $folder 'Name')) })) {
                    $user = (Get-TcText $p 'User')
                    if ($user -in 'Default', 'Anonymous', 'Default', 'Anonymous') { continue }
                    $rights.Add(@{ Target = (Get-TcMember $b 'Target'); Delegate = $user; Rights = @((Get-TcMember $p 'AccessRights') | ForEach-Object { [string]$_ }) })
                }
            }
            $undos = [System.Collections.Generic.List[object]]::new()
            foreach ($r in $rights) {
                $delegate = Find-DelegateTarget (Get-TcMember $x 'Source') (Get-TcMember $r 'Delegate')
                if (-not $delegate) { Write-TcRemediationAlert ("Calendar of {0}: {1} has no target account, right not carried over" -f (Get-TcMember $r 'Target'), (Get-TcMember $r 'Delegate')); continue }
                $folder = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-MailboxFolderStatistics' -Parameters @{ Identity = (Get-TcMember $r 'Target'); FolderScope = 'Calendar' } | Select-Object -First 1
                if (-not $folder) { Write-TcRemediationAlert ("Calendar of {0} not found in the target" -f (Get-TcMember $r 'Target')); continue }
                $identity = '{0}:\{1}' -f (Get-TcMember $r 'Target'), (Get-TcMember $folder 'Name')
                if (Test-ObjectFound 'Get-MailboxFolderPermission' @{ Identity = $identity; User = $delegate }) { continue }
                Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Add-MailboxFolderPermission' -Parameters @{ Identity = $identity; User = $delegate; AccessRights = (Get-TcMember $r 'Rights') } | Out-Null
                $undos.Add(@{ command = 'Remove-MailboxFolderPermission'; parameters = @{ Identity = $identity; User = $delegate } })
                $a.undo = @($undos)
            }
        }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $list = @($chosenPolicies | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Right') -match 'FullAccess' -and (Get-TcMember $_ 'Target delegate') -and (Get-TcMember $_ 'Mailbox') -ne $CalendarRow })
    $missing = @($list | Where-Object { -not (Test-ObjectFound 'Get-MailboxPermission' @{ Identity = (Get-TcMember $_ 'Target mailbox'); User = (Get-TcMember $_ 'Target delegate') }) })
    if ($missing.Count) { New-TcRemediationResult Warning ("{0} full access right(s) out of {1} not found" -f $missing.Count, $list.Count) } else { New-TcRemediationResult OK ("{0} full access right(s) found" -f $list.Count) }
    $n = @($chosenPolicies | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t }).Count
    New-TcRemediationResult Info ("{0} row(s) kept for {1}" -f $n, $t)
}
Close-TcRemediation

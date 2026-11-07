# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Settles each pair of matching mailboxes between a source and the target (procedure CMP-SHARED-MAILBOXES).

.DESCRIPTION
    Data read: pairs of the plan, mailboxes, rights read in the source, matrices, decisions of CON-SHARED-MAILBOXES (they serve as the proposal).

    Decision: decisions\CMP-SHARED-MAILBOXES.csv, one row per pair.
      Merge           : the source mailbox joins the target one;
      Separate        : both mailboxes stay, the source one is created with its prefix;
      Separate-Rename : the same, and the target mailbox also gets a prefixed alias and name.

    Two steps, the same script runs again:
      1. before the cutover: rename the matching mailboxes that are not synced, and exports\matrix-rows-pairs.csv;
      2. after the domains are assigned: full access for the accounts of the source on the merged mailbox. While the original address
         is not on the mailbox, the action is postponed.

    Limits: a synced target mailbox is managed in on-premises AD, the script reports it without touching it. The SendAs and
    SendOnBehalf rights of shared mailboxes are carried over by EXO-PERMISSIONS. The content copy stays in the copy tool.
#>
$c = Open-TcRemediation

$Origins = @{}

function Get-MailboxRight {
    <# Rights of a mailbox: SendAs is read under the Exchange name (encoded accents, suffix), the others under the address. #>
    param([string]$Tenant, $Mailbox)
    $names = @($Mailbox['Primary address'], $Mailbox['UPN'], $Mailbox['Alias'], $Mailbox['ObjectId'], $Mailbox['Name'])
    return @(Get-TcRemediationTable $Tenant 'mailboxPermissions' | Where-Object { $_['Mailbox'] -in $names -or ([System.Net.WebUtility]::HtmlDecode([System.Net.WebUtility]::HtmlDecode([string]$_['Mailbox'])) -replace '_[0-9a-f]{10}$', '') -in $names })
}

function Find-MailboxRow {
    param([string]$Tenant, [string]$Address)
    return (Get-TcRemediationTable $Tenant 'mailboxes' | Where-Object { $_['Primary address'] -eq $Address -or $_['UPN'] -eq $Address } | Select-Object -First 1)
}

function Find-TargetAccount {
    <# Target account of a delegate read in the source: by UPN, alias or ObjectId, then through the matrix. #>
    param([string]$Tenant, [string]$Delegate)
    $b = Get-TcRemediationTable $Tenant 'mailboxes' | Where-Object { $_['UPN'] -eq $Delegate -or $_['Primary address'] -eq $Delegate -or $_['Alias'] -eq $Delegate -or $_['ObjectId'] -eq $Delegate } | Select-Object -First 1
    $l = Find-TcMatrixRow $Tenant $(if ($b) { $b['UPN'] } else { $Delegate })
    if (-not $l -or $l['Decision'] -notin 'Create', 'Duplicate') { return $null }
    return $l['Target UPN']
}

function Test-SyncedMailbox {
    param([string]$Upn)
    $u = Get-TcRemediationTable 'Target' 'users' | Where-Object { $_['UPN'] -eq $Upn } | Select-Object -First 1
    return ($u -and (ConvertTo-TcBoolean $u['Synced']))
}

$NameFile = 'CON-SHARED-MAILBOXES'
$NameDecisions = @{}
if (Test-TcDecisionFile $NameFile) { foreach ($l in Read-TcDecisionRow $NameFile) { $NameDecisions[((Get-TcText $l 'Name')).ToLowerInvariant()] = (Get-TcMember $l 'Decision') } }

$Pairs = @{}
$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $items = @(foreach ($a in Get-TcRemediationPlanAction -Procedure 'CMP-SHARED-MAILBOXES' -Tenant $t) { @($a.items) })
    Write-TcRemediationNote ("{0} pair(s) of matching mailboxes" -f $items.Count)
    foreach ($e in $items) {
        if ($e -notmatch '^(.+?) and (.+)$') { continue }
        $source = $Matches[1]; $target = $Matches[2]
        $bs = Find-MailboxRow $t $source
        $bc = Find-MailboxRow 'Target' $target
        $l = if ($bs) { Find-TcMatrixRow $t $bs['UPN'] }
        $name = ((Get-TcAddressPrefix $source)).ToLowerInvariant()
        $nameChoice = $NameDecisions[$name]
        $proposal = if ($nameChoice -eq 'Common') { 'Merge' } elseif ($nameChoice -eq 'Separate') { 'Separate' } elseif ($l -and $l['Decision'] -eq 'Duplicate') { 'Merge' } elseif ($l -and $l['Decision'] -eq 'Create') { 'Separate' } else { '' }
        $Pairs["$t|$source"] = @{ Source = $bs; Target = $bc; Row = $l }
        [ordered]@{ Tenant = $t; 'Source mailbox' = $source; 'Target mailbox' = $target; 'Source type' = $(if ($bs) { $bs['Type'] }); 'Target type' = $(if ($bc) { $bc['Type'] })
                    'Source rights' = $(if ($bs) { @(Get-MailboxRight $t $bs).Count } else { 0 }); Matrix = $(if ($l) { $l['Decision'] }); Proposal = $proposal }
    }
}

$decisions = @(Get-TcDecision -Name 'CMP-SHARED-MAILBOXES' -Proposal @($proposals) -Key 'Tenant', 'Source mailbox' -Choice 'Merge', 'Separate', 'Separate-Rename')

$matrixRows = [System.Collections.Generic.List[object]]::new()
$initialValue = (Get-TcMember (Get-TcRemediationTenant 'Target') 'InitialDomain')
$targetPrefix = (Get-TcMember (Get-TcRemediationTenant 'Target') 'Prefix')
foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -in $c.Tenants }) {
    $t = (Get-TcMember $d 'Tenant')
    $i = Get-TcRemediationTenant $t
    $p = $Pairs["$t|$((Get-TcMember $d 'Source mailbox'))"]
    if (-not $p -or -not (Get-TcMember $p 'Source') -or -not (Get-TcMember $p 'Target')) { Write-TcRemediationAlert ("{0}: mailbox not found in the snapshot, pair ignored" -f (Get-TcMember $d 'Source mailbox')); continue }
    $targetMailbox = (Get-TcMember $p 'Target')['UPN']
    $syncedOne = Test-SyncedMailbox $targetMailbox

    if ((Get-TcMember $d 'Decision') -eq 'Merge') {
        $matrixRows.Add([pscustomobject][ordered]@{ Tenant = $t; 'Source UPN' = (Get-TcMember $p 'Source')['UPN']; Type = 'Shared'; Decision = 'Duplicate'; 'Target UPN' = $targetMailbox; 'Temporary UPN' = ''; 'Display name' = (Get-TcMember $p 'Source')['Name']; Before = $(if ((Get-TcMember $p 'Row')) { (Get-TcMember $p 'Row')['Decision'] }) })
        if ($syncedOne) { Write-TcRemediationAlert ("{0} is synced: add its original addresses in on-premises AD, the step that assigns domains to target accounts cannot do it" -f $targetMailbox) }
        $Origins[$targetMailbox] = (Get-TcText $d 'Source mailbox')
        foreach ($x in Get-TcRemediationTable $t 'mailboxPermissions' | Where-Object { $_['Mailbox'] -eq (Get-TcMember $d 'Source mailbox') -and $_['Right'] -match 'FullAccess' }) {
            $delegate = Find-TargetAccount $t $x['User']
            if (-not $delegate) { Write-TcRemediationAlert ("{0}: the delegate {1} has no target account in the matrix" -f (Get-TcMember $d 'Source mailbox'), $x['User']); continue }
            Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Add-MailboxPermission' -Parameters @{ Identity = $targetMailbox; User = $delegate; AccessRights = 'FullAccess'; AutoMapping = $false } -Object ("{0} / {1}" -f $targetMailbox, $delegate) `
                -Description ("Full access of {0} to {1}" -f $delegate, $targetMailbox) `
                -Test {
                    param($a)
                    $b = $a.parameters.Identity
                    try { $m = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-Mailbox' -Parameters @{ Identity = $b } } catch { $m = $null }
                    if (-not $m) { return Test-TcPostponed $a ("mailbox {0} not found in the target" -f $b) }
                    $origin = $Origins[$b]
                    if (-not @((Get-TcMember $m 'EmailAddresses') | Where-Object { ($_ -replace '^smtp:', '') -eq $origin }).Count) { return Test-TcPostponed $a ("{0} is not yet on {1}: run again after the domains are assigned to target accounts" -f $origin, $b) }
                    try { return [bool](Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-MailboxPermission' -Parameters @{ Identity = $b; User = $a.parameters.User }) } catch { return Test-TcPostponed $a ("account {0} not found in the target" -f $a.parameters.User) }
                } `
                -Undo @{ command = 'Remove-MailboxPermission'; parameters = @{ Identity = $targetMailbox; User = $delegate; AccessRights = 'FullAccess' } }
        }
        continue
    }

    $temporaryValue = '{0}.{1}@{2}' -f (Get-TcMember $i 'Prefix').ToLowerInvariant(), (Get-TcAddressPrefix (Get-TcMember $d 'Source mailbox')).ToLowerInvariant(), $initialValue
    $matrixRows.Add([pscustomobject][ordered]@{ Tenant = $t; 'Source UPN' = (Get-TcMember $p 'Source')['UPN']; Type = 'Shared'; Decision = 'Create'; 'Target UPN' = (Get-TcMember $p 'Source')['UPN']; 'Temporary UPN' = $temporaryValue; 'Display name' = ('{0}-{1}' -f (Get-TcMember $i 'Prefix'), (Get-TcMember $p 'Source')['Name']); Before = $(if ((Get-TcMember $p 'Row')) { (Get-TcMember $p 'Row')['Decision'] }) })
    if ((Get-TcMember $d 'Decision') -ne 'Separate-Rename') { continue }
    if ($syncedOne) { Write-TcRemediationAlert ("{0} is synced: its alias and name are changed in on-premises AD" -f $targetMailbox); continue }
    $newAlias = '{0}-{1}' -f $targetPrefix.ToLowerInvariant(), (Get-TcMember $p 'Target')['Alias']
    $newName = '{0}-{1}' -f $targetPrefix, (Get-TcMember $p 'Target')['Name']
    Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Set-Mailbox' -Parameters @{ Identity = $targetMailbox; Alias = $newAlias; DisplayName = $newName } -Object $targetMailbox `
        -Description ("Rename {0} to '{1}' (alias {2}); the SMTP address does not change" -f $targetMailbox, $newName, $newAlias) `
        -Test {
            param($a)
            $m = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-Mailbox' -Parameters @{ Identity = $a.parameters.Identity }
            if ((Get-TcMember $m 'IsDirSynced')) { return Test-TcPostponed $a ("{0} is synced: to rename in on-premises AD" -f $a.parameters.Identity) }
            $a.undo = @{ command = 'Set-Mailbox'; parameters = @{ Identity = $a.parameters.Identity; Alias = (Get-TcText $m 'Alias'); DisplayName = (Get-TcText $m 'DisplayName') } }
            return (Get-TcText $m 'Alias') -eq $a.parameters.Alias
        }
}

if ($matrixRows.Count) {
    Export-TcRemediationReport -Name 'matrix-rows-pairs' -Rows @($matrixRows) | Out-Null
    foreach ($t in @($matrixRows | ForEach-Object { (Get-TcMember $_ 'Tenant') } | Select-Object -Unique)) {
        $n = @($matrixRows | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Before') -ne (Get-TcMember $_ 'Decision') }).Count
        if (-not $n) { continue }
        Add-TcManualAction -Tenant $t -Object 'Matrix' -Description ("Register {0} row(s) in the matrix of {1}" -f $n, $t) `
            -Instruction @(("Copy exports\matrix-rows-pairs.csv into the matrix of {0}: Type Shared, Decision Duplicate with the UPN of the target mailbox, or Create with a prefixed name and temporary UPN." -f $t),
                        ('Run the preview again and fix the conflicts with the cutover tool of your choice, for {0}' -f $t))
    }
}

Invoke-TcRemediationPlan
Close-TcRemediation

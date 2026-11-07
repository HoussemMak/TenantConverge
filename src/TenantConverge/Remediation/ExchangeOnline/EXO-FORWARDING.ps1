# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has each automatic forwarding validated, then recreates it in the target or removes it (procedure EXO-FORWARDING).

.DESCRIPTION
    Data read: mailboxes table of each tenant (SMTP forwarding and internal forwarding), inbox rules, matrices.

    Decision: decisions\EXO-FORWARDING.csv, one row per mailbox, columns Tenant, Mailbox, Decision.
      Keep   : in the target, the forwarding stays. In a source, it is recreated on the target account with a copy kept;
      Remove : the forwarding is removed from the mailbox.
    EXO-AUTO-FORWARD reads this file too: while rows have no decision, the block is not planned.
    A forwarding to an unknown external address can signal a compromised account: handle it as a possible incident first.

    Recreating it needs the target mailbox: before PREP-02 or before the domains are assigned, the action is postponed and picked up
    at the next run. On a synced mailbox of the target, only the field to clear is written, and an internal forwarding is removed in
    on-premises AD. A forwarding to an address of a migrated domain must be reviewed after the domains are assigned.

    Emergency accounts, migration team accounts and kept accounts are never touched.
    Limits: inbox rules are not decided here, exports\inbox-rules-<tenant>.csv lists them and a rule to the outside raises an alert. A
    rule copied by the migration tool can recreate a refused forwarding.
#>
$c = Open-TcRemediation

$Identities = @{}

function Find-LiveMailbox {
    <# First identity known in the target; a missing mailbox returns $null. #>
    param([string[]]$Identities)
    foreach ($i in $Identities | Where-Object { $_ }) {
        try { return (Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-Mailbox' -Parameters @{ Identity = $i }) } catch { Write-Verbose "Not found: $i" }
    }
    return $null
}

$KnownDomains = @(@(Get-TcRemediationTable 'Target' 'acceptedDomains' | ForEach-Object { $_['Domain'] }) + @((Get-TcSourceRole) | ForEach-Object { $i = Get-TcRemediationTenant $_; @((Get-TcMember $i 'Domains')) + @((Get-TcMember $i 'InitialDomain')) }) | ForEach-Object { ([string]$_).ToLowerInvariant() })

$Mailboxes = @{}
$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $Mailboxes[$t] = @(Get-TcRemediationTable $t 'mailboxes')
    if (-not (Get-TcCount $Mailboxes[$t]) -and -not (Test-TcCollectionComplete $t 'mailboxes')) { Write-TcRemediationAlert 'Incomplete mailbox collection: run Invoke-TcAssessment again'; continue }
    $forwardings = @($Mailboxes[$t] | Where-Object { $_['SMTP forwarding'] -or $_['Internal forwarding'] })
    $rows = foreach ($b in $forwardings) {
        $internal = [string]$b['Internal forwarding']
        $internalTarget = if ($internal) { $Mailboxes[$t] | Where-Object { $_['ObjectId'] -eq $internal -or $_['Alias'] -eq $internal -or $_['UPN'] -eq $internal } | Select-Object -First 1 }
        $destination = if ($b['SMTP forwarding']) { ([string]$b['SMTP forwarding']) -replace '^smtp:', '' } elseif ($internalTarget) { $internalTarget['Primary address'] } else { $internal }
        $external = ($destination -match '@') -and (Get-TcAddressDomain $destination) -notin $KnownDomains
        [ordered]@{ Tenant = $t; Mailbox = $b['Primary address']; Upn = $b['UPN']; Destination = $destination; 'External destination' = $(if ($external) { 'Yes' } else { 'No' }); 'Copy kept' = $(if (ConvertTo-TcBoolean $b['Deliver and forward']) { 'Yes' } else { 'No' })
                    Proposal = $(if ($external -or (Test-TcProtectedAccount $b['UPN'] $i)) { '' } else { 'Keep' }) }
    }
    Write-TcRemediationNote ("{0} forward(s), {1} of them to an unknown external address" -f @($rows).Count, @($rows | Where-Object { (Get-TcMember $_ 'External destination') -eq 'Yes' }).Count)
    $rules = @(Get-TcRemediationTable $t 'inboxRules')
    if ($rules.Count) {
        Export-TcRemediationReport -Name "mailbox-rules-$t" -Rows @($rules) | Out-Null
        $externalUsers = @($rules | Where-Object { ConvertTo-TcBoolean $_['External'] }).Count
        if ($externalUsers) { Write-TcRemediationAlert ("{0} mailbox rule(s) forward to external recipients: to handle as a possible incident" -f $externalUsers) }
    }
    $rows
}

$decisions = @(Get-TcDecision -Name 'EXO-FORWARDING' -Proposal @($proposals) -Key 'Tenant', 'Mailbox' -Choice 'Keep', 'Remove')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -in $c.Tenants }) {
    $t = (Get-TcMember $d 'Tenant')
    $i = Get-TcRemediationTenant $t
    if (Test-TcProtectedAccount (Get-TcMember $d 'Mailbox') $i) { Write-TcRemediationAlert ("{0} is a protected account, the {1} decision is ignored" -f (Get-TcMember $d 'Mailbox'), (Get-TcMember $d 'Decision')); continue }

    if ((Get-TcMember $d 'Decision') -eq 'Remove') {
        Add-TcCommandAction -Tenant $t -Service Exo -Command 'Set-Mailbox' -Parameters @{ Identity = (Get-TcMember $d 'Mailbox'); ForwardingSmtpAddress = $null; ForwardingAddress = $null } -Object (Get-TcMember $d 'Mailbox') `
            -Description ("Remove the forwarding of {0} to {1}" -f (Get-TcMember $d 'Mailbox'), (Get-TcMember $d 'Destination')) `
            -Test {
                param($a)
                $m = Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command 'Get-Mailbox' -Parameters @{ Identity = $a.parameters.Identity }
                $a.undo = @{ command = 'Set-Mailbox'; parameters = @{ Identity = $a.parameters.Identity; ForwardingSmtpAddress = $(if ((Get-TcMember $m 'ForwardingSmtpAddress')) { (Get-TcText $m 'ForwardingSmtpAddress') }); ForwardingAddress = $(if ((Get-TcMember $m 'ForwardingAddress')) { (Get-TcText $m 'ForwardingAddress') }); DeliverToMailboxAndForward = [bool](Get-TcMember $m 'DeliverToMailboxAndForward') } }
                if ((Get-TcMember $m 'ForwardingAddress') -and (Get-TcMember $m 'IsDirSynced')) { return Test-TcPostponed $a ("{0} is synced: its internal forwarding is removed in the on-premises AD" -f $a.parameters.Identity) }
                if (-not (Get-TcMember $m 'ForwardingAddress')) { $a.parameters.Remove('ForwardingAddress') }
                if (-not (Get-TcMember $m 'ForwardingSmtpAddress')) { $a.parameters.Remove('ForwardingSmtpAddress') }
                return (-not (Get-TcMember $m 'ForwardingSmtpAddress') -and -not (Get-TcMember $m 'ForwardingAddress'))
            }
        continue
    }

    if ($t -eq 'Target') { continue }
    $row = Find-TcMatrixRow $t (Get-TcMember $d 'Upn')
    if (-not $row -or $row['Decision'] -notin 'Create', 'Duplicate') { Write-TcRemediationAlert ("{0}: no target account decided in the matrix, forwarding not recreated" -f (Get-TcMember $d 'Mailbox')); continue }
    if ((Get-TcMember $d 'Destination') -notmatch '@') { Write-TcRemediationAlert ("{0}: destination {1} not found, forwarding to recreate by hand" -f (Get-TcMember $d 'Mailbox'), (Get-TcMember $d 'Destination')); continue }
    $Identities[$row['Target UPN']] = @($row['Target UPN'], $row['Temporary UPN'])
    Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Set-Mailbox' -Parameters @{ Identity = $row['Target UPN']; ForwardingSmtpAddress = ('smtp:{0}' -f (Get-TcMember $d 'Destination')); DeliverToMailboxAndForward = $true } -Object $row['Target UPN'] `
        -Description ("Recreate the forwarding of {0} to {1}, copy kept" -f $row['Target UPN'], (Get-TcMember $d 'Destination')) `
        -Test {
            param($a)
            $m = Find-LiveMailbox $Identities[$a.parameters.Identity]
            if (-not $m) { return Test-TcPostponed $a ("{0} does not have a mailbox in the target yet" -f $a.parameters.Identity) }
            $a.parameters.Identity = (Get-TcText $m 'PrimarySmtpAddress')
            $a.undo = @{ command = 'Set-Mailbox'; parameters = @{ Identity = (Get-TcText $m 'PrimarySmtpAddress'); ForwardingSmtpAddress = $(if ((Get-TcMember $m 'ForwardingSmtpAddress')) { (Get-TcText $m 'ForwardingSmtpAddress') }); DeliverToMailboxAndForward = [bool](Get-TcMember $m 'DeliverToMailboxAndForward') } }
            return ((Get-TcText $m 'ForwardingSmtpAddress') -replace '^smtp:', '') -eq ($a.parameters.ForwardingSmtpAddress -replace '^smtp:', '')
        }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $removedOnes = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Remove' } | ForEach-Object { (Get-TcMember $_ 'Mailbox') })
    $live = @(Invoke-TcServiceCommand -Tenant $t -Service Exo -Command 'Get-EXOMailbox' -Parameters @{ ResultSize = 'Unlimited'; Properties = @('ForwardingSmtpAddress', 'ForwardingAddress') } | Where-Object { (Get-TcMember $_ 'ForwardingSmtpAddress') -or (Get-TcMember $_ 'ForwardingAddress') })
    $still = @($live | Where-Object { (Get-TcText $_ 'PrimarySmtpAddress') -in $removedOnes })
    if ($still.Count) { New-TcRemediationResult Blocking ("{0} forwarding(s) to remove are still in place" -f $still.Count) } else { New-TcRemediationResult OK ("{0} forwarding(s) remain, none of them among the removed forwardings" -f $live.Count) }
}
Close-TcRemediation

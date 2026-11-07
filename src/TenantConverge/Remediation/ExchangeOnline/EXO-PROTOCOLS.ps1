# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Lists POP, IMAP and authenticated SMTP, then turns on in the target only what is needed (procedure EXO-PROTOCOLS).

.DESCRIPTION
    Data read: the mailboxProtocols and legacySignIns tables of each tenant, the SMTP setting of the organization, matrices.
    exports\protocols-<tenant>.csv gives each mailbox, its protocols and the observed use. A protocol that is on does not prove a use:
    POP and IMAP are on by default. The Unknown client of the sign-ins does not count as use.

    Decision: decisions\EXO-PROTOCOLS.csv, with Keep or Disable.
      one row per mailbox with an observed use or authenticated SMTP on, in each tenant.
        Source: Keep carries the access over to the target account (after the domains are assigned); Disable carries nothing over.
        Target: Keep keeps the access; Disable cuts POP, IMAP and authenticated SMTP of this mailbox.
      three grouped rows for the target:
        (CAS plan)        : POP and IMAP off by default on new mailboxes, including migrated ones;
        (other mailboxes) : POP and IMAP off on all mailboxes with no row of their own;
        (organization)    : authenticated SMTP off for the organization, after the exceptions, and only if no target mailbox still
                            waits for its decision. A mailbox kept with an SMTP use gets its exception, even if it inherited the
                            setting of the organization.

    Emergency accounts, migration team accounts and kept accounts are never touched.
    Limits: only the sign-ins of the log retention period are seen. Reconfiguring devices and the send test stay to be done by a
    person, after the cutover.
#>
$c = Open-TcRemediation

$Targets = @{}
$CasRow = '(CAS plan)'
$OtherRow = '(other mailboxes)'
$OrganizationRow = '(organization)'

function Get-ProtocolUsage {
    <# What the legacy sign-ins show: SMTP, POP, IMAP. #>
    param([object[]]$SignIns)
    $n = @($SignIns | ForEach-Object { [string]$_['Client'] })
    return @(if ($n -match 'SMTP') { 'SMTP' }; if ($n -match 'POP') { 'POP' }; if ($n -match 'IMAP') { 'IMAP' })
}

function Add-CaseUndo {
    <# Reads the mailbox in the -Test and prepares the return to the earlier values. #>
    param($Action)
    $b = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-CASMailbox' -Parameters @{ Identity = (Get-TcMember (Get-TcMember $Action 'parameters') 'Identity') }
    $Action.undo = @{ command = 'Set-CASMailbox'; parameters = @{ Identity = (Get-TcMember (Get-TcMember $Action 'parameters') 'Identity'); PopEnabled = [bool](Get-TcMember $b 'PopEnabled'); ImapEnabled = [bool](Get-TcMember $b 'ImapEnabled'); SmtpClientAuthenticationDisabled = (Get-TcMember $b 'SmtpClientAuthenticationDisabled') } }
    return $b
}

function Test-AlreadyDone {
    <# True if the mailbox already has the values asked for. #>
    param($Action, $Mailbox)
    foreach ($k in @((Get-TcMember $Action 'parameters').Keys | Where-Object { $_ -ne 'Identity' })) { if ((Get-TcMember $Mailbox $k) -ne (Get-TcMember $Action 'parameters')[$k]) { return $false } }
    return $true
}

$ReadItems = @{}
$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $table = @(Get-TcRemediationTable $t 'mailboxProtocols')
    if (-not $table.Count -and -not (Test-TcCollectionComplete $t 'mailboxProtocols')) { Write-TcRemediationAlert 'Incomplete protocol collection: run Invoke-TcAssessment again'; continue }
    $legacy = @(Get-TcRemediationTable $t 'legacySignIns' | Where-Object { $_['Client'] -match 'SMTP|POP|IMAP' })
    $rows = foreach ($b in $table) {
        $u = @($legacy | Where-Object { $_['UPN'] -eq $b['Mailbox'] })
        [pscustomobject][ordered]@{ Tenant = $t; Mailbox = $b['Mailbox']; POP = [bool]$b['POP']; IMAP = [bool]$b['IMAP']; SMTP = (ConvertTo-TcBoolean $b['Authenticated SMTP']); 'SMTP per'= [string]$b['Authenticated SMTP']
                                    'Observed use' = (@($u | ForEach-Object { '{0} ({1})' -f $_['Client'], $_['Sign-ins'] }) -join ', ') }
    }
    $ReadItems[$t] = @($rows)
    Write-TcRemediationNote ("POP: {0} - IMAP: {1} - authenticated SMTP: {2} - observed use: {3} mailbox(es)" -f @($rows | Where-Object POP).Count, @($rows | Where-Object IMAP).Count, @($rows | Where-Object SMTP).Count, @($rows | Where-Object 'Observed use').Count)
    Export-TcRemediationReport -Name "protocols-$t" -Rows @($rows) | Out-Null

    foreach ($l in $rows | Where-Object { ((Get-TcMember $_ 'Observed use') -or (Get-TcMember $_ 'SMTP')) -and -not (Test-TcProtectedAccount (Get-TcMember $_ 'Mailbox') $i) }) {
        [ordered]@{ Tenant = $t; Mailbox = (Get-TcMember $l 'Mailbox'); Protocols = (@(if ((Get-TcMember $l 'POP')) { 'POP' }; if ((Get-TcMember $l 'IMAP')) { 'IMAP' }; if ((Get-TcMember $l 'SMTP')) { 'SMTP' }) -join ' '); 'Observed use' = (Get-TcMember $l 'Observed use'); Proposal = '' }
    }
    if ($t -eq 'Target') {
        $n = @($rows | Where-Object { ((Get-TcMember $_ 'POP') -or (Get-TcMember $_ 'IMAP')) -and -not (Get-TcMember $_ 'Observed use') -and -not (Get-TcMember $_ 'SMTP') }).Count
        [ordered]@{ Tenant = $t; Mailbox = $CasRow; Protocols = 'POP IMAP'; 'Observed use' = 'New mailboxes, including migrated mailboxes'; Proposal = 'Disable' }
        [ordered]@{ Tenant = $t; Mailbox = $OtherRow; Protocols = 'POP IMAP'; 'Observed use' = ("No use observed on {0} mailbox(es)" -f $n); Proposal = 'Disable' }
        if (-not (ConvertTo-TcBoolean (Get-TcRemediationValue $t 'exchangeSettings' 'Transport.SmtpClientAuthenticationDisabled'))) {
            [ordered]@{ Tenant = $t; Mailbox = $OrganizationRow; Protocols = 'SMTP'; 'Observed use' = 'Authenticated SMTP open for the whole organization'; Proposal = 'Disable' }
        }
    }
}

$decisions = @(Get-TcDecision -Name 'EXO-PROTOCOLS' -Proposal @($proposals) -Key 'Tenant', 'Mailbox' -Choice 'Keep', 'Disable')

$group = @{}
foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq 'Target' -and (Get-TcMember $_ 'Mailbox') -like '(*' }) { $group[$d.Mailbox] = (Get-TcMember $d 'Decision') }

if ('Target' -in $c.Tenants) {
    $targetInfoRow = Get-TcRemediationTenant 'Target'
    if ($group[$CasRow] -eq 'Disable') {
        Add-TcBlockAction -Tenant 'Target' -Service Exo -Object 'CAS plans' -Description 'Turn off POP and IMAP by default on new mailboxes (CAS plans)' `
            -Test { -not @(Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-CASMailboxPlan' | Where-Object { (Get-TcMember $_ 'PopEnabled') -or (Get-TcMember $_ 'ImapEnabled') }).Count } `
            -Block {
                param($a)
                $undo = [System.Collections.Generic.List[object]]::new()
                foreach ($p in @(Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-CASMailboxPlan' | Where-Object { (Get-TcMember $_ 'PopEnabled') -or (Get-TcMember $_ 'ImapEnabled') })) {
                    $undo.Add(@{ command = 'Set-CASMailboxPlan'; parameters = @{ Identity = (Get-TcText $p 'Identity'); PopEnabled = [bool](Get-TcMember $p 'PopEnabled'); ImapEnabled = [bool](Get-TcMember $p 'ImapEnabled') } })
                    Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Set-CASMailboxPlan' -Parameters @{ Identity = (Get-TcText $p 'Identity'); PopEnabled = $false; ImapEnabled = $false } | Out-Null
                    $a.undo = @($undo)
                }
            }
    }

    $mailboxesWithRow = @(@($proposals | Where-Object { (Get-TcMember $_ 'Tenant') -eq 'Target' -and (Get-TcMember $_ 'Mailbox') -notlike '(*' }) | ForEach-Object { (Get-TcMember $_ 'Mailbox') })
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq 'Target' -and (Get-TcMember $_ 'Mailbox') -notlike '(*' }) {
        if (Test-TcProtectedAccount (Get-TcMember $d 'Mailbox') $targetInfoRow) { continue }
        $r = $ReadItems['Target'] | Where-Object Mailbox -eq (Get-TcMember $d 'Mailbox') | Select-Object -First 1
        if ((Get-TcMember $d 'Decision') -eq 'Disable') { $p = @{ Identity = (Get-TcMember $d 'Mailbox'); PopEnabled = $false; ImapEnabled = $false; SmtpClientAuthenticationDisabled = $true }; $text = 'Turn off POP, IMAP and authenticated SMTP for {0}' }
        elseif ($r -and ((Get-TcMember $r 'SMTP') -or (Get-TcMember $r 'Observed use') -match 'SMTP')) { $p = @{ Identity = (Get-TcMember $d 'Mailbox'); SmtpClientAuthenticationDisabled = $false }; $text = 'Keep the authenticated SMTP of {0} as an exception' }
        else { continue }
        # an exception that fails must stop the plan before the organization is cut
        Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Set-CASMailbox' -Parameters $p -Object (Get-TcMember $d 'Mailbox') -Description ($text -f (Get-TcMember $d 'Mailbox')) -Critical:((Get-TcMember $d 'Decision') -ne 'Disable') `
            -Test { param($a) Test-AlreadyDone $a (Add-CaseUndo $a) }
    }

    if ($group[$OtherRow] -eq 'Disable') {
        foreach ($l in @($ReadItems['Target']) | Where-Object { ((Get-TcMember $_ 'POP') -or (Get-TcMember $_ 'IMAP')) -and (Get-TcMember $_ 'Mailbox') -notin $mailboxesWithRow -and -not (Test-TcProtectedAccount (Get-TcMember $_ 'Mailbox') $targetInfoRow) }) {
            Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Set-CASMailbox' -Parameters @{ Identity = (Get-TcMember $l 'Mailbox'); PopEnabled = $false; ImapEnabled = $false } -Object (Get-TcMember $l 'Mailbox') `
                -Description ("Turn off POP and IMAP for {0}" -f (Get-TcMember $l 'Mailbox')) `
                -Test { param($a) Test-AlreadyDone $a (Add-CaseUndo $a) }
        }
    }
}

$carriedOver = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -ne 'Target' -and (Get-TcMember $_ 'Tenant') -in $c.Tenants -and (Get-TcMember $_ 'Decision') -eq 'Keep' })
foreach ($d in $carriedOver) {
    $t = (Get-TcMember $d 'Tenant')
    $row = Find-TcMatrixRow $t (Get-TcMember $d 'Mailbox')
    if (-not $row -or $row['Decision'] -notin 'Create', 'Duplicate') { Write-TcRemediationAlert ("{0}: no target account decided in the matrix, access not carried over" -f (Get-TcMember $d 'Mailbox')); continue }
    $r = $ReadItems[$t] | Where-Object Mailbox -eq (Get-TcMember $d 'Mailbox') | Select-Object -First 1
    $seen = @(Get-ProtocolUsage @(Get-TcRemediationTable $t 'legacySignIns' | Where-Object { $_['UPN'] -eq (Get-TcMember $d 'Mailbox') }))
    $p = @{ Identity = $row['Target UPN'] }
    if ('POP' -in $seen) { $p.PopEnabled = $true }
    if ('IMAP' -in $seen) { $p.ImapEnabled = $true }
    if ('SMTP' -in $seen -or ($r -and (Get-TcMember $r 'SMTP'))) { $p.SmtpClientAuthenticationDisabled = $false }
    if ($p.Count -lt 2) { continue }
    $Targets[$row['Target UPN']] = $row['Source UPN']
    Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Set-CASMailbox' -Parameters $p -Object $row['Target UPN'] -Description ("Carry over the access of {0} onto {1}" -f (Get-TcMember $d 'Mailbox'), $row['Target UPN']) `
        -Test {
            param($a)
            try { return (Test-AlreadyDone $a (Add-CaseUndo $a)) } catch { return (Test-TcPostponed $a ("{0} does not have its own mailbox in the target yet: run again after the domains are assigned to target accounts" -f $a.parameters.Identity)) }
        }
}

$pendingMailboxes = @($proposals | Where-Object { (Get-TcMember $_ 'Tenant') -eq 'Target' -and (Get-TcMember $_ 'Mailbox') -notlike '(*' -and (Get-TcMember $_ 'Mailbox') -notin @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq 'Target' } | ForEach-Object { (Get-TcMember $_ 'Mailbox') }) })
if ($group[$OrganizationRow] -eq 'Disable' -and $pendingMailboxes.Count) {
    Write-TcRemediationAlert ("Turning off authenticated SMTP for the organization is postponed: {0} mailbox(es) of the target are waiting for their decision." -f $pendingMailboxes.Count)
}
elseif ($group[$OrganizationRow] -eq 'Disable') {
    Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Set-TransportConfig' -Parameters @{ SmtpClientAuthenticationDisabled = $true } -Object 'Organization' `
        -Description "Turn off authenticated SMTP for the organization, except the per-mailbox exceptions" `
        -Test {
            param($a)
            $x = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-TransportConfig'
            $a.undo = @{ command = 'Set-TransportConfig'; parameters = @{ SmtpClientAuthenticationDisabled = [bool](Get-TcMember $x 'SmtpClientAuthenticationDisabled') } }
            return [bool](Get-TcMember $x 'SmtpClientAuthenticationDisabled')
        }
}

foreach ($t in @($carriedOver | ForEach-Object { (Get-TcMember $_ 'Tenant') } | Select-Object -Unique)) {
    Add-TcManualAction -Tenant $t -Object 'Devices' -Description ("Reconfigure the devices and applications of {0} after the cutover" -f $t) `
        -Instruction @("Choose for each device or application the sending method: authenticated SMTP, direct send or relay through a connector.", "After the cutover, reconfigure toward the target and test a send: a forgotten scanner stops sending on the Monday of the cutover.")
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $org = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-TransportConfig'
    if ($group[$OrganizationRow] -eq 'Disable' -and -not $pendingMailboxes.Count -and -not (Get-TcMember $org 'SmtpClientAuthenticationDisabled')) { New-TcRemediationResult Blocking 'Authenticated SMTP still open for the organization' } else { New-TcRemediationResult OK ("Authenticated SMTP of the organization turned off: {0}" -f [bool](Get-TcMember $org 'SmtpClientAuthenticationDisabled')) }
    $openOnes = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-EXOCasMailbox' -Parameters @{ ResultSize = 'Unlimited'; Properties = @('PopEnabled', 'ImapEnabled', 'SmtpClientAuthenticationDisabled') } | Where-Object { (Get-TcMember $_ 'PopEnabled') -or (Get-TcMember $_ 'ImapEnabled') -or (Get-TcMember $_ 'SmtpClientAuthenticationDisabled') -eq $false })
    New-TcRemediationResult Info ("{0} mailbox(es) keep POP, IMAP or authenticated SMTP" -f $openOnes.Count)
}
Close-TcRemediation

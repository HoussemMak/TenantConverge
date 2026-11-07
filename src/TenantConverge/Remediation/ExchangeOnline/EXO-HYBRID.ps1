# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the removal of the last on-premises Exchange server decided and prepares what depends on it (procedure EXO-HYBRID).

.DESCRIPTION
    Data read: hybrid objects, synced accounts of the target, mailboxes of the target, matrices of the sources.

    Decision: decisions\EXO-HYBRID.csv, Keep or Remove. Keep is proposed: this removal raises the risk of the cutover and is kept apart
    from the migration windows.

    exports\synced-duplicates.csv lists the Duplicate accounts whose target mailbox is synced, with their original addresses. The cutover
    writes these addresses with Set-Mailbox: this is impossible on a synced mailbox while its Exchange attributes are managed on
    premises. These addresses are added in on-premises AD (Set-RemoteMailbox on the Exchange server).

    Nothing is automated on the on-premises server: the script has no access to it. And Microsoft does not support
    Set-Mailbox -IsExchangeCloudManaged with certificate authentication: moving the authority is done with an administrator account,
    in an interactive session. It stays a human action.
#>
$c = Open-TcRemediation

$Users = @{}
foreach ($u in Get-TcRemediationTable 'Target' 'users') { $Users[([string]$u['UPN']).ToLowerInvariant()] = $u }
$TargetMailboxes = @(Get-TcRemediationTable 'Target' 'mailboxes')

function Test-SyncedAccount {
    param([string]$Upn)
    $u = $Users[$Upn.ToLowerInvariant()]
    return ($u -and (ConvertTo-TcBoolean $u['Synced']))
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $objects = @(Get-TcRemediationTable $t 'exchangeHybrid')
    if (-not $objects.Count -and -not (Test-TcCollectionComplete $t 'exchangeHybrid')) { Write-TcRemediationAlert 'Partial hybrid collection: confirm with Get-OnPremisesOrganization' }
    $syncedOnes = @($TargetMailboxes | Where-Object { Test-SyncedAccount $_['UPN'] })
    Write-TcRemediationNote ("{0} hybrid object(s); {1} synced mailbox(es) of the target out of {2}" -f $objects.Count, $syncedOnes.Count, $TargetMailboxes.Count)
    [ordered]@{ Tenant = $t; 'Hybrid objects' = (@($objects | ForEach-Object { '{0}: {1}' -f $_['Item'], $_['Detail'] }) -join ' ; '); 'Synced mailboxes' = $syncedOnes.Count; Proposal = 'Keep' }
}

$duplicates = @(foreach ($s in (Get-TcSourceRole)) {
    $i = Get-TcRemediationTenant $s
    foreach ($l in @((Get-TcMember (Get-TcRemediationIdentity $s) 'rows')) | Where-Object { $_['Decision'] -eq 'Duplicate' -and (Test-SyncedAccount $_['Target UPN']) }) {
        $b = Get-TcRemediationTable $s 'mailboxes' | Where-Object { $_['UPN'] -eq $l['Source UPN'] } | Select-Object -First 1
        $addresses = if ($b) { @([string]$b['Addresses'] -split ';\s*' | Where-Object { (Get-TcAddressDomain $_) -in (Get-TcMember $i 'Domains') }) } else { @($l['Source UPN']) }
        [pscustomobject][ordered]@{ Source = $s; 'Source UPN' = $l['Source UPN']; 'Target mailbox' = $l['Target UPN']; "Original addresses" = ($addresses -join '; ') }
    }
})
Write-TcRemediationNote ("{0} duplicate(s) target a synced mailbox: their original addresses go through the on-premises AD" -f $duplicates.Count)
if ($duplicates.Count) { Export-TcRemediationReport -Name 'synced-duplicates' -Rows $duplicates | Out-Null }

$decisions = @(Get-TcDecision -Name 'EXO-HYBRID' -Proposal @($proposals) -Key 'Tenant' -Choice 'Keep', 'Remove')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -in $c.Tenants }) {
    if ((Get-TcMember $d 'Decision') -eq 'Keep') {
        Add-TcManualAction -Tenant (Get-TcMember $d 'Tenant') -Object 'On-premises Exchange server' -Description 'Keep the on-premises server and manage the Exchange attributes there' `
            -Instruction @('The Exchange attributes of synced objects are managed from the on-premises server: do not shut it down or delete it.',
                        ("On this server, add the original addresses of {0} duplicate(s), see exports\synced-duplicates.csv." -f $duplicates.Count))
        continue
    }
    Add-TcManualAction -Tenant (Get-TcMember $d 'Tenant') -Object 'On-premises Exchange server' -Description 'Inventory what still depends on the on-premises Exchange server' `
        -Instruction @('On the server: remaining mailboxes, SMTP relays, applications and connectors.', 'An application that relays through this server stops sending when it is removed.')
    Add-TcManualAction -Tenant (Get-TcMember $d 'Tenant') -Object 'Attribute authority' -Description 'Move the Exchange attributes to the cloud on a pilot group' `
        -Instruction @('In an interactive session with an Exchange Administrator account, since the certificate is not supported:', 'Set-Mailbox -Identity <mailbox> -IsExchangeCloudManaged $true',
                    'Entra Connect Sync must be version 2.5.190.0 or later. After a local change, wait for one synchronization cycle and 24 hours.')
    Add-TcManualAction -Tenant (Get-TcMember $d 'Tenant') -Object 'Uninstall' -Description 'Uninstall the server with Exchange Setup, after the pilot is validated' `
        -Instruction @('Follow the Microsoft procedure. Never simply shut down or delete the last server.', 'Keep this removal outside the migration windows.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $o = @(Invoke-TcServiceCommand -Tenant $t -Service Exo -Command 'Get-OnPremisesOrganization')
    New-TcRemediationResult Info ("{0} on-premises organization(s) declared" -f $o.Count)
    $m = @(Invoke-TcServiceCommand -Tenant $t -Service Exo -Command 'Get-Mailbox' -Parameters @{ ResultSize = 'Unlimited' } | Where-Object { (Get-TcMember $_ 'IsDirSynced') })
    New-TcRemediationResult Info ("{0} synced mailbox(es), of which {1} managed in the cloud" -f $m.Count, @($m | Where-Object IsExchangeCloudManaged).Count)
}
Close-TcRemediation

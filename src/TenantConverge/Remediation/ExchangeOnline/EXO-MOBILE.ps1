# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Prepares the reconfiguration of mobile devices: list by user and first-day support (procedure EXO-MOBILE).

.DESCRIPTION
    Source tenants (STAB-01).

    Data read: mobileDevices table and mailboxes of the source, with no connection. exports\devices-<tenant>.csv gives one device per row;
    exports\mobile-users-<tenant>.csv gives one user per row, for the guide and the support call.
    The native client is marked: it can be blocked by the conditional access of the target.

    The snapshot only has the first sync. In an -Apply run, a read of the mailboxes produces exports\active-devices-<tenant>.csv with the
    last successful sync.

    Limits: the guide, the communication and the support are human tasks. No API reconfigures a device.
#>
$c = Open-TcRemediation

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $devices = @(Get-TcRemediationTable $t 'mobileDevices')
    if (-not $devices.Count -and -not (Test-TcCollectionComplete $t 'mobileDevices')) { Write-TcRemediationAlert 'Device collection incomplete: run Invoke-TcAssessment again'; continue }

    $rows = foreach ($x in $devices) {
        [pscustomobject][ordered]@{ User = $x['User']; 'Model' = $x['Model']; 'System' = $x['System']; Client = $x['Client']; Type = $x['Type']; 'Access' = $x['Access']; 'First sync' = $x['First sync']; 'Native client' = $(if ($x['Client'] -eq 'EAS') { 'Yes' } else { 'No' }) }
    }
    $persons = @($rows | Group-Object User | ForEach-Object {
        [pscustomobject][ordered]@{ User = (Get-TcMember $_ 'Name'); Devices = (Get-TcCount $_); 'Native client' = $(if (@((Get-TcMember $_ 'Group') | Where-Object { (Get-TcMember $_ 'Native client') -eq 'Yes' }).Count) { 'Yes' } else { 'No' }); 'Systems' = (@((Get-TcMember $_ 'Group') | ForEach-Object { (Get-TcMember $_ 'System') } | Select-Object -Unique) -join ', ') }
    })
    Write-TcRemediationNote ("{0} device(s) for {1} user(s); {2} with the native client" -f $devices.Count, $persons.Count, @($persons | Where-Object { (Get-TcMember $_ 'Native client') -eq 'Yes' }).Count)
    if ($devices.Count) {
        Export-TcRemediationReport -Name "devices-$t" -Rows @($rows) | Out-Null
        Export-TcRemediationReport -Name "mobile-users-$t" -Rows $persons | Out-Null
    }

    $mailboxes = @(Get-TcRemediationTable $t 'mailboxes' | Where-Object { $_['Name'] -in (Get-TcMember $persons 'User') } | ForEach-Object { $_['UPN'] })
    if ($mailboxes.Count) {
        Add-TcBlockAction -Tenant $t -Service Exo -Object 'Active devices' -Data @{ Mailboxes = $mailboxes } -Description ("Read the last sync of the devices of {0} mailbox(es)" -f $mailboxes.Count) -Reason 'Read only: the report stays in the log folder.' `
            -Block {
                param($a)
                $activeOnes = foreach ($upn in $a.data.Mailboxes) {
                    try { $list = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command 'Get-EXOMobileDeviceStatistics' -Parameters @{ UserPrincipalName = $upn }) } catch { continue }
                    foreach ($s in $list) { [pscustomobject][ordered]@{ 'Mailbox' = $upn; 'Model' = (Get-TcMember $s 'DeviceModel'); 'System' = (Get-TcMember $s 'DeviceOS'); Client = (Get-TcMember $s 'ClientType'); 'Last successful sync' = (Get-TcText $s 'LastSuccessSync') } }
                }
                Export-TcRemediationReport -Name ("active-devices-{0}" -f $a.tenant) -Rows @($activeOnes) | Out-Null
            }
    }

    Add-TcManualAction -Tenant $t -Object 'Guide and support' -Description ("Prepare {0} mobile user(s) of {1} for the cutover" -f $persons.Count, $t) `
        -Instruction @('Add the steps for Outlook mobile and for the native client to the user guide; first check that the conditional access of the target allows the native client.',
                    "Warn these users before the cutover: the old account stops syncing.",
                    'Plan the first-day support with the list exports\mobile-users: remove the old account, add the new one, test sending and receiving.')
}

Invoke-TcRemediationPlan
Close-TcRemediation

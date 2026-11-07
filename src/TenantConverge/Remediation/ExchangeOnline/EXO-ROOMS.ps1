# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Recreates the rooms and equipment in the target with the prefix and the same booking rules (procedure EXO-ROOMS).

.DESCRIPTION
    Data read: rooms and mailboxes tables of the source, matrix. Delegates and booking lists are not in the snapshot: they are read in
    the source at run time.
    A resource whose matrix row is not Create is not handled.

    Two steps, the same script runs again:
      1. before the cutover: creation of the mailbox, then booking rules. A delegate with no account in the target is reported;
      2. after the domains are verified: original address on the mailbox. Postponed while the domain is not accepted in the target.

    Limits: copying the calendar stays in the copy tool. Existing bookings point to the old address: check them after the copy.
#>
$c = Open-TcRemediation

$Copies = @('AutomateProcessing', 'BookingWindowInDays', 'MaximumDurationInMinutes', 'AllowConflicts', 'AllBookInPolicy', 'AllRequestInPolicy', 'ProcessExternalMeetingMessages')

function Get-TargetMailbox {
    param([string]$Identity)
    try { return (Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-Mailbox' -Parameters @{ Identity = $Identity }) } catch { return $null }
}

function Find-TargetAccountRow {
    <# Target account of a source account, from the matrix; returns the identity that exists. #>
    param([string]$Tenant, [string]$Account)
    $l = @((Get-TcMember (Get-TcRemediationIdentity $Tenant) 'rows')) | Where-Object { $_['Source UPN'] -eq $Account } | Select-Object -First 1
    if (-not $l -or $l['Decision'] -notin 'Create', 'Duplicate') { return $null }
    foreach ($i in @($l['Target UPN'], $l['Temporary UPN']) | Where-Object { $_ }) { if (Get-TargetMailbox $i) { return $i } }
    return $null
}

$Handled = [System.Collections.Generic.List[object]]::new()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $rooms = @(Get-TcRemediationTable $t 'roomsAndEquipment')
    if (-not $rooms.Count -and -not (Test-TcCollectionComplete $t 'roomsAndEquipment')) { Write-TcRemediationAlert 'Room collection incomplete: run Invoke-TcAssessment again'; continue }
    Write-TcRemediationNote ("{0} room(s) or equipment; {1} delegate(s) in total" -f $rooms.Count, (Get-TcMember (@($rooms | ForEach-Object { [int]$_['Delegates'] }) | Measure-Object -Sum) 'Sum'))

    foreach ($s in $rooms) {
        $b = Get-TcRemediationTable $t 'mailboxes' | Where-Object { $_['Primary address'] -eq $s['Address'] } | Select-Object -First 1
        $upn = if ($b) { $b['UPN'] } else { $s['Address'] }
        $row = @((Get-TcMember (Get-TcRemediationIdentity $t) 'rows')) | Where-Object { $_['Source UPN'] -eq $upn } | Select-Object -First 1
        if ($row -and $row['Decision'] -ne 'Create') { Write-TcRemediationNote ("{0}: matrix says {1}, resource not handled" -f $s['Address'], $row['Decision']); continue }
        if (-not $row) { Write-TcRemediationAlert ("{0}: missing from the matrix, resource not handled" -f $s['Address']); continue }

        $name = '{0}-{1}' -f (Get-TcMember $i 'Prefix'), $s['Resource']
        $alias = ('{0}-{1}' -f (Get-TcMember $i 'Prefix'), ($s['Resource'] -replace '[^A-Za-z0-9\.\-_]', '')).ToLowerInvariant()
        $kind = if ($s['Type'] -eq 'RoomMailbox') { 'Room' } else { 'Equipment' }
        $Handled.Add(@{ Tenant = $t; Name = $name; Handling = $s['Processing']; Window = $s['Booking window (days)']; Duration = $s['Max duration (min)'] })

        Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'New-Mailbox' -Parameters @{ Name = $name; Alias = $alias; $kind = $true } -Object $name -Description ("Create {0} in the target ({1})" -f $name, $kind) `
            -Test { param($a) [bool](Get-TargetMailbox $a.parameters.Name) } `
            -Undo @{ command = 'Remove-Mailbox'; parameters = @{ Identity = $name } }

        Add-TcBlockAction -Tenant 'Target' -Service Exo -Object $name -Data @{ Source = $t; Address = $s['Address']; Name = $name; Handling = $s['Processing']; Window = [int]$s['Booking window (days)']; Duration = [int]$s['Max duration (min)'] } `
            -Description ("Carry over the booking rules of {0} ({1}, {2} d, {3} min)" -f $s['Address'], $s['Processing'], $s['Booking window (days)'], $s['Max duration (min)']) `
            -Test {
                param($a)
                $x = $a.data
                if (-not (Get-TargetMailbox (Get-TcMember $x 'Name'))) { return Test-TcPostponed $a ("{0} does not exist in the target yet" -f (Get-TcMember $x 'Name')) }
                $k = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-CalendarProcessing' -Parameters @{ Identity = (Get-TcMember $x 'Name') }
                $before = @{ Identity = (Get-TcMember $x 'Name') }
                foreach ($n in $Copies) { $before[$n] = (Get-TcMember $k $n) }
                $a.undo = @{ command = 'Set-CalendarProcessing'; parameters = $before }
                return ((Get-TcText $k 'AutomateProcessing') -eq (Get-TcMember $x 'Handling') -and [int](Get-TcMember $k 'BookingWindowInDays') -eq (Get-TcMember $x 'Window') -and [int](Get-TcMember $k 'MaximumDurationInMinutes') -eq (Get-TcMember $x 'Duration'))
            } `
            -Block {
                param($a)
                $x = $a.data
                $k = Invoke-TcServiceCommand -Tenant (Get-TcMember $x 'Source') -Service Exo -Command 'Get-CalendarProcessing' -Parameters @{ Identity = (Get-TcMember $x 'Address') }
                $p = @{ Identity = (Get-TcMember $x 'Name') }
                foreach ($n in $Copies) { $p[$n] = (Get-TcMember $k $n) }
                $missing = [System.Collections.Generic.List[string]]::new()
                $lists = @{ ResourceDelegates = [System.Collections.Generic.List[string]]::new(); BookInPolicy = [System.Collections.Generic.List[string]]::new() }
                foreach ($field in 'ResourceDelegates', 'BookInPolicy') {
                    foreach ($v in @((Get-TcMember $k $field) | Where-Object { $_ })) {
                        try { $r = Invoke-TcServiceCommand -Tenant (Get-TcMember $x 'Source') -Service Exo -Command 'Get-Recipient' -Parameters @{ Identity = [string]$v } } catch { $r = $null }
                        $account = if ($r) { Find-TargetAccountRow (Get-TcMember $x 'Source') ((Get-TcText $r 'PrimarySmtpAddress')) }
                        if ($account) { $lists[$field].Add($account) } else { $missing.Add([string]$v) }
                    }
                }
                if ((Get-TcCount (Get-TcMember $lists 'ResourceDelegates'))) { $p.ResourceDelegates = @((Get-TcMember $lists 'ResourceDelegates')) }
                if ((Get-TcCount (Get-TcMember $lists 'BookInPolicy'))) { $p.BookInPolicy = @((Get-TcMember $lists 'BookInPolicy')) }
                Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Set-CalendarProcessing' -Parameters $p | Out-Null
                if ($missing.Count) { Write-TcRemediationAlert ("{0}: {1} delegate(s) with no account in the target, to add after their cutover: {2}" -f (Get-TcMember $x 'Name'), $missing.Count, ($missing -join ', ')) }
            }

        $addresses = if ($b) { @([string]$b['Addresses'] -split ';\s*' | Where-Object { (Get-TcAddressDomain $_) -in (Get-TcMember $i 'Domains') }) } else { @($s['Address']) }
        foreach ($x in $addresses) {
            $addition = 'smtp:{0}' -f $x
            Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Set-Mailbox' -Parameters @{ Identity = $name; EmailAddresses = @{ Add = $addition } } -Object $name -Description ("Give {0} back its original address {1}" -f $name, $x) `
                -Test {
                    param($a)
                    $address = [string]$a.parameters.EmailAddresses.Add -replace '^smtp:', ''
                    $domain = Get-TcAddressDomain $address
                    if (-not (Test-TcTargetDomain $domain)) { return Test-TcPostponed $a ("{0} is not accepted in the target: run again after the domains are verified in the target" -f $domain) }
                    $m = Get-TargetMailbox $a.parameters.Identity
                    if (-not $m) { return Test-TcPostponed $a ("{0} does not exist in the target yet" -f $a.parameters.Identity) }
                    return @((Get-TcMember $m 'EmailAddresses') | Where-Object { ($_ -replace '^smtp:', '') -eq $address }).Count -gt 0
                } `
                -Undo @{ command = 'Set-Mailbox'; parameters = @{ Identity = $name; EmailAddresses = @{ Remove = $addition } } }
        }

        Add-TcManualAction -Tenant 'Target' -Object $name -Description ("Copy the calendar of {0} to {1}" -f $s['Address'], $name) `
            -Instruction @("Add the resource to the plan of the copy tool, then migrate its calendar.", "After the copy, check the bookings: they point to the old address.")
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($s in $Handled | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t }) {
        if (-not (Get-TargetMailbox (Get-TcMember $s 'Name'))) { New-TcRemediationResult Blocking ("{0} missing from the target" -f (Get-TcMember $s 'Name')); continue }
        $k = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-CalendarProcessing' -Parameters @{ Identity = (Get-TcMember $s 'Name') }
        if ((Get-TcText $k 'AutomateProcessing') -eq (Get-TcMember $s 'Handling') -and [int](Get-TcMember $k 'BookingWindowInDays') -eq [int](Get-TcMember $s 'Window') -and [int](Get-TcMember $k 'MaximumDurationInMinutes') -eq [int](Get-TcMember $s 'Duration')) { New-TcRemediationResult OK ("{0}: booking rules carried over, {1} delegate(s)" -f (Get-TcMember $s 'Name'), @((Get-TcMember $k 'ResourceDelegates')).Count) }
        else { New-TcRemediationResult Warning ("{0}: rules differ from the source" -f (Get-TcMember $s 'Name')) }
    }
}
Close-TcRemediation

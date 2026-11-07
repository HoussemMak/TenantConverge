# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Frames the transfer of numbers to the target: full export, port, assignment and removal (procedure TEL-NUMBERS).

.DESCRIPTION
    Before anything else, the -Apply run exports the whole number configuration of the source to <output>\telephony\<tenant>.
    Moving a number goes through no tenant-to-tenant API. Microsoft calling plan: Microsoft number service or port. Other types:
    provider. In both cases, at least 10 business days, on a weekday.
    The strategy is a decision (TEL-ROUTING-TARGET). Without it, only the export is planned.
      - decisions\TEL-NUMBERS.csv says which numbers leave.
      - A number is assigned as soon as it is present in the target according to the snapshot: run again after a new snapshot.
        Set-CsPhoneNumberAssignment turns on voice for the account. The emergency location is found by the address description (TEL-EMERGENCY).
      - decisions\TEL-NUMBERS-RELEASE.csv says which numbers to take off the source account, on the day Microsoft or the provider asks.
    Limits: filing the port and the call tests stay to be done by a person.
#>
$c = Open-TcRemediation

$TypeFile = 'TEL-ROUTING-TARGET'
$targetType = if (Test-TcDecisionFile $TypeFile) { @(Read-TcDecisionRow $TypeFile | ForEach-Object { (Get-TcMember $_ 'Decision') } | Where-Object { $_ }) | Select-Object -First 1 }

$targetAccounts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($u in Get-TcRemediationTable 'Target' 'teamsUsers') { [void]$targetAccounts.Add([string]$u['UPN']) }
$received = @{}
foreach ($n in Get-TcRemediationTable 'Target' 'phoneNumbers') { $received[[string]$n['Number']] = $n }

function Get-BusinessDate {
    <# Date after a number of business days. Holidays are not counted: review with the provider. #>
    param([datetime]$Departure, [int]$Days)
    $d = (Get-TcMember $Departure 'Date')
    while ($Days -gt 0) {
        $d = $d.AddDays(1)
        if ((Get-TcMember $d 'DayOfWeek') -notin 'Saturday', 'Sunday') { $Days-- }
    }
    return $d
}

function Get-TargetAccount {
    <# Target account of a matrix row. A resource account can hold a temporary UPN. #>
    param($Row)
    if (-not $Row) { return '' }
    foreach ($u in (Get-TcMember $Row 'Target UPN'), (Get-TcMember $Row 'Temporary UPN')) { if ($u -and $targetAccounts.Contains([string]$u)) { return [string]$u } }
    if (Get-TcRemediationTable 'Target' 'resourceAccounts' | Where-Object { $_['UPN'] -eq (Get-TcMember $Row 'Temporary UPN') }) { return (Get-TcText $Row 'Temporary UPN') }
    return ''
}

$matrices = @{}
$proposals = foreach ($t in $c.Tenants) {
    $matrix = @{}
    foreach ($l in @((Get-TcMember (Get-TcRemediationIdentity $t) 'rows'))) { $matrix[((Get-TcText $l 'Source UPN')).ToLowerInvariant()] = $l }
    $matrices[$t] = $matrix
    foreach ($n in Get-TcRemediationTable $t 'phoneNumbers') {
        $source = [string]$n['Assigned to']
        [ordered]@{ Tenant = $t; 'Number' = $n['Number']; Type = $n['Type']; Assignment = $n['Assignment']; 'Source account' = $source; 'Target account' = (Get-TargetAccount $matrix[$source.ToLowerInvariant()])
                    Proposal = $(if ($source) { 'Transfer' } else { '' }) }
    }
}
$decisions = @(Get-TcDecision -Name 'TEL-NUMBERS' -Proposal @($proposals) -Key 'Tenant', 'Number' -Choice 'Transfer', 'Drop')

$removalProposals = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Transfer' -and (Get-TcMember $_ 'Source account') } | ForEach-Object { [ordered]@{ Tenant = (Get-TcMember $_ 'Tenant'); 'Number' = (Get-TcMember $_ 'Number'); Type = (Get-TcMember $_ 'Type'); 'Source account' = (Get-TcMember $_ 'Source account'); Proposal = '' } })
$removals = @()
if ($removalProposals.Count) { $removals = @(Get-TcDecision -Name 'TEL-NUMBERS-RELEASE' -Proposal $removalProposals -Key 'Tenant', 'Number' -Choice 'Remove', 'Wait' | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Remove' }) }

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $numbers = @(Get-TcRemediationTable $t 'phoneNumbers')
    $types = @($numbers | Group-Object { $_['Type'] } | ForEach-Object { '{0}: {1}' -f (Get-TcMember $_ 'Name'), (Get-TcCount $_) })
    Write-TcRemediationNote ("{0} number(s) ({1}), {2} assigned" -f $numbers.Count, ($types -join ', '), @($numbers | Where-Object { $_['Assigned to'] }).Count)
    if (-not $numbers.Count) { continue }

    $exportFolder = Join-Path (Get-TcRemediationOutput) "telephony\$t"
    Add-TcBlockAction -Tenant $t -Service Teams -Object 'Configuration export' -Description "Export the numbers, assignments and emergency locations of $t" -Critical -Data @{ Folder = $exportFolder } `
        -Reason 'Reads the source: nothing to undo, the export is the reference if a port must be redone.' `
        -Test { param($a) $f = Join-Path $a.data.Folder ("numbers-{0:yyyyMMdd}.json" -f (Get-TcRemediationNow)); return (Test-Path -LiteralPath $f) } `
        -Block {
            param($a)
            New-Item -ItemType Directory -Force -Path $a.data.Folder | Out-Null
            $l = [System.Collections.Generic.List[object]]::new(); $skip = 0
            do {
                $batch = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsPhoneNumberAssignment' -Parameters @{ Top = 1000; Skip = $skip })
                foreach ($x in $batch) { $l.Add($x) }
                $skip += 1000
            } while ($batch.Count -eq 1000)
            $complete = [ordered]@{ numbers = @($l); addresses = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsOnlineLisCivicAddress'); places = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsOnlineLisLocation')
                               voiceAccounts = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsOnlineUser' -Parameters @{ Filter = 'EnterpriseVoiceEnabled -eq $true' } | Select-Object UserPrincipalName, LineUri, EnterpriseVoiceEnabled, TenantDialPlan, OnlineVoiceRoutingPolicy, TeamsCallingPolicy) }
            $complete | ConvertTo-Json -Depth 8 -WarningAction SilentlyContinue | Set-Content -LiteralPath (Join-Path $a.data.Folder ("numbers-{0:yyyyMMdd}.json" -f (Get-TcRemediationNow))) -Encoding utf8
        }

    if (-not $targetType) { Write-TcRemediationAlert 'Provider not decided (TEL-ROUTING-TARGET): porting not planned.'; continue }

    $leaving = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Transfer' })
    $pending = @($leaving | Where-Object { -not $received[(Get-TcText $_ 'Number')] })
    Write-TcRemediationNote ("Chosen type: {0}; {1} number(s) to transfer, {2} already received in the target" -f $targetType, $leaving.Count, ($leaving.Count - $pending.Count))
    if ($pending.Count) {
        $earliest = Get-BusinessDate -Departure (Get-TcRemediationNow) -Days 10
        $path2 = if ($targetType -eq 'CallingPlan') { 'Request to the Microsoft phone number service, or port, to the target tenant.' } else { 'Port with the provider of the target, from the Teams admin center or at the provider.' }
        Add-TcManualAction -Tenant 'Target' -Object 'Number porting' -Description ("File the transfer of {0} number(s), no earlier than {1:yyyy-MM-dd}" -f $pending.Count, $earliest) -Who 'Provider' `
            -Instruction @($path2, ("Choose a weekday, no earlier than {0:yyyy-MM-dd}: at least 10 business days after filing." -f $earliest), 'Gather the letter of authorization and the account details of the current provider: a wrong name or address gets the port refused.', 'In Canada, the current provider answers within 5 to 7 business days.', 'Confirm with the provider the effect of a partial port on the numbers that stay.')
    }

    foreach ($d in $leaving) {
        $numberValue = (Get-TcText $d 'Number')
        $receivedOne = $received[$numberValue]
        if (-not $receivedOne -or -not (Get-TcMember $d 'Source account')) { continue }
        $target = Get-TargetAccount $matrices[$t][((Get-TcText $d 'Source account')).ToLowerInvariant()]
        if (-not $target) { Write-TcRemediationAlert ("{0} received, but the account of {1} does not exist in the target yet" -f $numberValue, (Get-TcMember $d 'Source account')); continue }
        Add-TcBlockAction -Tenant 'Target' -Service Teams -Object $numberValue -Description ("Assign {0} to {1}" -f $numberValue, $target) -Data @{ Source = $t; Number = $numberValue; Target = $target; Type = [string]$receivedOne['Type'] } `
            -Test {
                param($a)
                $x = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsPhoneNumberAssignment' -Parameters @{ TelephoneNumber = $a.data.Number }) | Select-Object -First 1
                if (-not $x) { throw "$($a.data.Number) missing from the target: the snapshot is out of date." }
                return [bool](Get-TcMember $x 'AssignedPstnTargetId')
            } `
            -Block {
                param($a)
                $d = $a.data
                $p = @{ Identity = (Get-TcMember $d 'Target'); TelephoneNumber = (Get-TcMember $d 'Number'); NumberType = (Get-TcMember $d 'Type') }
                $s = @(Invoke-TcServiceCommand -Tenant (Get-TcMember $d 'Source') -Service Teams -Command 'Get-CsPhoneNumberAssignment' -Parameters @{ TelephoneNumber = (Get-TcMember $d 'Number') }) | Select-Object -First 1
                if ($s -and (Get-TcMember $s 'CivicAddressId')) {
                    $sourceAddress = @(Invoke-TcServiceCommand -Tenant (Get-TcMember $d 'Source') -Service Teams -Command 'Get-CsOnlineLisCivicAddress' -Parameters @{ CivicAddressId = [guid](Get-TcMember $s 'CivicAddressId') }) | Select-Object -First 1
                    $sourcePlace = if ((Get-TcMember $s 'LocationId')) { (Get-TcText (@(Invoke-TcServiceCommand -Tenant (Get-TcMember $d 'Source') -Service Teams -Command 'Get-CsOnlineLisLocation' -Parameters @{ LocationId = [guid](Get-TcMember $s 'LocationId') }) | Select-Object -First 1) 'Location') }
                    $address = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsOnlineLisCivicAddress' | Where-Object { (Get-TcMember $_ 'Description') -eq (Get-TcMember $sourceAddress 'Description') }) | Select-Object -First 1
                    if (-not $address) { throw "Emergency address $((Get-TcMember $sourceAddress 'Description')) missing from the target: run TEL-EMERGENCY." }
                    $places = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsOnlineLisLocation' -Parameters @{ CivicAddressId = [guid](Get-TcMember $address 'CivicAddressId') })
                    $place = @($places | Where-Object { (Get-TcText $_ 'Location') -eq $sourcePlace }) | Select-Object -First 1
                    if (-not $place) { $place = $places | Select-Object -First 1 }
                    if ($place) { $p.LocationId = (Get-TcText $place 'LocationId') }
                }
                Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Set-CsPhoneNumberAssignment' -Parameters $p | Out-Null
                $a.undo = @{ command = 'Remove-CsPhoneNumberAssignment'; parameters = @{ Identity = (Get-TcMember $d 'Target'); TelephoneNumber = (Get-TcMember $d 'Number'); NumberType = (Get-TcMember $d 'Type') } }
            }
    }

    foreach ($r in $removals | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t }) {
        Add-TcCommandAction -Tenant $t -Service Teams -Command 'Remove-CsPhoneNumberAssignment' -Parameters @{ Identity = (Get-TcMember $r 'Source account'); TelephoneNumber = (Get-TcMember $r 'Number'); NumberType = (Get-TcMember $r 'Type') } -Object (Get-TcMember $r 'Number') `
            -Description ("Remove {0} from the account {1}" -f (Get-TcMember $r 'Number'), (Get-TcMember $r 'Source account')) `
            -Test {
                param($a)
                $x = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsPhoneNumberAssignment' -Parameters @{ TelephoneNumber = $a.parameters.TelephoneNumber }) | Select-Object -First 1
                if (-not $x -or -not (Get-TcMember $x 'AssignedPstnTargetId')) { return $true }
                $p = @{ Identity = $a.parameters.Identity; TelephoneNumber = $a.parameters.TelephoneNumber; NumberType = $a.parameters.NumberType }
                if ((Get-TcMember $x 'LocationId')) { $p.LocationId = (Get-TcText $x 'LocationId') }
                $a.undo = @{ command = 'Set-CsPhoneNumberAssignment'; parameters = $p }
                return $false
            }
    }

    Add-TcManualAction -Tenant 'Target' -Object 'Call tests' -Description 'Test each pilot account and each auto attendant after the transfer' `
        -Instruction @('Make one inbound and one outbound call per pilot account, then call each auto attendant.', 'The number transfer is not aligned with the mail cutover: plan it separately.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $expectedItems = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Transfer' -and (Get-TcMember $_ 'Source account') })
    if (-not $expectedItems.Count) { return }
    $l = [System.Collections.Generic.List[object]]::new(); $skip = 0
    do {
        $batch = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command 'Get-CsPhoneNumberAssignment' -Parameters @{ Top = 1000; Skip = $skip })
        foreach ($x in $batch) { $l.Add($x) }
        $skip += 1000
    } while ($batch.Count -eq 1000)
    $assignedItems = @($expectedItems | Where-Object { $n = (Get-TcMember $_ 'Number'); @($l | Where-Object { (Get-TcMember $_ 'TelephoneNumber') -eq $n -and (Get-TcMember $_ 'AssignedPstnTargetId') }).Count }).Count
    if ($assignedItems -eq $expectedItems.Count) { New-TcRemediationResult OK ("{0} number(s) assigned in the target" -f $assignedItems) } else { New-TcRemediationResult Warning ("{0} number(s) out of {1} assigned in the target" -f $assignedItems, $expectedItems.Count) }
}
Close-TcRemediation

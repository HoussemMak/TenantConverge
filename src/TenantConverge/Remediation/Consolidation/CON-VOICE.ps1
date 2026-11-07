# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Draws up the single telephony plan, all sources together, from the snapshot (procedure CON-VOICE).

.DESCRIPTION
    No connection: the script reads the snapshot and the identity matrix, then produces four reports for the workshop with the customer:
    numbers, voice users, auto attendants and queues, licenses.
    A resource account shows as a voice account in the snapshot: the script separates them (VoiceApp function), otherwise the need for
    Teams Phone licenses would be overstated.
    Order to follow next: emergency addresses, resource accounts, auto attendants and queues, then numbers.
    The Porting moment column stays to fill with the customer; the target provider comes from the decision TEL-ROUTING-TARGET.
    Limit: approving the plan and the rollback of each port belong to the customer.
#>
$c = Open-TcRemediation

$TypeFile = 'TEL-ROUTING-TARGET'
$targetType = if (Test-TcDecisionFile $TypeFile) { @(Read-TcDecisionRow $TypeFile | ForEach-Object { (Get-TcMember $_ 'Decision') } | Where-Object { $_ }) | Select-Object -First 1 }

$targetAccounts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($u in Get-TcRemediationTable 'Target' 'teamsUsers') { [void]$targetAccounts.Add([string]$u['UPN']) }

function Get-TargetAccount {
    <# Target account of a matrix row: the final UPN, otherwise the temporary one, otherwise nothing while it does not exist. #>
    param($Row)
    foreach ($u in (Get-TcMember $Row 'Target UPN'), (Get-TcMember $Row 'Temporary UPN')) { if ($u -and $targetAccounts.Contains([string]$u)) { return [string]$u } }
    return ''
}

$theNumbers = [System.Collections.Generic.List[object]]::new()
$theUsers = [System.Collections.Generic.List[object]]::new()
$theApplications = [System.Collections.Generic.List[object]]::new()
$peopleTotal = 0; $resourceTotal = 0

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    if ($t -eq 'Target') {
        $types = @(Get-TcRemediationTable $t 'phoneNumbers' | Group-Object { $_['Type'] } | ForEach-Object { '{0}: {1}' -f (Get-TcMember $_ 'Name'), (Get-TcCount $_) })
        Write-TcRemediationNote ("Target: {0} number(s) ({1}), {2} voice route(s)" -f @(Get-TcRemediationTable $t 'phoneNumbers').Count, ($types -join ', '), @(Get-TcRemediationTable $t 'voiceRoutes').Count)
        continue
    }
    $matrix = @{}
    foreach ($l in @((Get-TcMember (Get-TcRemediationIdentity $t) 'rows'))) { $matrix[((Get-TcText $l 'Source UPN')).ToLowerInvariant()] = $l }
    $voice = @(Get-TcRemediationTable $t 'teamsUsers' | Where-Object { ConvertTo-TcBoolean $_['Enterprise Voice'] })
    $people = @($voice | Where-Object { $_['Features'] -notmatch 'VoiceApp' })
    $resources = @(Get-TcRemediationTable $t 'resourceAccounts')
    $numbers = @(Get-TcRemediationTable $t 'phoneNumbers')
    $peopleTotal += $people.Count; $resourceTotal += $resources.Count
    Write-TcRemediationNote ("{0} voice account(s): {1} user(s) and {2} resource account(s); {3} number(s)" -f $voice.Count, $people.Count, ($voice.Count - $people.Count), $numbers.Count)

    foreach ($n in $numbers) {
        $source = [string]$n['Assigned to']
        $l = $matrix[$source.ToLowerInvariant()]
        $theNumbers.Add([ordered]@{ Tenant = $t; 'Number' = $n['Number']; Type = $n['Type']; Assignment = $n['Assignment']; 'Source account' = $source
                                  'Target account' = $(if ($l) { Get-TargetAccount $l }); 'Target type' = $targetType; 'Porting moment' = '' })
    }
    foreach ($u in $people) {
        $l = $matrix[([string]$u['UPN']).ToLowerInvariant()]
        $theUsers.Add([ordered]@{ Tenant = $t; 'Source account' = $u['UPN']; Name = $u['Name']; 'Number' = $u['Number']; 'Matrix decision' = $(if ($l) { (Get-TcMember $l 'Decision') }); 'Target account' = $(if ($l) { Get-TargetAccount $l }) })
    }
    foreach ($s in Get-TcRemediationTable $t 'autoAttendants') { $theApplications.Add([ordered]@{ Tenant = $t; Type = 'Auto attendant'; Name = $s['Name']; 'Resource accounts' = $s['Resource accounts']; 'Detail' = ('{0} flow(s), {1} schedule(s), {2}' -f $s["Call flows"], $s['Schedules'], $s['Time zone']) }) }
    foreach ($q in Get-TcRemediationTable $t 'callQueues') { $theApplications.Add([ordered]@{ Tenant = $t; Type = "Call queue"; Name = $q['Name']; 'Resource accounts' = $q['Resource accounts']; 'Detail' = ('{0}, {1} agent(s), {2} list(s)' -f $q['Routing'], $q['Agents'], $q['Lists']) }) }

    $freeOnes = @($numbers | Where-Object { -not $_['Assigned to'] }).Count
    if ($freeOnes) { Write-TcRemediationAlert ("{0} number(s) with no assignment: to keep or to drop with the customer" -f $freeOnes) }
    $missing = @($people | Where-Object { -not $matrix[([string]$_['UPN']).ToLowerInvariant()] }).Count
    if ($missing) { Write-TcRemediationAlert ("{0} voice user(s) missing from the matrix" -f $missing) }
}

$licenses = @(foreach ($sku in 'MCOEV', 'PHONESYSTEM_VIRTUALUSER') {
    $l = Get-TcRemediationTable 'Target' 'licenses' | Where-Object { $_['SKU'] -eq $sku } | Select-Object -First 1
    $available = if ($l) { [int]$l['Available'] } else { 0 }
    $need = if ($sku -eq 'MCOEV') { $peopleTotal } else { $resourceTotal }
    [ordered]@{ License = $sku; Need = $need; 'Available in target' = $available; 'To order' = [math]::Max(0, $need - $available) }
})
foreach ($l in $licenses) { if ((Get-TcMember $l 'To order')) { Write-TcRemediationAlert ("{0}: {1} required, {2} available in the target" -f (Get-TcMember $l 'License'), (Get-TcMember $l 'Need'), (Get-TcMember $l 'Available in target')) } }
if (-not $targetType) { Write-TcRemediationAlert 'Provider of the numbers not decided: run TEL-ROUTING-TARGET. The number of calling plans stays unknown.' }

Close-TcRemediationBlock
Export-TcRemediationReport -Name 'phone-plan-numbers' -Rows @($theNumbers) | Out-Null
Export-TcRemediationReport -Name 'phone-plan-users' -Rows @($theUsers) | Out-Null
Export-TcRemediationReport -Name 'phone-plan-applications' -Rows @($theApplications) | Out-Null
Export-TcRemediationReport -Name 'phone-plan-licenses' -Rows @($licenses) | Out-Null

Invoke-TcRemediationPlan
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Resets the devices by batches, from the Intune of the source, and follows their return through Autopilot (task CUT-02).

.DESCRIPTION
    A wipe has no undo. Two decisions guard it:
      - decisions\DEVICE-BATCHES.csv puts each device in a batch;
      - decisions\DEVICE-BATCHES-ALLOWED.csv allows each batch, with the customer.
    A device is wiped only if it is marked in an allowed batch. A batch other than Pilot is planned only if the pilot is allowed.
    A batch starts only after the return of the allowed batch before it: the plan stops at the check, and a rerun resumes when the devices
    are back. A device is back if it is alone under its serial number in the Intune of the target, compliant and synced within three days.
    A device of the pilot must also have received its wipe from this script. All the decided devices are checked, even those that left
    the snapshot.
    Candidates are Windows devices of the Intune of the source registered in Autopilot, in the source or the target: INT-AUTOPILOT moves them there.
    Guards just before the wipe, read device by device on the tenant. At the slightest doubt, the device is skipped and reported, never wiped:
      - the device must be alone under its serial number, on Windows, still managed by the Intune of the source;
      - its name and account must be those of the decision, and this account must not be protected;
      - it must be registered in the Autopilot of the target, once, with its profile (INT-AUTOPILOT);
      - no wipe is already running or done, which makes a rerun safe.
    A protected device (emergency, kept or migration team account) and Macs stay out of the batches (INT-CONNECTORS for Macs).
    An Autopilot device with no Intune device gets no remote wipe: it is reset on site.
    Running the script again follows the return: the check and the device-return report say where each device stands. Once the device is
    back, its old record in the source goes away with the tenant.
#>
$c = Open-TcRemediation

$BatchSize = 10
$Threshold = [int](Get-TcRemediationOption 'StaleDeviceDays')
$Pilot = 'Pilot'
$DeviceUri = 'v1.0/deviceManagement/managedDevices'
$DeviceFile = 'DEVICE-BATCHES'
$DeviceKeys = @('Tenant', 'Serial number')
$WipeStates = @('pending', 'active', 'done')
$ReturnSyncDays = 3

function Find-TenantDevice {
    <# All the Intune devices of a serial number on a tenant, read at each call: the device changes state during the wave. An empty serial number points to no device. #>
    param([string]$Tenant, [string]$Serial)
    if (-not $Serial.Trim()) { return @() }
    return @(Invoke-TcGraph -Tenant $Tenant -Uri "$DeviceUri`?`$select=id,deviceName,serialNumber,lastSyncDateTime,complianceState,userPrincipalName,operatingSystem" -All | Where-Object { ((Get-TcText $_ 'serialNumber')).Trim() -eq $Serial })
}

function Find-TargetIdentity {
    <# Registrations in the Autopilot of the target; deploymentProfileAssignmentStatus exists only in beta. #>
    param([string]$Serial)
    return @(Invoke-TcGraph -Tenant 'Target' -Uri 'beta/deviceManagement/windowsAutopilotDeviceIdentities' -All | Where-Object { ((Get-TcText $_ 'serialNumber')).Trim() -eq $Serial })
}

function Get-WipeState {
    <# State of the last wipe command; empty if none was started. #>
    param([string]$Tenant, [string]$Id)
    $d = Invoke-TcGraph -Tenant $Tenant -Uri "$DeviceUri/$Id"
    return (Get-TcText (@((Get-TcMember $d 'deviceActionResults') | Where-Object { (Get-TcMember $_ 'actionName') -match 'wipe' }) | Sort-Object { [datetime](Get-TcMember $_ 'lastUpdatedDateTime') } | Select-Object -Last 1) 'actionState')
}

function Get-WipeRefusalReason {
    <# Reason not to wipe; empty only if the device read and the decided row point to the same device beyond doubt. #>
    param([object[]]$Devices, [string]$Tenant, [string]$Device, [string]$User)
    $l = @($Devices | Where-Object { $_ })
    if (-not $l.Count) { return "no longer managed by the Intune of ${Tenant}: reset on site" }
    if ($l.Count -gt 1) { return "$($l.Count) devices carry this serial number" }
    $x = $l[0]
    if ((Get-TcText $x 'operatingSystem') -ne 'Windows') { return "system $((Get-TcMember $x 'operatingSystem')): only a Windows device comes back through Autopilot" }
    if (-not $Device -or (Get-TcText $x 'deviceName') -ne $Device) { return "name $((Get-TcMember $x 'deviceName')) differs from the decision ($Device)" }
    $account = (Get-TcText $x 'userPrincipalName')
    if (-not $account) { return "no account on the device: the account cannot be checked" }
    if ($account -ne $User) { return "account $account differs from the decision ($User)" }
    if (Test-TcProtectedAccount $account (Get-TcRemediationTenant $Tenant)) { return "protected account $account" }
    return ''
}

function Get-AutopilotReason {
    <# Reason not to wipe on the target side; empty if the device is registered once, with its profile. #>
    param([string]$Serial)
    $l = @(Find-TargetIdentity -Serial $Serial)
    if (-not $l.Count) { return "missing from the Autopilot of the target: run INT-AUTOPILOT before wiping" }
    if ($l.Count -gt 1) { return "$($l.Count) registrations in the Autopilot of the target" }
    if ((Get-TcMember $l[0] 'deploymentProfileAssignmentStatus') -notlike 'assigned*') { return "no Autopilot profile in the target: state $((Get-TcMember $l[0] 'deploymentProfileAssignmentStatus'))" }
    return ''
}

function Get-NotBackReason {
    <# Reason not to call the device back; empty if it is alone under its serial number in the target, compliant and recently synced. #>
    param([string]$Tenant, [string]$Serial, [switch]$WipeRequired)
    $l = @(Find-TenantDevice -Tenant 'Target' -Serial $Serial)
    if ($l.Count -ne 1) { return "$($l.Count) device(s) under this serial number in the Intune of the target" }
    if ((Get-TcMember $l[0] 'complianceState') -ne 'compliant') { return "compliance state $((Get-TcMember $l[0] 'complianceState'))" }
    $sync = (Get-TcMember $l[0] 'lastSyncDateTime')
    if (-not $sync -or (Get-TcMember ((Get-TcRemediationNow).ToUniversalTime() - ([datetime]$sync).ToUniversalTime()) 'TotalDays') -gt $ReturnSyncDays) { return "no sync for $ReturnSyncDays days" }
    if ($WipeRequired) {
        $s = @(Find-TenantDevice -Tenant $Tenant -Serial $Serial)
        if ((Get-TcCount $s) -eq 1 -and (Get-WipeState -Tenant $Tenant -Id (Get-TcMember $s[0] 'id')) -notin $WipeStates) { return 'came back without a wipe by this script: the pilot must prove this path, choose another device' }
    }
    return ''
}

function Add-ReturnCheck {
    <# Stop point between two batches: while a device of the earlier batch is not back, the next one does not start. #>
    param([string]$Batch, [object[]]$Rows)
    Add-TcBlockAction -Tenant $sources[0] -Service Graph -Object "Return of batch $Batch" -Description ("Check the return of batch {0} in the target before the next batch" -f $Batch) -Critical -Reason 'Read only.' `
        -Data @{ Batch = $Batch; Computers = @($Rows | ForEach-Object { @{ Tenant = (Get-TcText $_ 'Tenant'); Serial = ((Get-TcText $_ 'Serial number')).Trim() } }) } `
        -Block {
            param($a)
            $reasons = @(foreach ($p in $a.data.Computers) {
                $m = Get-NotBackReason -Tenant (Get-TcMember $p 'Tenant') -Serial (Get-TcMember $p 'Serial') -WipeRequired:($a.data.Batch -eq $Pilot)
                if ($m) { '{0}: {1}' -f (Get-TcMember $p 'Serial'), $m }
            })
            if ($reasons.Count) { throw ("Batch {0} not back yet, the next batch does not start. {1}" -f $a.data.Batch, ($reasons -join ' ; ')) }
        }
}

$deviceProposals = [System.Collections.Generic.List[object]]::new()
$sources = @($c.Tenants)
foreach ($t in $sources) {
    Write-TcRemediationTenant $t
    $info = Get-TcRemediationTenant $t
    $autopilotSource = @{}
    foreach ($p in Get-TcRemediationTable $t 'autopilotDevices') { $autopilotSource[([string]$p['Serial number']).Trim()] = $p }
    # INT-AUTOPILOT takes the device off the Autopilot of the source: a recent snapshot shows it only in the target
    $autopilot = @{}
    foreach ($k in $autopilotSource.Keys) { $autopilot[$k] = 1 }
    foreach ($p in Get-TcRemediationTable 'Target' 'autopilotDevices') { $autopilot[([string]$p['Serial number']).Trim()] = 1 }
    $devices = @(Get-TcRemediationTable $t 'managedDevices')
    $windows = @($devices | Where-Object { $_['OS'] -eq 'Windows' -and ([string]$_['Serial number']).Trim() -and $autopilot.Contains(([string]$_['Serial number']).Trim()) })
    $protected = @($windows | Where-Object { Test-TcProtectedAccount ([string]$_['User']) $info })
    $inactive = @($windows | Where-Object { [int]$_['Days inactive'] -ge $Threshold })
    $candidates = @($windows | Where-Object { $_ -notin $protected -and $_ -notin $inactive })
    $managedSerials = @($windows | ForEach-Object { ([string]$_['Serial number']).Trim() })
    $noIntune = @($autopilotSource.Keys | Where-Object { $_ -notin $managedSerials }).Count
    Write-TcRemediationNote ("{0} Windows device(s) managed and in Autopilot: {1} candidate(s), {2} inactive, {3} of a protected account" -f $windows.Count, $candidates.Count, $inactive.Count, $protected.Count)
    Write-TcRemediationNote ("{0} Autopilot device(s) with no Intune device: no remote wipe, reset on site" -f $noIntune)
    $outsideAutopilot = @($devices | Where-Object { $_['OS'] -eq 'Windows' -and [int]$_['Days inactive'] -lt $Threshold -and -not $autopilot.Contains(([string]$_['Serial number']).Trim()) })
    if ($outsideAutopilot.Count) { Write-TcRemediationAlert ("{0} active Windows device(s) outside Autopilot: they would not come back through Autopilot and stay out of the batches" -f $outsideAutopilot.Count) }
    $n = 0
    foreach ($a in $candidates) {
        $batch = if ($n -eq 0) { $Pilot } else { 'Lot-{0:D2}' -f ([int][math]::Floor(($n - 1) / $BatchSize) + 1) }
        $n++
        $deviceProposals.Add([ordered]@{ Tenant = $t; 'Serial number' = ([string]$a['Serial number']).Trim(); Device = $a['Name']; 'Model' = $a['Model']; User = $a['User']; 'Days inactive' = $a['Days inactive']; Proposal = $batch })
    }
}
# a wiped device leaves the snapshot, not the batches: their number and list also come from the file
$deviceCount = [math]::Max($deviceProposals.Count, @((Read-TcDecisionEntry -Name $DeviceFile -Key $DeviceKeys).Keys).Count)
$batchCount = [int][math]::Ceiling([math]::Max(0, $deviceCount - 1) / $BatchSize) + 1
$batches = @($Pilot) + @(1..$batchCount | ForEach-Object { 'Lot-{0:D2}' -f $_ })
$computers = @(Get-TcDecision -Name $DeviceFile -Proposal @($deviceProposals) -Key $DeviceKeys -Choice (@($batches) + 'Exclude'))
$placed = @($computers | Where-Object { (Get-TcMember $_ 'Decision') -ne 'Exclude' })
$rows = @((Read-TcDecisionEntry -Name $DeviceFile -Key $DeviceKeys).Values | Where-Object { (Get-TcMember $_ 'Tenant') -in $sources -and (Get-TcText $_ 'Decision') -in $batches })

$batchProposals = @($rows | Group-Object 'Decision' | Sort-Object Name | ForEach-Object { [ordered]@{ Batch = (Get-TcMember $_ 'Name'); Computers = (Get-TcCount $_); Proposal = '' } })
$allowed = @()
if ($batchProposals.Count) { $allowed = @(Get-TcDecision -Name 'DEVICE-BATCHES-ALLOWED' -Proposal $batchProposals -Key 'Batch' -Choice 'Allow', 'Postpone' | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Allow' } | ForEach-Object { (Get-TcMember $_ 'Batch') }) }

$runningBatches = @($allowed | Where-Object { $_ -ne $Pilot })
if ($runningBatches.Count -and $Pilot -notin $allowed) { Write-TcRemediationAlert 'The pilot is not allowed: the other batches are not planned.'; $runningBatches = @() }
$chosenRows = @(@($allowed | Where-Object { $_ -eq $Pilot }) + $runningBatches)

for ($i = 0; $i -lt $chosenRows.Count; $i++) {
    $batch = $chosenRows[$i]
    if ($i -gt 0) { Add-ReturnCheck -Batch $chosenRows[$i - 1] -Rows @($rows | Where-Object { (Get-TcMember $_ 'Decision') -eq $chosenRows[$i - 1] }) }
    foreach ($p in $placed | Where-Object { (Get-TcMember $_ 'Decision') -eq $batch -and (Get-TcMember $_ 'Tenant') -in $sources }) {
        $serial = ((Get-TcText $p 'Serial number')).Trim()
        if (-not $serial -or -not (Get-TcText $p 'Device') -or -not (Get-TcText $p 'User')) { Write-TcRemediationAlert ("{0}: incomplete row (serial number, device or account): never wiped" -f (Get-TcMember $p 'Device')); continue }
        if (Test-TcProtectedAccount ((Get-TcText $p 'User')) (Get-TcRemediationTenant (Get-TcMember $p 'Tenant'))) { Write-TcRemediationAlert ("{0}: device of a protected account, never wiped" -f $serial); continue }
        Add-TcBlockAction -Tenant (Get-TcMember $p 'Tenant') -Service Graph -Object $serial -Description ("Wipe {0} ({1}, {2})" -f (Get-TcMember $p 'Device'), $batch, (Get-TcMember $p 'User')) -Critical -Data @{ Serial = $serial; Batch = $batch; Device = (Get-TcText $p 'Device'); User = (Get-TcText $p 'User') } `
            -Reason 'A wipe cannot be undone: the device comes back through Autopilot, its local data is lost.' `
            -Test {
                param($a)
                $d = $a.data
                if (@(Find-TenantDevice -Tenant 'Target' -Serial (Get-TcMember $d 'Serial')).Count) { return $true }
                $l = @(Find-TenantDevice -Tenant $a.tenant -Serial (Get-TcMember $d 'Serial'))
                $reason = Get-WipeRefusalReason -Devices $l -Tenant $a.tenant -Device (Get-TcMember $d 'Device') -User (Get-TcMember $d 'User')
                if ($reason) { return (Test-TcPostponed $a ("{0}: {1}" -f (Get-TcMember $d 'Serial'), $reason)) }
                if ((Get-WipeState -Tenant $a.tenant -Id (Get-TcMember $l[0] 'id')) -in $WipeStates) { return $true }
                $reason = Get-AutopilotReason -Serial (Get-TcMember $d 'Serial')
                if ($reason) { return (Test-TcPostponed $a ("{0}: {1}" -f (Get-TcMember $d 'Serial'), $reason)) }
                $d.Id = (Get-TcMember $l[0] 'id')
                return $false
            } `
            -Block {
                param($a)
                if (-not $a.data.Id) { throw "$($a.data.Serial): device not verified, wipe refused." }
                Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri "$DeviceUri/$($a.data.Id)/wipe" -Body @{ keepEnrollmentData = $false; keepUserData = $false } | Out-Null
            }
    }
}
Write-TcRemediationNote ("{0} device(s) placed in a batch, {1} batch(es) allowed, {2} wipe(s) planned" -f $rows.Count, $allowed.Count, @($script:TcRemediationRun['Actions'] | Where-Object { (Get-TcMember $_ 'object') -notlike 'Batch return*' }).Count)

Invoke-TcRemediationPlan -Verify {
    param($t)
    $tracking = [System.Collections.Generic.List[object]]::new()
    $target = @(Invoke-TcGraph -Tenant 'Target' -Uri "$DeviceUri`?`$select=id,deviceName,serialNumber,lastSyncDateTime,complianceState" -All)
    $source = @(Invoke-TcGraph -Tenant $t -Uri "$DeviceUri`?`$select=id,deviceName,serialNumber" -All)
    foreach ($p in $rows | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -in $allowed }) {
        $serial = ((Get-TcText $p 'Serial number')).Trim()
        $r = $target | Where-Object { ((Get-TcText $_ 'serialNumber')).Trim() -eq $serial } | Select-Object -First 1
        $s = $source | Where-Object { ((Get-TcText $_ 'serialNumber')).Trim() -eq $serial } | Select-Object -First 1
        $state = if ($s) { Get-WipeState -Tenant $t -Id (Get-TcMember $s 'id') } else { 'outside Intune of the source' }
        $tracking.Add([ordered]@{ Batch = (Get-TcMember $p 'Decision'); 'Serial number' = $serial; 'Old name' = (Get-TcMember $p 'Device'); User = (Get-TcMember $p 'User'); 'Wipe' = $state; 'Back in target' = $(if ($r) { 'Yes' } else { 'No' }); 'New name' = $(if ($r) { (Get-TcMember $r 'deviceName') }); 'Compliance' = $(if ($r) { (Get-TcMember $r 'complianceState') }) })
    }
    if (-not $tracking.Count) { return }
    Export-TcRemediationReport -Name 'device-return' -Rows @($tracking) | Out-Null
    foreach ($g in $tracking | Group-Object { (Get-TcMember $_ 'Batch') }) {
        $returned = @((Get-TcMember $g 'Group') | Where-Object { (Get-TcMember $_ 'Back in target') -eq 'Yes' }).Count
        $names = @((Get-TcMember $g 'Group') | Where-Object { (Get-TcMember $_ 'New name') -and (Get-TcMember $_ 'New name') -notmatch '^WS-\d{4}$' }).Count
        if ($returned -eq (Get-TcCount $g)) { New-TcRemediationResult OK ("{0}: {1} device(s) returned" -f (Get-TcMember $g 'Name'), $returned) } else { New-TcRemediationResult Warning ("{0}: {1} device(s) back out of {2}" -f (Get-TcMember $g 'Name'), $returned, (Get-TcCount $g)) }
        if ($names) { New-TcRemediationResult Warning ("{0}: {1} device(s) outside the naming pattern" -f (Get-TcMember $g 'Name'), $names) }
    }
}
Close-TcRemediation

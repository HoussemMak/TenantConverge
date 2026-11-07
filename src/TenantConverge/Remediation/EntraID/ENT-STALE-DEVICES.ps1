# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Disables then deletes the stale devices of the target according to the customer decisions (procedure ENT-STALE-DEVICES).

.DESCRIPTION
    Target: decisions\ENT-STALE-DEVICES.csv, one row per device name, choices Disable, Delete or Keep.
    Always disable first: Delete aims at a device already disabled and is entered after the agreed grace period.
    Devices joined to on-premises AD (Hybrid) are not in this file: they would come back through sync, they go in a report for
    on-premises AD.

    Sources: nothing is cleaned, the objects go away with the tenant. The script produces the list to take off the devices to re-enroll.

    The snapshot does not carry the device identifier: it is read again by name on the tenant, and only objects still with no sign-in
    since the StaleDeviceDays setting are touched. A device that came back in the meantime is left in place.
    Guards before a deletion: the device must be disabled, an Autopilot device is refused, and its BitLocker keys are saved with DPAPI
    in secrets\ in the log folder.

    Limits: Graph can only disable Windows devices; the others are disabled in the portal.
#>
$c = Open-TcRemediation

$Threshold = [int](Get-TcRemediationOption 'StaleDeviceDays')

function Get-StaleObject {
    <# Objects of the tenant with this name, outside on-premises AD, still with no sign-in since the threshold. #>
    param([string]$Tenant, [string]$Name)
    $limit = (Get-TcRemediationNow).AddDays(-$Threshold)
    $fields = 'id,deviceId,displayName,accountEnabled,approximateLastSignInDateTime,trustType,physicalIds'
    $l = @(Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/devices?`$filter=displayName eq '{0}'&`$select={1}" -f [uri]::EscapeDataString($Name.Replace("'", "''")), $fields) -All)
    return @($l | Where-Object { (Get-TcMember $_ 'trustType') -ne 'ServerAd' -and (Get-TcMember $_ 'approximateLastSignInDateTime') -and [datetime](Get-TcMember $_ 'approximateLastSignInDateTime') -le $limit })
}

function Save-BitlockerKey {
    <# A key stored in Entra goes away with the device: DPAPI, readable by this Windows account only. #>
    param([string]$Tenant, $Device)
    $keys = @(Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/informationProtection/bitlocker/recoveryKeys?`$filter=deviceId eq '{0}'" -f (Get-TcMember $Device 'deviceId')) -All)
    if (-not $keys.Count) { return 0 }
    $d = Join-Path $script:TcRemediationRun['Folder'] 'secrets'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    @($keys | ForEach-Object {
        $k = Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/informationProtection/bitlocker/recoveryKeys/{0}?`$select=key" -f (Get-TcMember $_ 'id'))
        @{ id = (Get-TcMember $_ 'id'); key = (ConvertTo-TcSecret -Text (Get-TcText $k 'key')) }
    }) | Export-Clixml -LiteralPath (Join-Path $d ("bitlocker-{0}.xml" -f (Get-TcMember $Device 'deviceId')))
    return $keys.Count
}

$proposals = [System.Collections.Generic.List[object]]::new()
$hybrids = @()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Devices with no recent sign-in'
    $devices = @(Get-TcRemediationTable $t 'devices')
    if (-not $devices.Count -and -not (Test-TcCollectionComplete $t 'devices')) { Write-TcRemediationAlert "${t}: device collection incomplete"; continue }
    $stale = @($devices | Where-Object { "$($_['Days inactive'])" -ne '' -and [int]$_['Days inactive'] -ge $Threshold })
    Write-TcRemediationNote ("{0} device(s) with no sign-in for {1} days or more, out of {2}" -f $stale.Count, $Threshold, $devices.Count)
    if ($t -ne 'Target') {
        if ($stale.Count) { Export-TcRemediationReport -Name "devices-not-to-re-enroll-$t" -Rows @($stale | ForEach-Object { [ordered]@{ Tenant = $t; Device = $_['Name']; OS = $_['OS']; 'Join type' = $_['Join type']; 'Days inactive' = $_['Days inactive'] } }) | Out-Null }
        continue
    }
    $serials = @{}
    foreach ($g in Get-TcRemediationTable $t 'managedDevices') { $serials[[string]$g['Name']] = $g['Serial number'] }
    $autopilot = @(Get-TcRemediationTable $t 'autopilotDevices' | ForEach-Object { $_['Serial number'] })
    $hybrids = @($stale | Where-Object { $_['Join type'] -eq 'Hybrid' })
    $others = @($stale | Where-Object { $_['Join type'] -ne 'Hybrid' })
    Write-TcRemediationNote ("{0} joined to on-premises AD, to handle there; {1} to decide here, including {2} non-Windows" -f $hybrids.Count, $others.Count, @($others | Where-Object { $_['OS'] -ne 'Windows' }).Count)
    foreach ($g in $others | Group-Object { $_['Name'] }) {
        $x = (Get-TcMember $g 'Group') | Sort-Object { [int]$_['Days inactive'] } | Select-Object -First 1
        $underAutopilot = $serials[(Get-TcMember $g 'Name')] -and $serials[(Get-TcMember $g 'Name')] -in $autopilot
        $proposals.Add([ordered]@{ Device = (Get-TcMember $g 'Name'); OS = $x['OS']; 'Join type' = $x['Join type']; Objects = (Get-TcCount $g); 'Days inactive' = $x['Days inactive']; Active = $(if (ConvertTo-TcBoolean $x['Enabled']) { 'Yes' } else { 'No' })
                                      Autopilot = $(if ($underAutopilot) { 'Yes' } else { 'No' }); Proposal = $(if ($underAutopilot) { 'Keep' } else { 'Disable' }) })
    }
}

$decisions = @(Get-TcDecision -Name 'ENT-STALE-DEVICES' -Proposal @($proposals) -Key 'Device' -Choice 'Disable', 'Delete', 'Keep')

if ($hybrids.Count) {
    $f = Export-TcRemediationReport -Name 'stale-devices-on-premises' -Rows @($hybrids | ForEach-Object { [ordered]@{ Device = $_['Name']; OS = $_['OS']; 'Days inactive' = $_['Days inactive']; Active = $_['Enabled'] } })
    Add-TcManualAction -Tenant 'Target' -Object 'Devices joined to on-premises AD' -Description ("Handle {0} stale device(s) joined to on-premises AD" -f $hybrids.Count) `
        -Instruction @("List: $f", 'Disable or remove them in on-premises AD: deleted in Entra, they would come back through synchronization. Have the customer validate the list.')
}

$nonWindows = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Disable' -and (Get-TcMember $_ 'OS') -ne 'Windows' })
if ($nonWindows.Count) {
    $f = Export-TcRemediationReport -Name 'devices-to-disable-in-portal' -Rows $nonWindows
    Add-TcManualAction -Tenant 'Target' -Object 'Non-Windows devices' -Description ("Disable {0} non-Windows device(s) in the portal" -f $nonWindows.Count) `
        -Instruction @("List: $f", 'Microsoft Entra admin center > Entra ID > Devices: disable each device. Graph does not allow it for non-Windows devices.')
}

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Disable' -and (Get-TcMember $_ 'OS') -eq 'Windows' }) {
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Device') -Description ("Disable the stale device {0}" -f (Get-TcMember $d 'Device')) -Data @{ Name = (Get-TcMember $d 'Device') } `
        -Test { param($a) -not @(Get-StaleObject $a.tenant $a.data.Name | Where-Object { (Get-TcMember $_ 'accountEnabled') }).Count } `
        -Block {
            param($a)
            $a.undo = [System.Collections.Generic.List[object]]::new()
            foreach ($x in Get-StaleObject $a.tenant $a.data.Name | Where-Object { (Get-TcMember $_ 'accountEnabled') }) {
                Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri ("v1.0/devices/{0}" -f (Get-TcMember $x 'id')) -Body @{ accountEnabled = $false } | Out-Null
                $a.undo.Add(@{ type = 'Graph'; tenant = $a.tenant; method = 'PATCH'; uri = ("v1.0/devices/{0}" -f (Get-TcMember $x 'id')); body = @{ accountEnabled = $true } })
            }
        }
}

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Delete' }) {
    if ((Get-TcMember $d 'Autopilot') -eq 'Yes') { Write-TcRemediationAlert ("{0}: Autopilot device, to clean up in Intune, deletion ignored" -f (Get-TcMember $d 'Device')); continue }
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Device') -Description ("Delete the disabled device {0}" -f (Get-TcMember $d 'Device')) -Data @{ Name = (Get-TcMember $d 'Device') } `
        -Reason 'A deleted device cannot be restored: it must enroll again. BitLocker keys are backed up first.' `
        -Test { param($a) -not @(Get-StaleObject $a.tenant $a.data.Name).Count } `
        -Block {
            param($a)
            foreach ($x in Get-StaleObject $a.tenant $a.data.Name) {
                if ((Get-TcMember $x 'accountEnabled')) { throw "$((Get-TcMember $x 'displayName')) is still active: decide Disable first, then wait for the grace period." }
                if (@((Get-TcMember $x 'physicalIds')) -match '^\[ZTDID\]') { throw "$((Get-TcMember $x 'displayName')) is an Autopilot object: to clean up in Intune." }
                Save-BitlockerKey -Tenant $a.tenant -Device $x | Out-Null
                Invoke-TcGraph -Tenant $a.tenant -Method DELETE -Uri ("v1.0/devices/{0}" -f (Get-TcMember $x 'id'))
            }
        }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $limit = (Get-TcRemediationNow).AddDays(-$Threshold)
    $n = @(Invoke-TcGraph -Tenant $t -Uri "v1.0/devices?`$select=id,approximateLastSignInDateTime" -All | Where-Object { (Get-TcMember $_ 'approximateLastSignInDateTime') -and [datetime](Get-TcMember $_ 'approximateLastSignInDateTime') -le $limit }).Count
    New-TcRemediationResult Info ("{0} device(s) with no sign-in for {1} days or more" -f $n, $Threshold)
}
Close-TcRemediation

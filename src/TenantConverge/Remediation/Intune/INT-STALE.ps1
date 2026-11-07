# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Excludes stale devices from re-enrollment and removes from the Intune of the target those the customer confirms (procedure INT-STALE).

.DESCRIPTION
    A device with no sync for 90 days or more is not always retired: leave, repair. Each device therefore goes through a decision, in
    decisions\INT-STALE-<tenant>.csv, with no proposal. One file per tenant.
      - Source: the decision Remove takes the device off the list to re-enroll (INT-AUTOPILOT). The device goes away with the tenant.
      - Target: the decision Remove deletes the device from Intune, by its serial number.
    Guard: just before the deletion, the script reads the device again. If it synced since, or if the name and serial number point to
    several devices, nothing is deleted and the row shows as failed.
#>
$c = Open-TcRemediation

$Threshold = [int](Get-TcRemediationOption 'StaleDeviceDays')

function Get-TenantDevice {
    <# Intune devices of the tenant, read once: the list avoids relying on an undocumented filter on the name. #>
    param([string]$Tenant)
    if (-not $script:TcRemediationRun['CacheIntuneDevices']) { $script:TcRemediationRun['CacheIntuneDevices'] = @{} }
    if (-not $script:TcRemediationRun['CacheIntuneDevices'][$Tenant]) { $script:TcRemediationRun['CacheIntuneDevices'][$Tenant] = @(Invoke-TcGraph -Tenant $Tenant -Uri 'v1.0/deviceManagement/managedDevices?$select=id,deviceName,serialNumber,lastSyncDateTime' -All) }
    return $script:TcRemediationRun['CacheIntuneDevices'][$Tenant]
}

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $devices = @(Get-TcRemediationTable $t 'managedDevices')
    if (-not $devices.Count -and -not (Test-TcCollectionComplete $t 'managedDevices')) { Write-TcRemediationAlert 'Device collection incomplete: run Invoke-TcAssessment again.'; continue }
    $stale = @($devices | Where-Object { [int]$_['Days inactive'] -ge $Threshold })
    Write-TcRemediationNote ("{0} device(s) out of {1} with no sync for {2} days or more" -f $stale.Count, $devices.Count, $Threshold)
    $proposals = @($stale | ForEach-Object { [ordered]@{ Tenant = $t; Device = $_['Name']; 'Serial number' = ([string]$_['Serial number']).Trim(); OS = $_['OS']; User = $_['User']; 'Days inactive' = $_['Days inactive']; 'Last sync' = $_['Last sync']; Proposal = '' } })
    if (-not $proposals.Count) { continue }
    $decisions = @(Get-TcDecision -Name "INT-STALE-$t" -Proposal $proposals -Key 'Tenant', 'Device', 'Serial number' -Choice 'Remove', 'Keep')
    $removedItems = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Remove' })
    if ($t -ne 'Target') { Write-TcRemediationNote ("{0} device(s) taken off the list to re-enroll; in this source, they disappear with the tenant" -f $removedItems.Count); continue }

    foreach ($d in $removedItems) {
        Add-TcBlockAction -Tenant $t -Service Graph -Object (Get-TcMember $d 'Device') -Description ("Remove {0} from Intune" -f (Get-TcMember $d 'Device')) -Data @{ Device = (Get-TcMember $d 'Device'); Serial = (Get-TcMember $d 'Serial number'); Threshold = $Threshold } `
            -Reason 'A device deleted from Intune comes back only through a new enrollment on the device.' `
            -Test {
                param($a)
                $l = @(Get-TenantDevice -Tenant $a.tenant | Where-Object { (Get-TcMember $_ 'deviceName') -eq $a.data.Device -and ((Get-TcText $_ 'serialNumber')).Trim() -eq $a.data.Serial })
                if ($l.Count -gt 1) { throw "$($a.data.Device): $($l.Count) devices carry this name and serial number, nothing is deleted." }
                $a.data.Id = $(if ($l.Count) { (Get-TcMember $l[0] 'id') })
                $a.data.Sync = $(if ($l.Count) { [datetime](Get-TcMember $l[0] 'lastSyncDateTime') })
                return -not $l.Count
            } `
            -Block {
                param($a)
                $days = (Get-TcMember ((Get-TcRemediationNow) - $a.data.Sync) 'TotalDays')
                if ($days -lt $a.data.Threshold) { throw ("{0} synced {1:N0} day(s) ago: decision to review, nothing is deleted." -f $a.data.Device, $days) }
                Invoke-TcGraph -Tenant $a.tenant -Method DELETE -Uri "v1.0/deviceManagement/managedDevices/$($a.data.Id)" | Out-Null
            }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $limit = (Get-TcRemediationNow).AddDays(-$Threshold).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $n = @(Invoke-TcGraph -Tenant $t -Uri ("v1.0/deviceManagement/managedDevices?`$select=id&`$filter=lastSyncDateTime lt {0}" -f $limit) -All).Count
    New-TcRemediationResult Info ("{0} device(s) still with no sync for {1} days or more" -f $n, $Threshold)
}
Close-TcRemediation

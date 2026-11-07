# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Produces the test report of the two POC test devices (procedure POC-DEVICES).

.DESCRIPTION
    Decision: decisions\POC-DEVICES.csv. For each device, enter Chosen and its serial number in Note.
    The snapshot does not tell a test device from another.

    Report test-devices-<tenant>.csv: Intune and Autopilot state read in the source and in the target, plus the columns to fill by hand.
    In an -Apply run, the script also reads the two devices live, in the source and in the target: a reset device shows in the target well
    after the last snapshot.

    Windows Hello, endpoint protection, applications and OneDrive are not read through a safe API: they are checked on the device.
    The reset itself is done on the device, never by this script.
#>
$c = Open-TcRemediation

$proposals = foreach ($t in $c.Tenants) { foreach ($n in 1, 2) { [ordered]@{ Tenant = $t; Device = "Test device $n (serial number in Note)" } } }
$decisions = @(Get-TcDecision -Name 'POC-DEVICES' -Proposal @($proposals) -Key 'Tenant', 'Device' -Choice 'Chosen')

function Get-SerialList {
    param([string]$Tenant)
    return @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $Tenant -and ((Get-TcText $_ 'Note')).Trim() } | ForEach-Object { ((Get-TcText $_ 'Note')).Trim() })
}

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    Write-TcRemediationNote ("Fleet read: {0} managed device(s), {1} Autopilot device(s)" -f @(Get-TcRemediationTable $t 'managedDevices').Count, @(Get-TcRemediationTable $t 'autopilotDevices').Count)
    $serials = @(Get-SerialList $t)
    if (-not $serials.Count) { Write-TcRemediationNote 'No test device named.' }
    $rows = foreach ($s in $serials) {
        $g = Get-TcRemediationTable $t 'managedDevices' | Where-Object { $_['Serial number'] -eq $s } | Select-Object -First 1
        $a = Get-TcRemediationTable $t 'autopilotDevices' | Where-Object { $_['Serial number'] -eq $s } | Select-Object -First 1
        $b = Get-TcRemediationTable 'Target' 'autopilotDevices' | Where-Object { $_['Serial number'] -eq $s } | Select-Object -First 1
        if (-not $g -and -not $a) { Write-TcRemediationAlert "Device $s missing from the snapshot of the source: check the serial number." }
        [ordered]@{ Tenant = $t; 'Serial number' = $s; Name = $(if ($g) { $g['Name'] }); Model = $(if ($g) { $g['Model'] } elseif ($a) { $a['Model'] }); System = $(if ($g) { '{0} {1}' -f $g['OS'], $g['Version'] })
                    Compliance = $(if ($g) { $g['Compliance'] }); Encrypted = $(if ($g) { $g['Encrypted'] }); 'Last sync' = $(if ($g) { $g['Last sync'] }); 'Source Autopilot' = $(if ($a) { 'Yes' } else { 'No' }); 'Target Autopilot' = $(if ($b) { 'Yes' } else { 'No' })
                    'Reset (date, duration)' = ''; 'Windows Hello' = ''; 'Security agent' = ''; 'Critical applications' = ''; OneDrive = '' }
    }
    [void](Export-TcRemediationReport -Name "test-devices-$t" -Rows @($rows))
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($s in @(Get-SerialList $t)) {
        foreach ($x in @($t, 'Target')) {
            $m = @(Invoke-TcGraph -Tenant $x -Uri ("v1.0/deviceManagement/managedDevices?`$filter=serialNumber eq '{0}'&`$select=deviceName,complianceState,lastSyncDateTime" -f $s) -All)
            $a = @(Invoke-TcGraph -Tenant $x -Uri ("v1.0/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'{0}')" -f $s) -All)
            New-TcRemediationResult Info ("{0} in {1}: Intune {2}, Autopilot {3}" -f $s, $x, $(if ($m.Count) { '{0} ({1})' -f (Get-TcMember $m[0] 'deviceName'), (Get-TcMember $m[0] 'complianceState') } else { 'missing' }), $(if ($a.Count) { 'present' } else { 'missing' }))
        }
    }
}
Close-TcRemediation

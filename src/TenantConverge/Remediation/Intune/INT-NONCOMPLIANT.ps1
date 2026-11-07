# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Groups the noncompliant devices of the target and their causes (procedure INT-NONCOMPLIANT).

.DESCRIPTION
    Preview: report of the noncompliant devices from the snapshot, setting apart those that are inactive (procedure INT-STALE).
    -Apply run, read only: the script reads through Graph the settings at fault in the whole tenant, then, for each setting, the devices
    affected. It fixes nothing: the fix depends on each cause and on the device owner.
    The moment to enforce compliance stays to set with the customer.
#>
$c = Open-TcRemediation

$Threshold = [int](Get-TcRemediationOption 'StaleDeviceDays')

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $devices = @(Get-TcRemediationTable $t 'managedDevices')
    if (-not $devices.Count -and -not (Test-TcCollectionComplete $t 'managedDevices')) { Write-TcRemediationAlert 'Device collection incomplete: run Invoke-TcAssessment again.'; continue }
    $noncompliant = @($devices | Where-Object { $_['Compliance'] -eq 'noncompliant' })
    $inactive = @($noncompliant | Where-Object { [int]$_['Days inactive'] -ge $Threshold })
    $bySystem = @($noncompliant | Group-Object { $_['OS'] } | ForEach-Object { '{0}: {1}' -f (Get-TcMember $_ 'Name'), (Get-TcCount $_) })
    Write-TcRemediationNote ("{0} noncompliant device(s) out of {1} ({2}), {3} inactive to handle with INT-STALE" -f $noncompliant.Count, $devices.Count, ($bySystem -join ', '), $inactive.Count)
    Export-TcRemediationReport -Name "noncompliant-$t" -Rows @($noncompliant | ForEach-Object { [ordered]@{ Device = $_['Name']; OS = $_['OS']; Version = $_['Version']; User = $_['User']; 'Last sync' = $_['Last sync']; 'Days inactive' = $_['Days inactive']; 'Encrypted' = $_['Encrypted']; Inactive = $(if ([int]$_['Days inactive'] -ge $Threshold) { 'Yes' } else { 'No' }) } }) | Out-Null

    Add-TcBlockAction -Tenant $t -Service Graph -Object 'Noncompliance causes' -Description 'Read the settings at fault and the devices affected' -Reason 'Read only.' -Data @{ Tenant = $t } `
        -Block {
            param($a)
            $rootPath = 'v1.0/deviceManagement/deviceCompliancePolicySettingStateSummaries'
            $summaries = @(Invoke-TcGraph -Tenant $a.tenant -Uri $rootPath -All | Where-Object { [int](Get-TcMember $_ 'nonCompliantDeviceCount') + [int](Get-TcMember $_ 'errorDeviceCount') -gt 0 })
            Export-TcRemediationReport -Name "causes-by-setting-$($a.tenant)" -Rows @($summaries | Sort-Object { [int](Get-TcMember $_ 'nonCompliantDeviceCount') } -Descending | ForEach-Object { [ordered]@{ 'Setting' = (Get-TcMember $_ 'settingName'); Platform = (Get-TcMember $_ 'platformType'); 'Noncompliant' = (Get-TcMember $_ 'nonCompliantDeviceCount'); 'In error' = (Get-TcMember $_ 'errorDeviceCount'); Compliant = (Get-TcMember $_ 'compliantDeviceCount') } }) | Out-Null
            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($r in $summaries) {
                foreach ($s in @(Invoke-TcGraph -Tenant $a.tenant -Uri "$rootPath/$((Get-TcMember $r 'id'))/deviceComplianceSettingStates" -All | Where-Object { (Get-TcMember $_ 'state') -in 'nonCompliant', 'error' })) {
                    $rows.Add([ordered]@{ Device = (Get-TcMember $s 'deviceName'); User = (Get-TcMember $s 'userPrincipalName'); 'Setting' = (Get-TcMember $r 'settingName'); 'State' = (Get-TcMember $s 'state') })
                }
            }
            Export-TcRemediationReport -Name "causes-by-device-$($a.tenant)" -Rows @($rows) | Out-Null
        }
}

Invoke-TcRemediationPlan
Close-TcRemediation

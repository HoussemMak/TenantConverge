# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Lists the unmanaged devices whose profiles must be reconfigured (task DEV-06).

.DESCRIPTION
    No connection. The script lists, from the devices table of each source, the devices Intune does not manage.
      - registered device: a person reconfigures the profile, in the session of the user;
      - device joined to Entra ID with no Intune management: these devices go to a technician.
    Limit: reaching an unmanaged device stays to be done by a person. No tool reaches it.
#>
$c = Open-TcRemediation

$threshold = [int](Get-TcRemediationOption 'StaleDeviceDays')
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $devices = @(Get-TcRemediationTable $t 'devices')
    if (-not $devices.Count -and -not (Test-TcCollectionComplete $t 'devices')) { Write-TcRemediationAlert 'Device collection incomplete: run Invoke-TcAssessment again.'; continue }
    $unmanaged = @($devices | Where-Object { -not (ConvertTo-TcBoolean $_['Managed']) -and $_['Join type'] -and $_['OS'] -match 'Windows' })
    $active = @($unmanaged | Where-Object { [int]$_['Days inactive'] -lt $threshold })
    $registered = @($active | Where-Object { $_['Join type'] -eq 'Registered' })
    Write-TcRemediationNote ('{0} unmanaged Windows device(s), {1} active: {2} registered, {3} joined to Entra ID' -f $unmanaged.Count, $active.Count, $registered.Count, ($active.Count - $registered.Count))
    foreach ($device in $active) {
        $rows.Add([ordered]@{
                Tenant = $t; Device = $device['Name']; OS = $device['OS']; Version = $device['Version']; 'Join type' = $device['Join type']; 'Last sign-in' = $device['Last sign-in']; 'Days inactive' = $device['Days inactive']
                Handling = $(if ($device['Join type'] -eq 'Registered') { 'Reconfigure the profile' } else { 'Technician' })
            })
    }
}

Close-TcRemediationBlock
[void](Export-TcRemediationReport -Name 'unmanaged-devices' -Rows @($rows))

foreach ($t in $c.Tenants) {
    $profiles = @($rows | Where-Object { $_['Tenant'] -eq $t -and $_['Handling'] -eq 'Reconfigure the profile' }).Count
    if ($profiles) {
        Add-TcManualAction -Tenant $t -Object 'Profiles' -Description ('Reconfigure the profiles of {0} unmanaged device(s)' -f $profiles) -Who 'Team and users' `
            -Instruction @('After the account migrates, on the device, in the session of the user: add the new work account in Office and OneDrive, and remove the old one.', 'Close Office first, and keep a copy of what the old profile holds locally.')
    }
    $technician = @($rows | Where-Object { $_['Tenant'] -eq $t -and $_['Handling'] -eq 'Technician' }).Count
    if ($technician) {
        Add-TcManualAction -Tenant $t -Object 'Joined unmanaged devices' -Description ('Handle {0} device(s) joined to Entra ID with no Intune management' -f $technician) `
            -Instruction @('A device joined to the old tenant is not fixed through its profile: join it to the target or reset it, with a technician.')
    }
}

Invoke-TcRemediationPlan
Close-TcRemediation

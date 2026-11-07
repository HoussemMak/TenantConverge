# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Frames the re-enrollment of Apple devices in the target and checks its connectors (procedure INT-CONNECTORS).

.DESCRIPTION
    Apple Business Manager has no API on the Microsoft side: creating the MDM server, reassigning devices and transferring tokens is
    done in its portal. The script reads the situation, declares the instructions and checks what Graph can read:
      - Apple MDM Push certificate of the target (applePushNotificationCertificate, v1.0);
      - automated enrollment tokens and imported devices of the target (depOnboardingSettings, beta only).
    Limit: the Apple enrollment policy has beta APIs, but its settings depend on the target design: it stays in the admin center. A
    re-enrollment often wipes the device: choosing the moment belongs to the user and the customer.
#>
$c = Open-TcRemediation

$AlertDays = 30

function Get-AppleDevice {
    param([string]$T)
    return @(Get-TcRemediationTable $T 'managedDevices' | Where-Object { $_['OS'] -match '^(macOS|iOS|iPadOS)' })
}

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    foreach ($x in Get-TcRemediationTable 'Target' 'intuneConnectors') {
        Write-TcRemediationNote ("Target, {0}: expires in {1} day(s)" -f $x['Type'], $x['Days remaining'])
        if ([int]$x['Days remaining'] -lt $AlertDays) { Write-TcRemediationAlert ("{0} of the target: to renew before re-enrolling the devices" -f $x['Type']) }
    }
    $connectors = @(Get-TcRemediationTable $t 'intuneConnectors')
    $apple = Get-AppleDevice $t
    Write-TcRemediationNote ("{0} managed Apple device(s), {1} Apple connector(s)" -f (Get-TcCount $apple), $connectors.Count)
    foreach ($x in $connectors) { Write-TcRemediationNote ("{0}: expires in {1} day(s)" -f $x['Type'], $x['Days remaining']) }
    foreach ($x in @($connectors | Where-Object { [int]$_['Days remaining'] -lt 0 })) { Write-TcRemediationAlert ("{0} of {1} expired: changes in this source no longer sync" -f $x['Type'], $t) }
    Export-TcRemediationReport -Name "apple-devices-$t" -Rows @($apple | ForEach-Object { [ordered]@{ Device = $_['Name']; 'Serial number' = ([string]$_['Serial number']).Trim(); OS = $_['OS']; Version = $_['Version']; 'Model' = $_['Model']; Enrollment = $_['Enrollment']; User = $_['User']; 'Days inactive' = $_['Days inactive'] } }) | Out-Null

    if ((Get-TcCount $apple)) {
        Add-TcManualAction -Tenant 'Target' -Object 'Apple Business Manager' -Description ("Reassign {0} device(s) to the MDM server of the target" -f (Get-TcCount $apple)) -Minutes 1 -IntervalSeconds 20 `
            -Instruction @('In Apple Business Manager, with the managed Apple account, reassign the devices of the report to the MDM server of the target.', 'If the source uses a separate Apple Business Manager account, confirm the steps with Apple first.') `
            -WaitUntil {
                param($a)
                $serials = @($c.Tenants | ForEach-Object { Get-AppleDevice $_ } | ForEach-Object { ([string]$_['Serial number']).Trim() })
                $seen = @(foreach ($j in @((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri 'beta/deviceManagement/depOnboardingSettings') 'value'))) {
                    Invoke-TcGraph -Tenant $a.tenant -Uri "beta/deviceManagement/depOnboardingSettings/$((Get-TcMember $j 'id'))/importedAppleDeviceIdentities" -All | ForEach-Object { ((Get-TcText $_ 'serialNumber')).Trim() }
                })
                return @($serials | Where-Object { $_ -notin $seen }).Count -eq 0
            }
        Add-TcManualAction -Tenant 'Target' -Object "Apple enrollment policy" -Description "Check the enrollment policy and its group in the target" `
            -Instruction @("Intune admin center, target: Devices, Enrollment, Apple, Enrollment program tokens.", 'Check the enrollment policy and assign it to the right group.')
        Add-TcManualAction -Tenant 'Target' -Object 'Apple pilot device' -Description 'Reset the pilot or have it re-enrolled, then repeat by waves' -Who 'Team and users' `
            -Instruction @('Warn the user and back up: a re-enrollment often wipes the device.', 'Validate the pilot before the next wave.')
    }
    if (@($connectors | Where-Object { $_['Type'] -match 'VPP' }).Count) {
        Add-TcManualAction -Tenant $t -Object 'VPP token' -Description "Transfer the Apple app license token to the target" `
            -Instruction @('Remove the VPP token from the source before uploading it to the target: a token serves one tenant only.', 'Download it again from Apple Business Manager if it has expired.')
    }
}

Invoke-TcRemediationPlan -Verify {
    $p = Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/deviceManagement/applePushNotificationCertificate'
    $days = if ((Get-TcMember $p 'expirationDateTime')) { (Get-TcMember ([datetime](Get-TcMember $p 'expirationDateTime') - (Get-TcRemediationNow)) 'TotalDays') } else { -1 }
    if (-not (Get-TcMember $p 'expirationDateTime')) { New-TcRemediationResult Warning 'no Apple MDM Push certificate in the target' }
    elseif ($days -lt $AlertDays) { New-TcRemediationResult Warning ("Apple MDM Push certificate of the target: {0:N0} day(s) left" -f $days) } else { New-TcRemediationResult OK ("Apple MDM Push certificate of the target: {0:N0} day(s) left" -f $days) }
    foreach ($j in @((Get-TcMember (Invoke-TcGraph -Tenant 'Target' -Uri 'beta/deviceManagement/depOnboardingSettings') 'value'))) {
        if (-not (Get-TcMember $j 'tokenExpirationDateTime')) { New-TcRemediationResult Warning ("token {0}: no expiry date" -f (Get-TcMember $j 'tokenName')); continue }
        $r = (Get-TcMember ([datetime](Get-TcMember $j 'tokenExpirationDateTime') - (Get-TcRemediationNow)) 'TotalDays')
        if ($r -lt $AlertDays) { New-TcRemediationResult Warning ("token {0}: {1:N0} day(s) left" -f (Get-TcMember $j 'tokenName'), $r) } else { New-TcRemediationResult OK ("token {0}: {1:N0} day(s) left" -f (Get-TcMember $j 'tokenName'), $r) }
    }
}
Close-TcRemediation

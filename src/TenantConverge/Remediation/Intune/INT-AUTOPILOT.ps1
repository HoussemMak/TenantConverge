# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Prepares the Autopilot of the target and moves the devices of the source, device by device, according to the decisions (procedure INT-AUTOPILOT).

.DESCRIPTION
    In the target: dynamic group of migrated devices, deployment profile with the naming pattern of the DeviceNamePattern setting,
    copied from the Entra profile of the target, then assignment of the profile to the group. Autopilot profiles exist only in Graph beta.
    decisions\INT-AUTOPILOT-TAG.csv sets the group tag: the proposal, or the value entered in Note.
    decisions\INT-AUTOPILOT.csv says which devices to move. A stale device or one tied to an excluded device is proposed as Exclude.

    The hardware hash cannot be read through Graph: windowsAutopilotDeviceIdentity exposes it neither in v1.0 nor in beta, only the
    import accepts it. It is collected on the device, with Get-WindowsAutopilotInfo. Reporting through Intune does not work: the output of
    a remediation is limited to 2,048 characters, less than the hash. CSV files placed in <output>\autopilot\<tenant> are read by this script.

    A hash that is missing, cut or unreadable does not count as collected: the device does not leave the source.
    Moving a device: removal from the Autopilot of the source, waiting for it to go, import into the target with the tag.
    Each move writes to two tenants: the primary domain of the target and of each source are both asked before the first write.
    The device stays enrolled in the Intune of the source: Microsoft documents the Autopilot removal in one step, without deleting the
    device from Intune, which keeps the remote wipe of CUT-02. The action is critical: at the first error, the plan stops.
    To validate on the pilot device. Deleting the device from the Intune of the source comes after its return to the target.

    Limit: the hash of a device that has never contacted Intune needs physical access to the device, or the reseller.
#>
$c = Open-TcRemediation

$GroupName = (Get-TcObjectName ' - Migrated devices')
$ProfileName = (Get-TcObjectName ' - Migrated devices (WS-####)')
$NameTemplate = (Get-TcRemediationOption 'DeviceNamePattern')
$IdentityUri = 'v1.0/deviceManagement/windowsAutopilotDeviceIdentities'
$ProfileUri = 'beta/deviceManagement/windowsAutopilotDeploymentProfiles'
$Threshold = [int](Get-TcRemediationOption 'StaleDeviceDays')

function Get-AutopilotIdentity {
    <# Autopilot registration of a serial number, read on the tenant. The full list avoids relying on a filter on the number. #>
    param([string]$Tenant, [string]$Serial)
    return @(Invoke-TcGraph -Tenant $Tenant -Uri $IdentityUri -All | Where-Object { ((Get-TcText $_ 'serialNumber')).Trim() -eq $Serial }) | Select-Object -First 1
}

function Test-HashValid {
    <# A damaged hash only shows at import, when the device has already left the source: valid base64, longer than 2,048 characters. #>
    param([string]$HashValue)
    if ((Get-TcMember $HashValue 'Length') -le 2048) { return $false }
    try { [void][Convert]::FromBase64String($HashValue); return $true } catch { return $false }
}

function Find-DeviceGroup {
    <# The group of migrated devices and its rule, read back on the tenant. #>
    param([string]$Tenant)
    return @((Get-TcMember (Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/groups?`$filter=displayName eq '{0}'&`$select=id,membershipRule" -f $GroupName)) 'value')) | Select-Object -First 1
}

function Get-HashFile {
    <# Hashes collected for a source: the files of Get-WindowsAutopilotInfo, one or more CSV, stay out of the logs. #>
    param([string]$Source)
    $d = Join-Path (Get-TcRemediationOutput) "autopilot\$Source"
    $h = @{}
    if (-not (Test-Path -LiteralPath $d)) { return $h }
    foreach ($f in Get-ChildItem -LiteralPath $d -Filter '*.csv' -File) {
        foreach ($l in Import-Csv -LiteralPath (Get-TcMember $f 'FullName')) {
            $s = ((Get-TcText $l 'Device Serial Number')).Trim()
            if ($s -and (Test-HashValid ((Get-TcText $l 'Hardware Hash')))) { $h[$s] = $l }
        }
    }
    return $h
}

$deviceProposals = @(); $tagProposals = @()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $computers = @(Get-TcRemediationTable $t 'autopilotDevices')
    $managed = @{}
    foreach ($m in Get-TcRemediationTable $t 'managedDevices') { $managed[([string]$m['Serial number']).Trim()] = $m }
    $stale = @(Get-ChildItem -LiteralPath (Get-TcDecisionFolder) -Filter "INT-STALE-$t.csv" -ErrorAction SilentlyContinue | ForEach-Object { Import-Csv -LiteralPath (Get-TcMember $_ 'FullName') -Encoding utf8BOM } | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Remove' } | ForEach-Object { ((Get-TcText $_ 'Serial number')).Trim() })
    $hashes = Get-HashFile -Source $t
    $enrolled = @($computers | Where-Object { $_['Enrollment state'] -eq 'enrolled' }).Count
    Write-TcRemediationNote ("{0} Autopilot device(s): {1} enrolled in Intune, {2} with no contact; {3} hash(es) collected" -f $computers.Count, $enrolled, ($computers.Count - $enrolled), (Get-TcCount $hashes))
    $autopilotSerials = @($computers | ForEach-Object { ([string]$_['Serial number']).Trim() })
    $outsideAutopilot = @(Get-TcRemediationTable $t 'managedDevices' | Where-Object { $_['OS'] -eq 'Windows' -and [int]$_['Days inactive'] -lt $Threshold -and ([string]$_['Serial number']).Trim() -notin $autopilotSerials })
    if ($outsideAutopilot.Count) { Write-TcRemediationAlert ("{0} active Windows device(s) outside Autopilot: add to the deployment plan, or handle by hand" -f $outsideAutopilot.Count) }
    $tagProposals += [ordered]@{ Tenant = $t; 'Group tag' = (Get-TcMember (Get-TcRemediationTenant $t) 'Prefix'); 'Devices' = $computers.Count; Proposal = 'Keep' }
    $deviceProposals += @(foreach ($p in $computers) {
        $serial = ([string]$p['Serial number']).Trim()
        $m = $managed[$serial]
        $days = if ($m) { [int]$m['Days inactive'] }
        $choice = if ($serial -in $stale -or ($m -and $days -ge $Threshold)) { 'Exclude' } else { 'Move' }
        [ordered]@{ Tenant = $t; 'Serial number' = $serial; 'Model' = $p['Model']; 'State' = $p['Enrollment state']; Device = $(if ($m) { $m['Name'] }); User = $(if ($m) { $m['User'] }); 'Days inactive' = $days; 'Hash collected' = $(if ($hashes.Contains($serial)) { 'Yes' } else { 'No' }); Proposal = $choice }
    })
}
$tags = @(Get-TcDecision -Name 'INT-AUTOPILOT-TAG' -Proposal $tagProposals -Key 'Tenant' -Choice 'Keep')
$decisions = @(Get-TcDecision -Name 'INT-AUTOPILOT' -Proposal $deviceProposals -Key 'Tenant', 'Serial number' -Choice 'Move', 'Exclude')

$rules = @(foreach ($e in $tags) {
    $value = if ((Get-TcMember $e 'Note')) { (Get-TcText $e 'Note') } else { (Get-TcText $e 'Group tag') }
    '(device.devicePhysicalIds -any (_ -eq "[OrderID]:{0}"))' -f $value
})
if ($rules.Count) {
    Add-TcGraphAction -Tenant 'Target' -Method POST -Uri 'v1.0/groups' -Object $GroupName -Description 'Create the dynamic group of migrated devices' `
        -Body @{ displayName = $GroupName; description = 'Devices migrated to the target through Autopilot, according to their group tag.'; mailEnabled = $false; mailNickname = (Get-TcObjectName '-migrated-devices').ToLowerInvariant(); securityEnabled = $true; groupTypes = @('DynamicMembership'); membershipRule = ($rules -join ' or '); membershipRuleProcessingState = 'On' } `
        -Test { param($a) [bool](Find-DeviceGroup $a.tenant) }

    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object $GroupName -Description 'Add to the group rule the tags decided since its creation' -Data @{ Rules = @($rules) } `
        -Test {
            param($a)
            $g = Find-DeviceGroup $a.tenant
            return (-not $g -or -not @($a.data.Rules | Where-Object { ((Get-TcText $g 'membershipRule')).IndexOf($_) -lt 0 }).Count)
        } `
        -Block {
            param($a)
            $g = Find-DeviceGroup $a.tenant
            $missingItems = @($a.data.Rules | Where-Object { ((Get-TcText $g 'membershipRule')).IndexOf($_) -lt 0 })
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'PATCH'; uri = "v1.0/groups/$((Get-TcMember $g 'id'))"; body = @{ membershipRule = (Get-TcMember $g 'membershipRule') } }
            Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri "v1.0/groups/$((Get-TcMember $g 'id'))" -Body @{ membershipRule = (@(@((Get-TcMember $g 'membershipRule')) + $missingItems | Where-Object { $_ }) -join ' or ') } | Out-Null
        }

    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object $ProfileName -Description ("Create the Autopilot profile {0}" -f $NameTemplate) -Data @{ Name = $ProfileName; NamePattern = $NameTemplate; Template = [string](Get-TcMember (Get-TcRemediationTable 'Target' 'autopilotProfiles' | Where-Object { $_['Type'] -eq 'azureADWindowsAutopilotDeploymentProfile' } | Select-Object -First 1) 'Name') } `
        -Test { param($a) [bool]@((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri $ProfileUri) 'value') | Where-Object { (Get-TcMember $_ 'displayName') -eq $a.data.Name }).Count } `
        -Block {
            param($a)
            $template = @((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri $ProfileUri) 'value') | Where-Object { (Get-TcMember $_ 'displayName') -eq $a.data.Template }) | Select-Object -First 1
            if (-not $template) { throw "Template profile $($a.data.Template) not found in the target" }
            $body = @{ '@odata.type' = '#microsoft.graph.azureADWindowsAutopilotDeploymentProfile'; displayName = $a.data.Name; description = 'Migrated devices: copy of the Entra profile of the target, naming convention of the target design.'; deviceNameTemplate = $a.data.NamePattern; deviceType = 'windowsPc'; roleScopeTagIds = @('0'); hardwareHashExtractionEnabled = $false; preprovisioningAllowed = [bool](Get-TcProperty $template 'preprovisioningAllowed' $false) }
            foreach ($k in 'local', 'outOfBoxExperienceSetting', 'enrollmentStatusScreenSettings') { $v = Get-TcProperty $template $k; if ($null -ne $v) { $body[$k] = $v } }
            $n = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri $ProfileUri -Body $body
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "$ProfileUri/$((Get-TcMember $n 'id'))" }
        }

    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object $ProfileName -Description 'Assign the profile to the group of migrated devices' -Data @{ Name = $ProfileName; Group = $GroupName } `
        -Test {
            param($a)
            $p = @((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri $ProfileUri) 'value') | Where-Object { (Get-TcMember $_ 'displayName') -eq $a.data.Name }) | Select-Object -First 1
            $a.data.Profile = (Get-TcMember $p 'id')
            $a.data.GroupId = (Get-TcMember ((@((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/groups?`$filter=displayName eq '{0}'&`$select=id" -f $a.data.Group)) 'value')) | Select-Object -First 1)) 'id')
            return [bool]@((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri "$ProfileUri/$((Get-TcMember $p 'id'))/assignments") 'value') | Where-Object { (Get-TcMember (Get-TcMember $_ 'target') 'groupId') -eq $a.data.GroupId }).Count
        } `
        -Block {
            param($a)
            $n = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri "$ProfileUri/$($a.data.Profile)/assignments" -Body @{ target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $a.data.GroupId } }
            if ((Get-TcMember $n 'id')) { $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "$ProfileUri/$($a.data.Profile)/assignments/$((Get-TcMember $n 'id'))" } }
        }
}

$ComputersWithNoHash = @{}
foreach ($t in $c.Tenants) {
    $tag = @($tags | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t }) | Select-Object -First 1
    $hashes = Get-HashFile -Source $t
    $chosenOnes = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Move' })
    $noHash = @($chosenOnes | Where-Object { -not $hashes.Contains((Get-TcText $_ 'Serial number')) })
    $ComputersWithNoHash[$t] = $noHash   # a deferred block does not keep the loop value: it reads by tenant
    if ($noHash.Count) {
        Add-TcManualAction -Tenant $t -Object 'Hardware hashes' -Description ("Collect the hardware hash of {0} device(s)" -f $noHash.Count) -Minutes 1 -IntervalSeconds 20 `
            -Instruction @(('On each device, as administrator: Install-Script -Name Get-WindowsAutopilotInfo, then Get-WindowsAutopilotInfo -OutputFile <serial number>.csv' ), ("Drop the files in {0}" -f (Join-Path (Get-TcRemediationOutput) "autopilot\$t")), 'A device that was never contacted is collected at first startup, or from the reseller. The script picks the devices up as soon as the file is there.') `
            -WaitUntil { param($a) $files = Get-HashFile -Source $a.tenant; @($ComputersWithNoHash[$a.tenant] | Where-Object { -not $files.Contains((Get-TcText $_ 'Serial number')) }).Count -eq 0 }
    }
    if (-not $tag) { continue }
    $value = if ((Get-TcMember $tag 'Note')) { (Get-TcText $tag 'Note') } else { (Get-TcText $tag 'Group tag') }
    foreach ($d in $chosenOnes | Where-Object { $hashes.Contains((Get-TcText $_ 'Serial number')) }) {
        $serial = (Get-TcText $d 'Serial number')
        Add-TcBlockAction -Tenant 'Target' -AlsoWrites $t -Service Graph -Object $serial -Description ("Move {0} from the Autopilot of {1} to the target" -f $serial, $t) -Critical -Data @{ Source = $t; Serial = $serial; Tag = $value } `
            -Reason 'Rollback is possible by removing the device from the target, then reimporting its hash, kept in the collection folder, into the source.' `
            -Test { param($a) [bool](Get-AutopilotIdentity -Tenant $a.tenant -Serial $a.data.Serial) } `
            -Block {
                param($a)
                $d = $a.data
                $h = (Get-HashFile -Source (Get-TcMember $d 'Source'))[(Get-TcMember $d 'Serial')]
                if (-not $h) { throw "$((Get-TcMember $d 'Serial')): hash missing or unreadable: nothing is removed from the source." }
                $i = Get-AutopilotIdentity -Tenant (Get-TcMember $d 'Source') -Serial (Get-TcMember $d 'Serial')
                if ($i) {
                    if ((Get-TcMember $i 'userPrincipalName')) { Invoke-TcGraph -Tenant $a.alsoWrites[0] -Method POST -Uri "$IdentityUri/$((Get-TcMember $i 'id'))/unassignUserFromDevice" | Out-Null }
                    Invoke-TcGraph -Tenant $a.alsoWrites[0] -Method DELETE -Uri "$IdentityUri/$((Get-TcMember $i 'id'))" | Out-Null
                    $end = (Get-TcRemediationNow).AddMinutes(20)
                    while (Get-AutopilotIdentity -Tenant (Get-TcMember $d 'Source') -Serial (Get-TcMember $d 'Serial')) {
                        if ((Get-TcRemediationNow) -ge $end) { throw "$((Get-TcMember $d 'Serial')) still enrolled in the Autopilot of $((Get-TcMember $d 'Source')) after 20 minutes" }
                        Wait-TcRemediation -Seconds 30
                    }
                }
                $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri 'v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/import' -Body @{ importedWindowsAutopilotDeviceIdentities = @(@{ '@odata.type' = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'; serialNumber = (Get-TcMember $d 'Serial'); groupTag = (Get-TcMember $d 'Tag'); productKey = (Get-TcText $h 'Windows Product ID'); hardwareIdentifier = (Get-TcText $h 'Hardware Hash') }) }
                $import = (Get-TcMember ((@((Get-TcMember $r 'value')) | Select-Object -First 1)) 'id')
                $end = (Get-TcRemediationNow).AddMinutes(20)
                while ($true) {
                    $e = Invoke-TcGraph -Tenant $a.tenant -Uri "v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$import"
                    if ((Get-TcMember (Get-TcMember $e 'state') 'deviceImportStatus') -eq 'error') { throw ("Import of {0} refused: {1} ({2})" -f (Get-TcMember $d 'Serial'), (Get-TcMember (Get-TcMember $e 'state') 'deviceErrorName'), (Get-TcMember (Get-TcMember $e 'state') 'deviceErrorCode')) }
                    if ((Get-TcMember (Get-TcMember $e 'state') 'deviceImportStatus') -eq 'complete') { break }
                    if ((Get-TcRemediationNow) -ge $end) { throw "Import of $((Get-TcMember $d 'Serial')) not finished after 20 minutes" }
                    Wait-TcRemediation -Seconds 30
                }
                Invoke-TcGraph -Tenant $a.tenant -Method DELETE -Uri "v1.0/deviceManagement/importedWindowsAutopilotDeviceIdentities/$import" | Out-Null
            }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $d = @(Invoke-TcGraph -Tenant 'Target' -Uri 'beta/deviceManagement/windowsAutopilotDeviceIdentities' -All)
    $expectedItems = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Move' } | ForEach-Object { (Get-TcText $_ 'Serial number') })
    $arrived = @($d | Where-Object { ((Get-TcText $_ 'serialNumber')).Trim() -in $expectedItems })
    $profiles = @($arrived | Where-Object { (Get-TcMember $_ 'deploymentProfileAssignmentStatus') -like 'assigned*' })
    if ($arrived.Count -lt $expectedItems.Count) { New-TcRemediationResult Warning ("{0} device(s) out of {1} enrolled in the target" -f $arrived.Count, $expectedItems.Count) } elseif ($expectedItems.Count) { New-TcRemediationResult OK ("{0} device(s) enrolled in the target" -f $arrived.Count) }
    if ($arrived.Count) { New-TcRemediationResult Info ("{0} device(s) out of {1} have their Autopilot profile" -f $profiles.Count, $arrived.Count) }
    $p = @((Get-TcMember (Invoke-TcGraph -Tenant 'Target' -Uri $ProfileUri) 'value') | Where-Object { (Get-TcMember $_ 'displayName') -eq $ProfileName }) | Select-Object -First 1
    if ($p -and (Get-TcMember $p 'deviceNameTemplate') -eq $NameTemplate) { New-TcRemediationResult OK "profile $ProfileName in place, naming $NameTemplate" } elseif ($tags.Count) { New-TcRemediationResult Blocking "profile $ProfileName missing or different naming convention" }
}
Close-TcRemediation

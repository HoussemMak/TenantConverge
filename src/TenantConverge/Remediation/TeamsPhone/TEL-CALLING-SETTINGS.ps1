# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Reproduces in the target the forwarding, unanswered handling and delegations of voice users (procedure TEL-CALLING-SETTINGS).

.DESCRIPTION
    Comes after the cutover: an account is handled only if its number is assigned in the target according to the snapshot. Run again
    after TEL-NUMBERS and a new snapshot. Before that, the script only announces the users to warn.
    In an -Apply run, it reads the settings of the source again (Get-CsUserCallingSettings) and reproduces them. A target on an account of the
    source is converted through the matrix; a target with no match is not carried over and raises an alert.
    New-CsUserCallingDelegate also needs -PickUpHeldCalls and -JoinActiveCalls: the rights are carried over from the source.
    Limit: a call group aims at accounts of the source, the user redoes it in Teams.
#>
$c = Open-TcRemediation

$targetAccounts = @{}
foreach ($u in Get-TcRemediationTable 'Target' 'teamsUsers') { $targetAccounts[([string]$u['UPN']).ToLowerInvariant()] = [string]$u['UPN'] }
$assignedNumbers = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($n in Get-TcRemediationTable 'Target' 'phoneNumbers') { if ($n['Assigned to']) { [void]$assignedNumbers.Add([string]$n['Assigned to']) } }

$Matrices = @{}
$SettingRows = @{}

function Get-SourceSetting {
    <# Settings of all the users of a source, read at once: each change of tenant opens a Teams session again. #>
    param([string]$Source, [string[]]$Accounts)
    if ($SettingRows[$Source]) { return $SettingRows[$Source] }
    $r = @{}
    foreach ($u in $Accounts) { $r[$u.ToLowerInvariant()] = Invoke-TcServiceCommand -Tenant $Source -Service Teams -Command 'Get-CsUserCallingSettings' -Parameters @{ Identity = $u } }
    $SettingRows[$Source] = $r
    return $r
}

function ConvertTo-TargetValue {
    <# Number: unchanged. Account of the source: its account in the target. Empty if nothing matches. #>
    param([string]$Target, [string]$Source)
    if (-not $Target) { return '' }
    if ($Target -notmatch '@') { return $Target }
    $upn = ($Target -replace '^sip:', '').ToLowerInvariant()
    $l = $Matrices[$Source][$upn]
    if ($l) { foreach ($u in (Get-TcMember $l 'Target UPN'), (Get-TcMember $l 'Temporary UPN')) { if ($u -and $targetAccounts[([string]$u).ToLowerInvariant()]) { return "sip:$u" } } }
    return ''
}

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $matrix = @{}
    foreach ($l in @((Get-TcMember (Get-TcRemediationIdentity $t) 'rows'))) { $matrix[((Get-TcText $l 'Source UPN')).ToLowerInvariant()] = $l }
    $Matrices[$t] = $matrix
    $rows = @(Get-TcRemediationTable $t 'userCallingSettings' | Where-Object { $_['Forwarding'] -or $_['Unanswered'] -or $_['Delegates'] -or $_["Call group"] })
    Write-TcRemediationNote ("{0} user(s) with forwarding, unanswered handling, delegation or a call group" -f $rows.Count)
    if (-not $rows.Count) { continue }
    $sourceAccounts = @($rows | ForEach-Object { [string]$_['UPN'] })
    $ready = 0
    foreach ($p in $rows) {
        $src = [string]$p['UPN']
        $l = $matrix[$src.ToLowerInvariant()]
        $target = if ($l) { @((Get-TcMember $l 'Target UPN'), (Get-TcMember $l 'Temporary UPN') | Where-Object { $_ -and $targetAccounts[([string]$_).ToLowerInvariant()] }) | Select-Object -First 1 }
        if (-not $target -or -not $assignedNumbers.Contains([string]$target)) { continue }
        $ready++
        Add-TcBlockAction -Tenant 'Target' -Service Teams -Object ([string]$target) -Description ("Reproduce the calling settings of {0}" -f $target) -Data @{ Source = $t; SourceAccount = $src; Target = [string]$target; Accounts = $sourceAccounts } `
            -Test {
                param($a)
                $s = (Get-SourceSetting -Source $a.data.Source -Accounts $a.data.Accounts)[$a.data.SourceAccount.ToLowerInvariant()]
                $d = Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsUserCallingSettings' -Parameters @{ Identity = $a.data.Target }
                $a.undo = @(
                    @{ command = 'Set-CsUserCallingSettings'; parameters = @{ Identity = $a.data.Target; IsForwardingEnabled = [bool](Get-TcMember $d 'IsForwardingEnabled') } }
                    @{ command = 'Set-CsUserCallingSettings'; parameters = @{ Identity = $a.data.Target; IsUnansweredEnabled = [bool](Get-TcMember $d 'IsUnansweredEnabled') } })
                return ([bool](Get-TcMember $s 'IsForwardingEnabled') -eq [bool](Get-TcMember $d 'IsForwardingEnabled') -and [bool](Get-TcMember $s 'IsUnansweredEnabled') -eq [bool](Get-TcMember $d 'IsUnansweredEnabled') -and @((Get-TcMember $s 'Delegates')).Count -eq @((Get-TcMember $d 'Delegates')).Count)
            } `
            -Block {
                param($a)
                $s = (Get-SourceSetting -Source $a.data.Source -Accounts $a.data.Accounts)[$a.data.SourceAccount.ToLowerInvariant()]
                $id = $a.data.Target
                if ((Get-TcMember $s 'IsForwardingEnabled')) {
                    $p = @{ Identity = $id; IsForwardingEnabled = $true; ForwardingType = (Get-TcText $s 'ForwardingType'); ForwardingTargetType = (Get-TcText $s 'ForwardingTargetType') }
                    $target = ConvertTo-TargetValue -Target ((Get-TcText $s 'ForwardingTarget')) -Source $a.data.Source
                    if ((Get-TcMember $s 'ForwardingTarget') -and -not $target) { Write-TcRemediationAlert ("{0}: forwarding target {1} has no match in the target, forwarding not carried over" -f $id, (Get-TcMember $s 'ForwardingTarget')) }
                    else {
                        if ($target) { $p.ForwardingTarget = $target }
                        Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Set-CsUserCallingSettings' -Parameters $p | Out-Null
                    }
                }
                if ((Get-TcMember $s 'IsUnansweredEnabled')) {
                    $p = @{ Identity = $id; IsUnansweredEnabled = $true; UnansweredTargetType = (Get-TcText $s 'UnansweredTargetType'); UnansweredDelay = (Get-TcText $s 'UnansweredDelay') }
                    $target = ConvertTo-TargetValue -Target ((Get-TcText $s 'UnansweredTarget')) -Source $a.data.Source
                    if ((Get-TcMember $s 'UnansweredTarget') -and -not $target) { Write-TcRemediationAlert ("{0}: unanswered target {1} has no match in the target, setting not carried over" -f $id, (Get-TcMember $s 'UnansweredTarget')) }
                    else {
                        if ($target) { $p.UnansweredTarget = $target }
                        Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Set-CsUserCallingSettings' -Parameters $p | Out-Null
                    }
                }
                foreach ($x in @((Get-TcMember $s 'Delegates'))) {
                    $target = ConvertTo-TargetValue -Target ((Get-TcText $x 'Id')) -Source $a.data.Source
                    if (-not $target) { Write-TcRemediationAlert ("{0}: delegate {1} has no match in the target, delegation not carried over" -f $id, (Get-TcMember $x 'Id')); continue }
                    Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'New-CsUserCallingDelegate' -Parameters @{ Identity = $id; Delegate = $target; MakeCalls = [bool](Get-TcMember $x 'MakeCalls'); ReceiveCalls = [bool](Get-TcMember $x 'ReceiveCalls'); ManageSettings = [bool](Get-TcMember $x 'ManageSettings'); PickUpHeldCalls = [bool](Get-TcMember $x 'PickUpHeldCalls'); JoinActiveCalls = [bool](Get-TcMember $x 'JoinActiveCalls') } | Out-Null
                    $a.undo = @($a.undo) + @(@{ command = 'Remove-CsUserCallingDelegate'; parameters = @{ Identity = $id; Delegate = $target } })
                }
                if (@((Get-TcMember $s 'CallGroupTargets')).Count) { Write-TcRemediationAlert ("{0}: call group to be redone by the user in Teams" -f $id) }
            }
    }
    Write-TcRemediationNote ("{0} user(s) ready: account present in the target and number assigned" -f $ready)
    Add-TcManualAction -Tenant $t -Object "Calling settings" -Description ("Warn the {0} user(s) whose calling settings will be reproduced" -f $rows.Count) `
        -Instruction @("These settings belong to the user: warn them before changing anything.", 'A target left on a number or an account of the source makes the forwarding fail.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $n = 0; $gaps = 0
    foreach ($a in $script:TcRemediationRun['Actions'] | Where-Object { (Get-TcMember $_ 'type') -eq 'Block' -and (Get-TcMember (Get-TcMember $_ 'data') 'Source') -eq $t }) {
        $n++
        $s = (Get-SourceSetting -Source $t -Accounts $a.data.Accounts)[$a.data.SourceAccount.ToLowerInvariant()]
        $d = Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command 'Get-CsUserCallingSettings' -Parameters @{ Identity = $a.data.Target }
        if ([bool](Get-TcMember $s 'IsForwardingEnabled') -ne [bool](Get-TcMember $d 'IsForwardingEnabled') -or [bool](Get-TcMember $s 'IsUnansweredEnabled') -ne [bool](Get-TcMember $d 'IsUnansweredEnabled')) { $gaps++ }
    }
    if ($gaps) { New-TcRemediationResult Warning ("{0} user(s) out of {1} still differ from the source" -f $gaps, $n) } elseif ($n) { New-TcRemediationResult OK ("{0} user(s) match the source" -f $n) }
}
Close-TcRemediation

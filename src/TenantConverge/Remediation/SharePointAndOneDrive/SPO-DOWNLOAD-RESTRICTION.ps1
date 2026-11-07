# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Prepares then enables the download restriction from unmanaged devices in the target (SEC-07).

.DESCRIPTION
    No procedure in the plan: the script follows the Microsoft documentation on app enforced restrictions.
    First step, with no effect on users, on the decision in decisions\SPO-DOWNLOAD-RESTRICTION-POLICY.csv: create the conditional access
    policy in report-only, on SharePoint, with the session control app enforced restrictions. Emergency accounts and migration team
    accounts are excluded from it.
    Second step, after reading the sign-in logs: decisions\SPO-DOWNLOAD-RESTRICTION.csv holds one row. With Enable, the script turns the
    policy on, with the common guards of SEC-03, then sets SharePoint to AllowLimitedAccess.
    While the row says Wait, nothing changes. If the activation is refused, SharePoint is not touched: the documentation does not say if
    Set-PnPTenant creates active policies itself.
    Limits: guests are aimed at by the policy. Anyone links are not. An application in application mode is exempt. The copy tool account,
    though, can be affected if it works from an unmanaged device: check before the activation.
#>
$c = Open-TcRemediation

$PolicyName = (Get-TcObjectName ' - SharePoint - Download restriction on unmanaged devices')
$AppSharePoint = '00000003-0000-0ff1-ce00-000000000000'

function Get-TargetCaPolicy {
    param([string]$Target)
    return (@(Invoke-TcGraph -Tenant $Target -Uri 'v1.0/identity/conditionalAccess/policies' -All) | Where-Object { (Get-TcMember $_ 'displayName') -eq $PolicyName } | Select-Object -First 1)
}

$decisions = @(Get-TcDecision -Name 'SPO-DOWNLOAD-RESTRICTION-POLICY' -Proposal @($c.Tenants | ForEach-Object { [ordered]@{ Tenant = $_; Policy = $PolicyName; Proposal = 'Report only' } }) -Key 'Tenant' -Choice 'Report only', 'Do not apply')

foreach ($t in @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Report only' } | ForEach-Object { (Get-TcMember $_ 'Tenant') })) {
    Write-TcRemediationTenant $t
    $current = [string](Get-TcRemediationValue $t 'sharePointSettings' 'ConditionalAccessPolicy')
    $devices = @(Get-TcRemediationTable $t 'managedDevices').Count
    Write-TcRemediationNote ("Read: SharePoint setting {0}; {1} device(s) managed in Intune" -f $current, $devices)
    $team = @(Get-TcRemediationTable $t 'users' | Where-Object { (Test-TcProtectedAccount -Account ([string]$_['UPN'])) } | ForEach-Object { $_['UPN'] })
    $emergency = @(Get-TcEmergencyAccount)
    Write-TcRemediationNote ("Excluded from the policy: {0} emergency account(s), {1} migration team account(s)" -f $emergency.Count, $team.Count)

    Add-TcBlockAction -Tenant $t -Service Graph -Object $PolicyName -Description "Create the policy in report-only mode, with no effect on users" -Data @{ ExcludedItems = @($emergency + $team) } -Critical `
        -Test { param($a) [bool](Get-TargetCaPolicy $a.tenant) } `
        -Block {
            param($a)
            # a missing emergency account would make a misleading exclusion: the failure is intended
            $ids = @($a.data.ExcludedItems | ForEach-Object { (Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users/{0}?`$select=id" -f [uri]::EscapeDataString($_))) 'id') })
            $body = @{ displayName = $PolicyName; state = 'enabledForReportingButNotEnforced'
                        conditions = @{ users = @{ includeUsers = @('All'); excludeUsers = $ids }; applications = @{ includeApplications = @($AppSharePoint) }; clientAppTypes = @('all') }
                        sessionControls = @{ applicationEnforcedRestrictions = @{ isEnabled = $true } } }
            $n = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri 'v1.0/identity/conditionalAccess/policies' -Body $body
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "v1.0/identity/conditionalAccess/policies/$((Get-TcMember $n 'id'))" }
        }

    $row = [ordered]@{ Subject = 'Enable the download restriction'; 'Current SharePoint setting' = $current; Proposal = 'Wait' }
    $d = @(Get-TcDecision -Name 'SPO-DOWNLOAD-RESTRICTION' -Proposal @($row) -Key 'Subject' -Choice 'Enable', 'Wait') | Select-Object -First 1
    if ((Get-TcMember $d 'Decision') -ne 'Enable') {
        Add-TcManualAction -Tenant $t -Object 'Report only' -Description "Read the effect of the policy before deciding to enable it" `
            -Instruction @("Entra > Sign-in logs, Conditional Access tab in report-only: policy $PolicyName.", 'Count the users and guests affected, then enter Enable in decisions\SPO-DOWNLOAD-RESTRICTION.csv.')
        continue
    }
    Add-TcPolicyActivation -Tenant $t -Name $PolicyName -Critical
    Add-TcCommandAction -Tenant $t -Service Pnp -Command 'Set-PnPTenant' -Parameters @{ ConditionalAccessPolicy = 'AllowLimitedAccess' } -Object 'ConditionalAccessPolicy' `
        -Description "Limit SharePoint to web access for unmanaged devices" `
        -Test {
            param($a)
            $p = Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Get-PnPTenant'
            $a.undo = @{ command = 'Set-PnPTenant'; parameters = @{ ConditionalAccessPolicy = (Get-TcText $p 'ConditionalAccessPolicy') } }
            return (Get-TcText $p 'ConditionalAccessPolicy') -eq 'AllowLimitedAccess'
        }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $s = Get-TargetCaPolicy $t
    if (-not $s) { New-TcRemediationResult Blocking 'policy missing'; return }
    New-TcRemediationResult OK ("policy present, state {0}" -f (Get-TcMember $s 'state'))
    Get-TcExclusionResult -Tenant $t -Policy $s
    New-TcRemediationResult Info ("{0} account(s) excluded from the policy" -f @((Get-TcMember (Get-TcMember (Get-TcMember $s 'conditions') 'users') 'excludeUsers')).Count)
    New-TcRemediationResult Info ("SharePoint setting: {0}" -f (Get-TcMember (Invoke-TcServiceCommand -Tenant $t -Service Pnp -Command 'Get-PnPTenant') 'ConditionalAccessPolicy'))
}
Close-TcRemediation

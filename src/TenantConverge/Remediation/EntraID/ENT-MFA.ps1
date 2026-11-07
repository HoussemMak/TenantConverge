# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Creates in report-only the policy that requires MFA for all, then enables it on decision (procedure ENT-MFA).

.DESCRIPTION
    Data read: the conditional access policies, security settings, accounts and roles read.
    The policy is created only if the customer decides so, in the target as in a source: with no decision, nothing is planned.
    The proposal is Report only in the target, a mode that touches no sign-in, and Do not apply in a source.
    Scope: all users, all resources, authentication strength Multifactor authentication.
    Exclusions: emergency accounts and the sync accounts role, which covers all Entra Connect accounts.

    decisions\ENT-MFA.csv: one row per tenant, Do not apply, Report only or Enable.
    The proposal is never Enable: this step stays a customer choice, policy by policy.

    Guards of the activation, whatever the decisions:
      - the policy is in the snapshot, and reads on the tenant, in report-only;
      - the ENT-MFA-REGISTRATION campaign is handled, in each tenant: each account read has a valid decision in
        ENT-MFA-REGISTRATION.csv, and the collection of registrations is complete;
      - the emergency accounts exist, are enabled, have a FIDO2 key in the target and are excluded; otherwise the script refuses;
      - the policy has not changed for at least three days;
      - security defaults are off.
    The exclusion is read back after the activation: if it is missing, the policy goes back to report-only.

    Limits: analyzing the sign-ins affected during report-only stays a human read of the logs. An external authentication method is
    incompatible with the authentication strength: in that case, use the control Require multifactor authentication.
#>
$c = Open-TcRemediation

$PolicyName = (Get-TcObjectName ' - MFA for all')
$ReportOnlyState = $script:TcReportOnlyState
$MfaStrengthId = '00000000-0000-0000-0000-000000000002'      # built-in strength Multifactor authentication





function Get-SimilarPolicy {
    <# Policies that already aim at all users and all resources with an MFA requirement: to compare before enabling ours. #>
    param([string]$Tenant)
    return @(Get-TcRemediationTable $Tenant 'conditionalAccess' | Where-Object { $_['Users'] -eq 'All' -and $_['Applications'] -eq 'All' -and $_['Controls'] -match 'mfa|Multifactor' -and $_['Name'] -ne $PolicyName })
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'MFA requirement read'
    $caPolicies = @(Get-TcRemediationTable $t 'conditionalAccess')
    if (-not $caPolicies.Count -and -not (Test-TcCollectionComplete $t 'conditionalAccess')) { Write-TcRemediationAlert 'Conditional access: incomplete collection, an empty table proves nothing.' }
    $activePolicies = @($caPolicies | Where-Object { ConvertTo-TcBoolean $_['MFA for all'] })
    $report = @($caPolicies | Where-Object { $_['State'] -eq $ReportOnlyState })
    $similar = @(Get-SimilarPolicy $t)
    $noMethod = @(Get-TcRemediationPlanAction -Procedure 'ENT-MFA-REGISTRATION' -Tenant $t | ForEach-Object { (Get-TcMember $_ 'items') } | Where-Object { $_ }).Count
    $sync = @(Get-TcRemediationTable $t 'adminRoles' | Where-Object { $_['Role'] -eq 'Directory Synchronization Accounts' }).Count
    Write-TcRemediationNote ("{0} policy(ies) read, {1} report-only, {2} require(s) MFA for all in active mode" -f $caPolicies.Count, $report.Count, $activePolicies.Count)
    Write-TcRemediationNote ("{0} active account(s) with no MFA method; {1} sync account(s) covered by the role exclusion" -f $noMethod, $sync)
    foreach ($s in $similar) { Write-TcRemediationNote ("Similar, to compare: {0} ({1})" -f $s['Name'], $s['State']) }
    $existingItem = $caPolicies | Where-Object { $_['Name'] -eq $PolicyName } | Select-Object -First 1
    [ordered]@{ Tenant = $t; Policy = $PolicyName; 'State read' = $(if ($existingItem) { $existingItem['State'] } else { 'missing' }); 'Accounts with no method' = $noMethod
                'Similar policies' = (@($similar | ForEach-Object { '{0} ({1})' -f $_['Name'], $_['State'] }) -join ' ; ')
                Proposal = $(if ($t -eq 'Target') { 'Report only' } else { 'Do not apply' }) }
}
$decisions = @(Get-TcDecision -Name 'ENT-MFA' -Proposal @($proposals | Where-Object { $_ }) -Key 'Tenant' -Choice 'Do not apply', 'Report only', 'Enable')

foreach ($t in $c.Tenants) {
    $d = $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | Select-Object -First 1
    $choice = if ($d) { (Get-TcMember $d 'Decision') } else { '' }
    if ($choice -notin 'Report only', 'Enable') { Write-TcRemediationNote ("{0}: no policy without a customer decision (migrated accounts will inherit those of the target)" -f $t); continue }
    if (ConvertTo-TcBoolean (Get-TcRemediationValue $t 'securitySettings' 'Security defaults enabled')) { Write-TcRemediationAlert ("{0}: security defaults are enabled: conditional access cannot be enabled." -f $t); continue }

    $missing = @(Get-TcMissingProtectedAccount $t)
    if ($missing.Count) { Write-TcRemediationAlert ("{0}: emergency accounts missing from the snapshot: {1}; enabling will stay refused (EMERGENCY-ACCESS procedure, SEC-02)." -f $t, ($missing -join ', ')) }
    $existingItem = Get-TcRemediationTable $t 'conditionalAccess' | Where-Object { $_['Name'] -eq $PolicyName } | Select-Object -First 1

    if (-not $existingItem) {
        Add-TcBlockAction -Tenant $t -Service Graph -Object $PolicyName -Description ("Create policy {0} in report-only mode" -f $PolicyName) `
            -Test { param($a) [bool](Get-TcConditionalAccessPolicy $a.tenant $PolicyName) } `
            -Block {
                param($a)
                if ((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri 'v1.0/policies/identitySecurityDefaultsEnforcementPolicy') 'isEnabled')) { throw 'Security defaults are enabled: disable them first.' }
                $x = Resolve-TcAccountId $a.tenant @(Get-TcProtectedAccount $a.tenant)
                foreach ($u in (Get-TcMember $x 'Missing')) { Write-TcRemediationAlert ("{0} does not exist yet: to exclude before enabling, the script handles it at that time" -f $u) }
                $body = @{ displayName = $PolicyName; state = $ReportOnlyState
                            conditions = @{ users = @{ includeUsers = @('All'); excludeUsers = @((Get-TcMember $x 'Ids')); excludeRoles = @($script:TcSyncRoleId) }
                                            applications = @{ includeApplications = @('All') }; clientAppTypes = @('all') }
                            grantControls = @{ operator = 'OR'; authenticationStrength = @{ id = $MfaStrengthId } } }
                $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri $script:TcPolicyUri -Body $body
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "$script:TcPolicyUri/$((Get-TcMember $r 'id'))" }
            }
    }
    elseif ($existingItem['State'] -eq 'enabled') { Write-TcRemediationNote ("{0}: policy already active" -f $t) }

    if ($choice -ne 'Enable') {
        if ($existingItem -and $existingItem['State'] -eq $ReportOnlyState) { Add-TcManualAction -Tenant $t -Object 'Observation' -Description 'Analyze the sign-ins affected in report-only mode, then decide on enabling' -Who 'Team' `
            -Instruction @('Entra ID > Monitoring & health > Sign-in logs, Conditional Access tab.', 'Handle the service accounts, the migration account and the devices affected.', 'After approval and announcement, enter Enable in decisions\ENT-MFA.csv.') }
        continue
    }
    if (-not $existingItem) { Write-TcRemediationAlert ("{0}: enabling decided, but the policy is not yet in the snapshot: create, observe, refresh the snapshot." -f $t); continue }
    if ($existingItem['State'] -ne $ReportOnlyState) { continue }
    if ($missing.Count -or -not @(Get-TcProtectedAccount $t).Count) { Write-TcRemediationAlert ("{0}: enabling blocked: emergency accounts missing." -f $t); continue }
    if (-not (Test-TcCollectionComplete $t 'mfaRegistrations')) { Write-TcRemediationAlert ("{0}: MFA registration collection incomplete: enabling blocked, run Invoke-TcAssessment again." -f $t); continue }
    $accounts = @(Get-TcRemediationPlanAction -Procedure 'ENT-MFA-REGISTRATION' -Tenant $t | ForEach-Object { (Get-TcMember $_ 'items') } | Where-Object { $_ } | ForEach-Object { @{ Tenant = $t; Account = $_ } })
    $pending = @(Get-TcUndecidedRow -Name 'ENT-MFA-REGISTRATION' -Key 'Tenant', 'Account' -Choice 'Register', 'Remove' -Expected $accounts -Tenant $t)
    if ($pending.Count) { Write-TcRemediationAlert ("{0}: {1} campaign account(s) with no valid decision: enabling blocked (run ENT-MFA-REGISTRATION -Tenant {0}, then decide)." -f $t, $pending.Count); continue }
    Add-TcPolicyActivation -Tenant $t -Name $PolicyName
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $p = Get-TcConditionalAccessPolicy $t $PolicyName
    if (-not $p) {
        if ($t -eq 'Target') { New-TcRemediationResult Blocking "policy missing: $PolicyName" } else { New-TcRemediationResult Info 'no policy created in this source' }
        return
    }
    if ((Get-TcMember $p 'state') -eq 'enabled') { New-TcRemediationResult OK 'MFA is required for all: the MFA check before cutover will recognize this policy' }
    else { New-TcRemediationResult Info ("policy in {0} mode: the MFA check before cutover does not recognize it yet" -f (Get-TcMember $p 'state')) }
    if ($script:TcSyncRoleId -notin @((Get-TcMember (Get-TcMember (Get-TcMember $p 'conditions') 'users') 'excludeRoles'))) { New-TcRemediationResult Blocking 'the role of the sync accounts is not excluded' }
    Get-TcExclusionResult -Tenant $t -Policy $p
}
Close-TcRemediation

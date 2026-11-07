# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Creates in report-only the policy that blocks legacy authentication, then enables it on decision (procedure ENT-LEGACY-AUTH).

.DESCRIPTION
    Depends on the procedure ENT-LEGACY-SIGN-INS. The policy is created in report-only on a decision, tenant by tenant: this mode cuts
    nothing, and with no decision nothing is planned. The activation waits until all the accounts of this tenant have a decision in
    decisions\ENT-LEGACY-SIGN-INS.csv, because the block could cut a printer or an application.

    Scope: all users, all resources, clients Exchange ActiveSync and Other clients, access blocked.
    Exclusions: emergency accounts, the sync accounts role and accounts marked Temporary exclusion. Each temporary exclusion stays
    exposed: owner and due date in the decisions file.

    decisions\ENT-LEGACY-AUTH.csv: one row per tenant, Report only or Enable. Nothing is created or enabled without a decision.

    Guards of the activation, whatever the decisions:
      - each legacy sign-in read has a valid decision, and the collection is complete;
      - the emergency accounts exist, are enabled, have a FIDO2 key in the target and are excluded; otherwise the script refuses;
      - the policy is in the snapshot and reads on the tenant in report-only, unchanged for at least three days;
      - security defaults are off.
    The exclusion is read back after the activation: if it is missing, the policy goes back to report-only.

    Limit: the link with EXO-PROTOCOLS stays to follow, authenticated SMTP also closes on the Exchange side.
#>
$c = Open-TcRemediation

$PolicyName = (Get-TcObjectName ' - Block legacy authentication')
$ReportOnlyState = $script:TcReportOnlyState
$UnknownAccount = '(account not resolved)'
$SignInChoices = @('Modern client', 'Other sending method', 'Replacement', 'Drop', 'Temporary exclusion')   # values of ENT-LEGACY-SIGN-INS
$SignInFile = 'ENT-LEGACY-SIGN-INS'





$signIns = if (Test-TcDecisionFile $SignInFile) { @(Read-TcDecisionRow $SignInFile) } else { @() }

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Legacy authentication block'
    $caPolicies = @(Get-TcRemediationTable $t 'conditionalAccess')
    if (-not $caPolicies.Count -and -not (Test-TcCollectionComplete $t 'conditionalAccess')) { Write-TcRemediationAlert 'Conditional access: incomplete collection, an empty table proves nothing.' }
    $activePolicies = @($caPolicies | Where-Object { $_['State'] -eq 'enabled' -and (ConvertTo-TcBoolean $_['Blocks legacy authentication']) })
    $accounts = @(Get-TcRemediationTable $t 'legacySignIns').Count
    $ofTenant = @($signIns | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t })
    $pending = @($ofTenant | Where-Object { -not (Get-TcMember $_ 'Decision') }).Count
    Write-TcRemediationNote ("{0} active policy(ies) already block it; {1} legacy sign-in row(s) read, {2} with no decision" -f $activePolicies.Count, $accounts, $(if ($ofTenant.Count) { $pending } else { 'all' }))
    $existingItem = $caPolicies | Where-Object { $_['Name'] -eq $PolicyName } | Select-Object -First 1
    [ordered]@{ Tenant = $t; Policy = $PolicyName; 'State read' = $(if ($existingItem) { $existingItem['State'] } else { 'missing' }); 'Legacy sign-ins' = $accounts; Proposal = 'Report only' }
}
$decisions = @(Get-TcDecision -Name 'ENT-LEGACY-AUTH' -Proposal @($proposals | Where-Object { $_ }) -Key 'Tenant' -Choice 'Report only', 'Enable')

foreach ($t in $c.Tenants) {
    if (ConvertTo-TcBoolean (Get-TcRemediationValue $t 'securitySettings' 'Security defaults enabled')) { Write-TcRemediationNote ("{0}: security defaults already block legacy authentication" -f $t); continue }
    # only a policy on all accounts and all resources makes ours unnecessary: a partial policy would let the rest through
    $blockingOnes = @(Get-TcRemediationTable $t 'conditionalAccess' | Where-Object { $_['State'] -eq 'enabled' -and (ConvertTo-TcBoolean $_['Blocks legacy authentication']) })
    if (@($blockingOnes | Where-Object { $_['Users'] -eq 'All' -and $_['Applications'] -eq 'All' }).Count) { Write-TcRemediationNote ("{0}: an active policy already blocks legacy authentication for everyone: nothing to create" -f $t); continue }
    if ($blockingOnes.Count) { Write-TcRemediationNote ("{0}: {1} active policy(ies) block legacy authentication only for some of the accounts or resources: compare before enabling our own" -f $t, $blockingOnes.Count) }
    $missing = @(Get-TcMissingProtectedAccount $t)
    if ($missing.Count) { Write-TcRemediationAlert ("{0}: emergency accounts missing from the snapshot: {1}; enabling will stay refused." -f $t, ($missing -join ', ')) }
    $ofTenant = @($signIns | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t })
    $temporary = @($ofTenant | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Temporary exclusion' -and (Get-TcMember $_ 'Account') -ne $UnknownAccount } | ForEach-Object { (Get-TcMember $_ 'Account') } | Select-Object -Unique)
    $existingItem = Get-TcRemediationTable $t 'conditionalAccess' | Where-Object { $_['Name'] -eq $PolicyName } | Select-Object -First 1

    if (-not $existingItem -and -not @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t }).Count) { Write-TcRemediationNote ("{0}: no policy without a decision" -f $t) }
    elseif (-not $existingItem) {
        Add-TcBlockAction -Tenant $t -Service Graph -Object $PolicyName -Description ("Create policy {0} in report-only mode" -f $PolicyName) -Data @{ Temporary = @($temporary) } `
            -Test { param($a) [bool](Get-TcConditionalAccessPolicy $a.tenant $PolicyName) } `
            -Block {
                param($a)
                $x = Resolve-TcAccountId $a.tenant @(Get-TcProtectedAccount $a.tenant)
                foreach ($u in (Get-TcMember $x 'Missing')) { Write-TcRemediationAlert ("{0} does not exist yet: to exclude before enabling, the script handles it at that time" -f $u) }
                $others = Resolve-TcAccountId $a.tenant @($a.data.Temporary)
                $body = @{ displayName = $PolicyName; state = $ReportOnlyState
                            conditions = @{ users = @{ includeUsers = @('All'); excludeUsers = @(@((Get-TcMember $x 'Ids')) + @((Get-TcMember $others 'Ids'))); excludeRoles = @($script:TcSyncRoleId) }
                                            applications = @{ includeApplications = @('All') }; clientAppTypes = @('exchangeActiveSync', 'other') }
                            grantControls = @{ operator = 'OR'; builtInControls = @('block') } }
                $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri $script:TcPolicyUri -Body $body
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "$script:TcPolicyUri/$((Get-TcMember $r 'id'))" }
            }
    }

    $d = $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Enable' } | Select-Object -First 1
    if (-not $d) { continue }
    if (-not $existingItem) { Write-TcRemediationAlert ("{0}: enabling decided, but the policy is not yet in the snapshot: create, observe, refresh the snapshot." -f $t); continue }
    if ($existingItem['State'] -ne $ReportOnlyState) { continue }
    if (-not (Test-TcCollectionComplete $t 'legacySignIns')) { Write-TcRemediationAlert ("{0}: legacy sign-in collection incomplete: block postponed, run Invoke-TcAssessment again." -f $t); continue }
    $readItems = @(Get-TcRemediationTable $t 'legacySignIns' | ForEach-Object { @{ Tenant = $t; Account = $(if ($_['UPN']) { $_['UPN'] } else { $UnknownAccount }); Client = [string]$_['Client'] } })
    $noDecision = @(Get-TcUndecidedRow -Name 'ENT-LEGACY-SIGN-INS' -Key 'Tenant', 'Account', 'Client' -Choice $SignInChoices -Expected $readItems -Tenant $t)
    if ($noDecision.Count) { Write-TcRemediationAlert ("{0}: {1} legacy sign-in row(s) with no valid decision: block postponed so as not to cut a legitimate use (run ENT-LEGACY-SIGN-INS, then decide)." -f $t, $noDecision.Count); continue }
    if ($missing.Count -or -not @(Get-TcProtectedAccount $t).Count) { Write-TcRemediationAlert ("{0}: enabling blocked: emergency accounts missing." -f $t); continue }
    Add-TcPolicyActivation -Tenant $t -Name $PolicyName -Temporary $temporary
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $p = Get-TcConditionalAccessPolicy $t $PolicyName
    if (-not $p) { New-TcRemediationResult Info "policy missing: $PolicyName"; return }
    New-TcRemediationResult $(if ((Get-TcMember $p 'state') -eq 'enabled') { 'OK' } else { 'Info' }) ("policy: {0}" -f (Get-TcMember $p 'state'))
    if (@((Get-TcMember (Get-TcMember $p 'conditions') 'clientAppTypes')) -notcontains 'other') { New-TcRemediationResult Blocking 'the policy does not target the other clients' }
    if ($script:TcSyncRoleId -notin @((Get-TcMember (Get-TcMember (Get-TcMember $p 'conditions') 'users') 'excludeRoles'))) { New-TcRemediationResult Blocking 'the role of the sync accounts is not excluded' }
    Get-TcExclusionResult -Tenant $t -Policy $p
}
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Recreates the voice routing specific to the sources and assigns the routing policy to voice users (procedure TEL-DIAL-PLANS).

.DESCRIPTION
    The script tells what is specific to a source from what each tenant gets by default: the Global plan with no rule, the Global policy
    with no usage and the LocalRoute route with no gateway are not recreated. What stays specific to a source becomes an instruction,
    with its name conflict check in the target.
    The routing policy only serves direct routing. It depends on TEL-ROUTING-TARGET:
      - type DirectRouting: decisions\TEL-DIAL-PLANS.csv names the policy of the target to use;
      - type OperatorConnect or CallingPlan: no policy to assign.
    The Global dial plan of the target already applies to all its accounts: no assignment per user.
    Only accounts already in the target according to the snapshot get the policy: run again after a new snapshot.
#>
$c = Open-TcRemediation

$TypeFile = 'TEL-ROUTING-TARGET'
$targetType = if (Test-TcDecisionFile $TypeFile) { @(Read-TcDecisionRow $TypeFile | ForEach-Object { (Get-TcMember $_ 'Decision') } | Where-Object { $_ }) | Select-Object -First 1 }

$targetAccounts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($u in Get-TcRemediationTable 'Target' 'teamsUsers') { [void]$targetAccounts.Add([string]$u['UPN']) }
$targetNames = @(foreach ($n in 'dialPlans', 'voiceRoutes', 'voiceRoutingPolicies') { Get-TcRemediationTable 'Target' $n | ForEach-Object { [string]$_['Name'] } })

$policy = ''
if ($targetType -eq 'DirectRouting') {
    $proposals = @(Get-TcRemediationTable 'Target' 'voiceRoutingPolicies' | Where-Object { $_['Name'] -ne 'Global' } | ForEach-Object { [ordered]@{ 'Policy' = $_['Name']; 'Usages' = $_['PSTN usages']; Proposal = '' } })
    $chosenPolicies = @(Get-TcDecision -Name 'TEL-DIAL-PLANS' -Proposal $proposals -Key 'Policy' -Choice 'Keep', 'Ignore' | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Keep' })
    if ($chosenPolicies.Count -gt 1) { Write-TcRemediationAlert ("{0} policies chosen: only one is expected, no assignment planned" -f $chosenPolicies.Count) }
    elseif ($chosenPolicies.Count -eq 1) { $policy = (Get-TcMember $chosenPolicies[0] 'Policy') -replace '^Tag:', '' }
}

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $plans = @(Get-TcRemediationTable $t 'dialPlans' | Where-Object { $_['Name'] -ne 'Global' -or [int]$_['Rules'] -gt 0 })
    $routes = @(Get-TcRemediationTable $t 'voiceRoutes' | Where-Object { $_['Gateways'] -or $_['Usages'] })
    $policies = @(Get-TcRemediationTable $t 'voiceRoutingPolicies' | Where-Object { $_['Name'] -ne 'Global' -or $_['PSTN usages'] })
    $people = @(Get-TcRemediationTable $t 'teamsUsers' | Where-Object { (ConvertTo-TcBoolean $_['Enterprise Voice']) -and $_['Features'] -notmatch 'VoiceApp' })
    Write-TcRemediationNote ("Specific to the source: {0} dial plan(s), {1} route(s), {2} policy(ies); {3} voice user(s)" -f $plans.Count, $routes.Count, $policies.Count, $people.Count)

    foreach ($x in @($plans + $routes + $policies)) {
        $conflict = if ([string]$x['Name'] -in $targetNames) { ' This name already exists in the target: choose another.' } else { '' }
        Add-TcManualAction -Tenant 'Target' -Object ([string]$x['Name']) -Description ("Recreate in the target the voice element {0} of {1}" -f $x['Name'], $t) `
            -Instruction @(("Element specific to {0}: {1}. The snapshot does not carry its rules: read them in {0}, then recreate them in the target.{2}" -f $t, ($x | ConvertTo-Json -Compress), $conflict), 'Check the order of the routes: a misplaced route sends calls to the wrong gateway.')
    }

    if (-not $people.Count) { continue }
    if (-not $targetType) { Write-TcRemediationAlert 'Number type not decided (TEL-ROUTING-TARGET): no assignment planned.'; continue }
    if ($targetType -ne 'DirectRouting') { Write-TcRemediationNote ("Type {0}: the routing policy does not apply" -f $targetType); continue }
    if (-not $policy) { Write-TcRemediationAlert 'Routing policy not chosen in decisions\TEL-DIAL-PLANS.csv: no assignment planned.'; continue }

    $matrix = @{}
    foreach ($l in @((Get-TcMember (Get-TcRemediationIdentity $t) 'rows'))) { $matrix[((Get-TcText $l 'Source UPN')).ToLowerInvariant()] = $l }
    $missing = 0
    foreach ($u in $people) {
        $l = $matrix[([string]$u['UPN']).ToLowerInvariant()]
        if ($l -and (Get-TcMember $l 'Decision') -eq 'Exclude') { continue }
        $target = if ($l) { @((Get-TcMember $l 'Target UPN'), (Get-TcMember $l 'Temporary UPN') | Where-Object { $_ -and $targetAccounts.Contains([string]$_) }) | Select-Object -First 1 }
        if (-not $target) { $missing++; continue }
        Add-TcCommandAction -Tenant 'Target' -Service Teams -Command 'Grant-CsOnlineVoiceRoutingPolicy' -Parameters @{ Identity = [string]$target; PolicyName = $policy } -Object ([string]$target) `
            -Description ("Assign the routing policy {0} to {1}" -f $policy, $target) `
            -Test {
                param($a)
                $o = Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsOnlineUser' -Parameters @{ Identity = $a.parameters.Identity }
                $before = (Get-TcText $o 'OnlineVoiceRoutingPolicy')
                $a.undo = @{ command = 'Grant-CsOnlineVoiceRoutingPolicy'; parameters = @{ Identity = $a.parameters.Identity; PolicyName = $(if ($before) { $before }) } }
                return $before -eq $a.parameters.PolicyName
            }
    }
    if ($missing) { Write-TcRemediationAlert ("{0} account(s) not in the target yet: run again after they are created and after a new snapshot" -f $missing) }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne $c.Tenants[0]) { return }
    $routes = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command 'Get-CsOnlineVoiceRoute')
    $policies = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command 'Get-CsOnlineVoiceRoutingPolicy')
    New-TcRemediationResult Info ("Target: {0} route(s), {1} routing policy(ies)" -f $routes.Count, $policies.Count)
    if ($policy) {
        if (@($policies | Where-Object { ((Get-TcText $_ 'Identity') -replace '^Tag:', '') -eq $policy }).Count) { New-TcRemediationResult OK "policy $policy present" } else { New-TcRemediationResult Blocking "policy $policy not found in the target" }
    }
}
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the telephony provider of the migrated numbers decided (procedure TEL-ROUTING-TARGET).

.DESCRIPTION
    The strategy belongs to the customer. The first preview creates decisions\TEL-ROUTING-TARGET.csv: one row, with the facts read
    (numbers of the sources, number type of the target, routing domains).
    The decision is the number type in the target:
      - DirectRouting or OperatorConnect: the numbers join the provider of the target through a port;
      - CallingPlan: the numbers stay Microsoft calling plans and go through the Microsoft number service.
    TEL-DIAL-PLANS, TEL-USERS and TEL-NUMBERS read this decision.
    Limit: the capacity of the provider to receive these numbers is checked with them. The -Apply run reads the voice configuration of
    the target again to confirm the connection mode; it writes nothing.
#>
[void](Open-TcRemediation)

Write-TcRemediationTenant 'Target'
$sourceNumbers = @(foreach ($s in (Get-TcSourceRole)) { Get-TcRemediationTable $s 'phoneNumbers' })
$sourceTypes = @($sourceNumbers | Group-Object { $_['Type'] } | ForEach-Object { '{0}: {1}' -f (Get-TcMember $_ 'Name'), (Get-TcCount $_) })
$targetTypes = @(Get-TcRemediationTable 'Target' 'phoneNumbers' | Group-Object { $_['Type'] } | ForEach-Object { '{0}: {1}' -f (Get-TcMember $_ 'Name'), (Get-TcCount $_) })
$domains = @((Get-TcMember (Get-TcRemediationPlanAction -Procedure 'TEL-ROUTING-TARGET' -Tenant 'Target') 'items'))
Write-TcRemediationNote ("{0} number(s) to migrate ({1}); target: {2}; {3} routing domain(s), {4} gateway(s) read" -f $sourceNumbers.Count, ($sourceTypes -join ', '), ($targetTypes -join ', '), $domains.Count, @(Get-TcRemediationTable 'Target' 'pstnGateways').Count)

$proposal = [ordered]@{ Subject = 'Type of the migrated numbers in the target'; 'Numbers to migrate' = ($sourceTypes -join ', '); 'Target numbers' = ($targetTypes -join ', '); 'Routing domains of the target' = ($domains -join ', '); Proposal = '' }
$decisions = @(Get-TcDecision -Name 'TEL-ROUTING-TARGET' -Proposal @($proposal) -Key 'Subject' -Choice 'DirectRouting', 'OperatorConnect', 'CallingPlan')

if ($decisions.Count) { Write-TcRemediationNote ("Decision: type {0} in the target" -f (Get-TcMember $decisions[0] 'Decision')) }
else {
    Add-TcManualAction -Tenant 'Target' -Object 'Target provider' -Description 'Check that the target provider can receive the numbers of the sources' `
        -Instruction @("Ask the telephony provider of the target whether it can receive $($sourceNumbers.Count) Canadian numbers, at what cost and with what delay.", 'Have them confirm the connection mode: direct routing or Operator Connect.')
    Add-TcManualAction -Tenant 'Target' -Object 'Telephony workshop' -Description 'Present the two options to the customer and record the decision' -Who 'Client' `
        -Instruction @('Option 1: porting to the target provider. Option 2: keeping the Microsoft calling plans.', 'Enter the chosen type in decisions\TEL-ROUTING-TARGET.csv, then run this script again.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $gateways = @(Invoke-TcServiceCommand -Tenant $t -Service Teams -Command 'Get-CsOnlinePSTNGateway')
    $routes = @(Invoke-TcServiceCommand -Tenant $t -Service Teams -Command 'Get-CsOnlineVoiceRoute' | Where-Object { @((Get-TcMember $_ 'OnlinePstnGatewayList')).Count })
    $policies = @(Invoke-TcServiceCommand -Tenant $t -Service Teams -Command 'Get-CsOnlineVoiceRoutingPolicy' | Where-Object { @((Get-TcMember $_ 'OnlinePstnUsages')).Count })
    New-TcRemediationResult Info ("{0} direct routing gateway(s), {1} route(s) with a gateway, {2} policy(ies) with usages" -f $gateways.Count, $routes.Count, $policies.Count)
    if ($routes.Count -and -not $gateways.Count) { New-TcRemediationResult Warning 'Some routes target gateways that the tenant does not expose: routing is hosted by the provider, to confirm with them.' }
}
Close-TcRemediation

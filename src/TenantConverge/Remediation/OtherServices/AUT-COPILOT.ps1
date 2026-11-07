# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the fate of the Copilot licenses and agents of the sources decided (procedure AUT-COPILOT).

.DESCRIPTION
    Buys and assigns nothing: the licenses are planned in the target after the Purview governance, because Copilot surfaces any
    overshared content.
    decisions\AUT-COPILOT.csv: one row per account with a Copilot license, with its fate in the matrix; choices Carry over or Drop.
    exports\copilot-plan.csv sums it up. The account must keep an eligible base plan.

    Limits: Copilot Studio agents are not in the snapshot, and Graph does not expose them. They are read in the Power Platform admin
    center; agents do not follow the content copy, they must be recreated.
#>
$c = Open-TcRemediation

$proposals = @(foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Copilot licenses'
    $skus = @(Get-TcRemediationTable $t 'licenses' | Where-Object { $_['SKU'] -match '(?i)copilot' -and [int]$_['Consumed'] -gt 0 })
    if ($skus.Count) { Write-TcRemediationNote ((@($skus | ForEach-Object { '{0}: {1} used' -f $_['SKU'], $_['Consumed'] }) -join ' - ')) }
    $accounts = @(Get-TcRemediationTable $t 'users' | Where-Object { $_['Licenses'] -match '(?i)copilot' })
    $matrix = @{}
    foreach ($l in (Get-TcMember (Get-TcRemediationIdentity $t) 'rows')) { $matrix[$l.'Source UPN'.ToLowerInvariant()] = (Get-TcMember $l 'Decision') }
    foreach ($u in $accounts) {
        [ordered]@{ Tenant = $t; Account = $u['UPN']; Name = $u['Name']; Licenses = $u['Licenses']; Active = $(if (ConvertTo-TcBoolean $u['Enabled']) { 'Yes' } else { 'No' }); Matrix = [string]$matrix[([string]$u['UPN']).ToLowerInvariant()]; Proposal = '' }
    }
    $environments = @(Get-TcRemediationTable $t 'powerEnvironments').Count
    Add-TcManualAction -Tenant $t -Object 'Copilot Studio agents' -Who 'Customer' -Description ("Inventory the Copilot Studio agents of {0}, with their owner" -f $t) `
        -Instruction @(("Power Platform admin center, {0} environment(s) read: list each agent and its owner." -f $environments), 'Have the use of each agent confirmed: it must be recreated in the target, it does not follow the content copy.')
})

$decisions = @(Get-TcDecision -Name 'AUT-COPILOT' -Proposal $proposals -Key 'Tenant', 'Account' -Choice 'Carry over', 'Drop')
$toCarryOver = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Carry over' })
if ($decisions.Count) {
    Export-TcRemediationReport -Name 'copilot-plan' -Rows $decisions | Out-Null
    Write-TcRemediationNote ("{0} license(s) to plan in the target after the Purview governance of the target design, to announce to the affected users" -f $toCarryOver.Count)
}

Invoke-TcRemediationPlan
Close-TcRemediation

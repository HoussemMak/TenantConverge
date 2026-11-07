# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Designs a single set of Teams policies for the target and creates the missing policies (procedure CON-TEAMS-POLICIES).

.DESCRIPTION
    Reads the teamsPolicies table of each source and of the target, then groups the custom policies by type and by name, not by
    source. decisions\CON-TEAMS-POLICIES.csv says for each: Reuse (it exists in the target), Recreate or Set aside.
    Only Recreate writes to the target, with New-Cs<Type> -Identity: the policy starts from the global values of the target.
    Limit: the script does not copy the settings of the source. If they matter, adjust them in the Teams admin center.
    The assignment by group and rank is done by TMS-POLICIES.
#>
$c = Open-TcRemediation

function Get-PolicyName { param([string]$Identity) return ($Identity -replace '^Tag:', '') }

$target = @{}
foreach ($p in Get-TcRemediationTable 'Target' 'teamsPolicies') { $target[('{0}|{1}' -f $p['Type'], (Get-PolicyName $p['Identity']))] = 1 }

$byKey = [ordered]@{}
foreach ($t in @($c.Tenants | Where-Object { $_ -ne 'Target' })) {
    Write-TcRemediationTenant $t
    $personal = @(Get-TcRemediationTable $t 'teamsPolicies' | Where-Object { ConvertTo-TcBoolean $_['Custom'] })
    Write-TcRemediationNote ("{0} custom policy(ies) read" -f $personal.Count)
    foreach ($p in $personal) {
        $name = Get-PolicyName $p['Identity']
        $key = '{0}|{1}' -f $p['Type'], $name
        if (-not $byKey.Contains($key)) { $byKey[$key] = [ordered]@{ Type = $p['Type']; Policy = $name; Sources = [System.Collections.Generic.List[string]]::new() } }
        $byKey[$key].Sources.Add($t)
    }
}

$proposals = foreach ($key in $byKey.Keys) {
    $e = $byKey[$key]
    $exists = $target.ContainsKey($key)
    [ordered]@{ Type = (Get-TcMember $e 'Type'); Policy = (Get-TcMember $e 'Policy'); Sources = ((Get-TcMember $e 'Sources') -join ', '); 'Exists in target' = $(if ($exists) { 'Yes' } else { 'No' }); Proposal = $(if ($exists) { 'Reuse' } else { '' }) }
}
if ('Target' -in $c.Tenants) { Write-TcRemediationTenant 'Target' }
$missingOnes = @($proposals | Where-Object { $_['Exists in target'] -eq 'No' })
Write-TcRemediationNote ("{0} distinct policy(ies), including {1} missing from the target" -f @($proposals).Count, $missingOnes.Count)

$decisions = @(Get-TcDecision -Name 'CON-TEAMS-POLICIES' -Proposal @($proposals) -Key 'Type', 'Policy' -Choice 'Reuse', 'Recreate', 'Set aside')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Recreate' }) {
    if ((Get-TcMember $d 'Exists in target') -eq 'Yes') { Write-TcRemediationAlert ("{0} {1} already exists in the target: Recreate decision ignored" -f (Get-TcMember $d 'Type'), (Get-TcMember $d 'Policy')); continue }
    Add-TcCommandAction -Tenant 'Target' -Service Teams -Command ("New-Cs{0}" -f (Get-TcMember $d 'Type')) -Parameters @{ Identity = (Get-TcMember $d 'Policy') } -Object ("{0} {1}" -f (Get-TcMember $d 'Type'), (Get-TcMember $d 'Policy')) `
        -Description ("Create the policy {0} ({1})" -f (Get-TcMember $d 'Policy'), (Get-TcMember $d 'Type')) `
        -Test {
            param($a)
            $readList = $a.command -replace '^New-', 'Get-'
            return [bool](@(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command $readList) | Where-Object { (Get-PolicyName (Get-TcMember $_ 'Identity')) -eq $a.parameters.Identity })
        } `
        -Undo @{ command = ("Remove-Cs{0}" -f (Get-TcMember $d 'Type')); parameters = @{ Identity = (Get-TcMember $d 'Policy') } }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    foreach ($d in @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Recreate' })) {
        $l = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command ("Get-Cs{0}" -f (Get-TcMember $d 'Type'))) | Where-Object { (Get-PolicyName (Get-TcMember $_ 'Identity')) -eq (Get-TcMember $d 'Policy') }
        if ($l) { New-TcRemediationResult OK ("{0} {1} present" -f (Get-TcMember $d 'Type'), (Get-TcMember $d 'Policy')) } else { New-TcRemediationResult Blocking ("{0} {1} missing" -f (Get-TcMember $d 'Type'), (Get-TcMember $d 'Policy')) }
    }
}
Close-TcRemediation

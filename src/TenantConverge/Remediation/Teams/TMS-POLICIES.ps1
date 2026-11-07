# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Assigns the chosen Teams policies to the migrated accounts, by business unit group (procedure TMS-POLICIES).

.DESCRIPTION
    Starts from the policies the plan read for each source. decisions\TMS-POLICIES.csv says, by source and by policy:
    Target policy (nothing to do: the account gets the global policy of the target) or Assign to group.
    The group is the one named in Note. The rank is 1. The policy must exist in the target: CON-TEAMS-POLICIES creates the missing ones.
    Limits: New-CsGroupPolicyAssignment is announced to go away in favor of Grant-Cs<Type> -Group.
    The assignment only reaches the direct members of the group and can take 24 hours. The check on a pilot account stays to be done.
#>
$c = Open-TcRemediation

function Get-GroupId {
    param([string]$Name)
    $f = $Name -replace "'", "''"
    return (Get-TcMember (@(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/groups?`$filter=displayName eq '{0}'&`$select=id" -f $f) -All) | Select-Object -First 1) 'id')
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $items = @(Get-TcRemediationPlanAction -Procedure 'TMS-POLICIES' -Tenant $t | ForEach-Object { (Get-TcMember $_ 'items') })
    Write-TcRemediationNote ("{0} policy(ies) to rule on" -f $items.Count)
    foreach ($e in $items) {
        $p = $e -split ' - '
        $exists = $e -match 'exists in the target'
        [ordered]@{ Tenant = $t; Type = $p[0]; Policy = $p[1]; Users = ($p[2] -replace '\D', ''); 'Exists in target' = $(if ($exists) { 'Yes' } else { 'No' }); Proposal = 'Target policy' }
    }
}
$decisions = @(Get-TcDecision -Name 'TMS-POLICIES' -Proposal @($proposals) -Key 'Tenant', 'Type', 'Policy' -Choice 'Target policy', 'Assign to group')

$assignedOnes = [System.Collections.Generic.List[object]]::new()
foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Assign to group' }) {
    $groups = @(Get-TcSourceGroup -Tenant (Get-TcMember $d 'Tenant'))
    $group = if ((Get-TcMember $d 'Note')) { (Get-TcText $d 'Note') } elseif ($groups.Count) { (Get-TcText $groups[0] 'name') } else { '' }
    if (-not $group) { Write-TcRemediationAlert ("{0}: no unit group known for {1}, specify the group in the Note column" -f (Get-TcMember $d 'Tenant'), (Get-TcMember $d 'Policy')); continue }
    $assignedOnes.Add(@{ Type = (Get-TcMember $d 'Type'); Policy = (Get-TcMember $d 'Policy'); Group = $group })
    Add-TcBlockAction -Tenant 'Target' -Service Teams -Object ("{0} {1}" -f (Get-TcMember $d 'Type'), (Get-TcMember $d 'Policy')) -Description ("Assign {0} to the group {1}, rank 1" -f (Get-TcMember $d 'Policy'), $group) -Data @{ Type = (Get-TcMember $d 'Type'); Policy = (Get-TcMember $d 'Policy'); Group = $group } `
        -Test {
            param($a)
            $id = Get-GroupId $a.data.Group
            if (-not $id) { return $false }
            return [bool](@(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsGroupPolicyAssignment' -Parameters @{ PolicyType = $a.data.Type }) | Where-Object { (Get-TcMember $_ 'GroupId') -eq $id -and (Get-TcMember $_ 'PolicyName') -eq $a.data.Policy })
        } `
        -Block {
            param($a)
            $id = Get-GroupId $a.data.Group
            if (-not $id) { throw "Group not found in the target: $($a.data.Group) (PREP-03)" }
            Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'New-CsGroupPolicyAssignment' -Parameters @{ GroupId = $id; PolicyType = $a.data.Type; PolicyName = $a.data.Policy; Rank = 1 } | Out-Null
            $a.undo = @{ command = 'Remove-CsGroupPolicyAssignment'; parameters = @{ GroupId = $id; PolicyType = $a.data.Type } }
        }
}
if ($assignedOnes.Count) {
    Add-TcManualAction -Tenant 'Target' -Object 'Pilot account' -Description "Check the effective policy on a pilot account of each unit" `
        -Instruction @("Get-CsUserPolicyAssignment -Identity <account> -PolicyType <type> gives the effective policy and its origin.", 'A direct assignment takes priority over the group: remove it if needed. A removed capability is announced to users.')
}

Invoke-TcRemediationPlan -Verify {
    foreach ($x in @($assignedOnes)) {
        $id = Get-GroupId (Get-TcMember $x 'Group')
        $ok = $id -and @(Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command 'Get-CsGroupPolicyAssignment' -Parameters @{ PolicyType = (Get-TcMember $x 'Type') }) | Where-Object { (Get-TcMember $_ 'GroupId') -eq $id -and (Get-TcMember $_ 'PolicyName') -eq (Get-TcMember $x 'Policy') }
        if ($ok) { New-TcRemediationResult OK ("{0} assigned to {1}" -f (Get-TcMember $x 'Policy'), (Get-TcMember $x 'Group')) } else { New-TcRemediationResult Blocking ("{0} not assigned to {1}" -f (Get-TcMember $x 'Policy'), (Get-TcMember $x 'Group')) }
    }
}
Close-TcRemediation

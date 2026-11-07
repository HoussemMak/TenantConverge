# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Recreates in the target the app protection policies the target design does not cover (procedure INT-MAM).

.DESCRIPTION
    Reads appProtection in the source and in the target. decisions\INT-MAM.csv says for each policy of the source: Covered by the target
    design (nothing to do) or Recreate. With Recreate, the script reads the policy in the source again, creates it in the target with the
    prefix of the unit, gives it the same applications and assigns it to the group named in Note.
    A policy with no assignment has no effect.
    Limit: the test on a pilot device (copy and paste, backup, PIN) stays to be done by a person.
#>
$c = Open-TcRemediation

$Collections = @{ iosManagedAppProtection = 'iosManagedAppProtections'; androidManagedAppProtection = 'androidManagedAppProtections' }
$RemovedFields = 'id', 'createdDateTime', 'lastModifiedDateTime', 'version', 'deployedAppCount', 'isAssigned', 'apps', 'assignments', 'apps@odata.context', 'assignments@odata.context', 'deploymentSummary'

function Get-TargetPolicy {
    param([string]$Target, [string]$Collection, [string]$Name)
    return (@(Invoke-TcGraph -Tenant $Target -Uri ("v1.0/deviceAppManagement/{0}" -f $Collection) -All) | Where-Object { (Get-TcMember $_ 'displayName') -eq $Name } | Select-Object -First 1)
}

$design = @(Get-TcRemediationTable 'Target' 'appProtectionPolicies')
$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    if (-not (Test-TcCollectionComplete $t 'appProtectionPolicies')) { Write-TcRemediationAlert 'Intune collection incomplete: the list may be partial' }
    $policies = @(Get-TcRemediationTable $t 'appProtectionPolicies')
    Write-TcRemediationNote ("{0} policy(ies) in the source, {1} in the target" -f $policies.Count, $design.Count)
    foreach ($p in $policies) {
        $same = @($design | Where-Object { $_['Type'] -eq $p['Type'] } | ForEach-Object { $_['Name'] })
        [ordered]@{ Tenant = $t; Policy = $p['Name']; Type = $p['Type']; 'Modified' = $p['Modified']; 'Same type in the target design' = ($same -join ', '); Proposal = $(if ($same.Count) { 'Covered by the target design' } else { 'Recreate' }) }
    }
}
$decisions = @(Get-TcDecision -Name 'INT-MAM' -Proposal @($proposals) -Key 'Tenant', 'Policy' -Choice 'Covered by the target design', 'Recreate')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Recreate' }) {
    $i = Get-TcRemediationTenant (Get-TcMember $d 'Tenant')
    $collection = $Collections[(Get-TcMember $d 'Type')]
    if (-not $collection) { Write-TcRemediationAlert ("{0}: type {1} not supported, to recreate by hand" -f (Get-TcMember $d 'Policy'), (Get-TcMember $d 'Type')); continue }
    $groups = @(Get-TcSourceGroup -Tenant $t)
    $group = if ((Get-TcMember $d 'Note')) { (Get-TcText $d 'Note') } elseif ($groups.Count) { (Get-TcText $groups[0] 'name') } else { '' }
    if (-not $group) { Write-TcRemediationAlert ("{0}: no unit group known, give the group in the Note column" -f (Get-TcMember $d 'Policy')); continue }
    $name = '{0} - {1}' -f (Get-TcMember $i 'Prefix'), (Get-TcMember $d 'Policy')
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object $name -Description ("Recreate {0} and assign it to {1}" -f $name, $group) -Data @{ Source = (Get-TcMember $d 'Tenant'); Type = (Get-TcMember $d 'Type'); Collection = $collection; Origin = (Get-TcMember $d 'Policy'); Name = $name; Group = $group } `
        -Test { param($a) [bool](Get-TargetPolicy $a.tenant $a.data.Collection $a.data.Name) } `
        -Block {
            param($a)
            $x = $a.data
            $f = (Get-TcMember $x 'Group') -replace "'", "''"
            $groupId = (Get-TcMember (@(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/groups?`$filter=displayName eq '{0}'&`$select=id" -f $f) -All) | Select-Object -First 1) 'id')
            if (-not $groupId) { throw "Group not found in the target: $((Get-TcMember $x 'Group')) (PREP-03)" }
            $s = Get-TargetPolicy (Get-TcMember $x 'Source') (Get-TcMember $x 'Collection') (Get-TcMember $x 'Origin')
            if (-not $s) { throw "Policy not found in the source: $((Get-TcMember $x 'Origin'))" }
            $complete = Invoke-TcGraph -Tenant (Get-TcMember $x 'Source') -Uri ("v1.0/deviceAppManagement/{0}/{1}?`$expand=apps" -f (Get-TcMember $x 'Collection'), (Get-TcMember $s 'id'))
            $body = [ordered]@{}
            foreach ($k in $complete.Keys) { if ($k -notin $RemovedFields -and $k -ne '@odata.context') { $body[$k] = $complete[$k] } }
            $body['@odata.type'] = '#microsoft.graph.{0}' -f (Get-TcMember $x 'Type')
            $body.displayName = (Get-TcMember $x 'Name')
            $n = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri ("v1.0/deviceAppManagement/{0}" -f (Get-TcMember $x 'Collection')) -Body $body
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = ("v1.0/deviceAppManagement/{0}/{1}" -f (Get-TcMember $x 'Collection'), (Get-TcMember $n 'id')) }
            $apps = @(@((Get-TcMember $complete 'apps')) | ForEach-Object { @{ '@odata.type' = '#microsoft.graph.managedMobileApp'; mobileAppIdentifier = (Get-TcMember $_ 'mobileAppIdentifier') } })
            if ($apps.Count) { Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri ("v1.0/deviceAppManagement/managedAppPolicies/{0}/targetApps" -f (Get-TcMember $n 'id')) -Body @{ apps = $apps } | Out-Null }
            $assignment = @(@{ '@odata.type' = '#microsoft.graph.targetedManagedAppPolicyAssignment'; target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $groupId } })
            Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri ("v1.0/deviceAppManagement/managedAppPolicies/{0}/assign" -f (Get-TcMember $n 'id')) -Body @{ assignments = $assignment } | Out-Null
        }
    Add-TcManualAction -Tenant 'Target' -Object $name -Description ("Try {0} on a pilot device" -f $name) -Instruction @('Copy and paste, backup and PIN, on a pilot device.', 'A policy that is too strict can block mobile access on the first day after cutover.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($d in @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Recreate' })) {
        $name = '{0} - {1}' -f (Get-TcMember (Get-TcRemediationTenant $t) 'Prefix'), (Get-TcMember $d 'Policy')
        $p = Get-TargetPolicy 'Target' $Collections[(Get-TcMember $d 'Type')] $name
        if ($p -and (Get-TcMember $p 'isAssigned')) { New-TcRemediationResult OK "$name created and assigned" } elseif ($p) { New-TcRemediationResult Warning "$name created, with no visible assignment" } else { New-TcRemediationResult Blocking "$name missing from the target" }
    }
}
Close-TcRemediation

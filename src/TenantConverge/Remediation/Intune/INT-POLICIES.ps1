# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Copies the chosen Intune policies to the target, with no assignment, then assigns them on decision (procedure INT-POLICIES).

.DESCRIPTION
    Comparison: the same name in the target counts as equivalent, which is a heuristic. Equivalents go to the equivalent-policies report;
    the rest goes in decisions\INT-POLICIES.csv, to compare with the target design. Only Recreate is copied.
    Copy through Graph: read at the source, read-only fields removed, creation in the target.
      - Compliance and Configuration: v1.0 (deviceCompliancePolicies, deviceConfigurations).
      - Settings catalog: beta only (configurationPolicies and its settings).
      - Administrative template: beta only (groupPolicyConfigurations, then updateDefinitionValues).
      - Enrollment: not copied, each tenant has its default configurations.
    Every policy is created with no assignment. decisions\INT-POLICIES-ASSIGNMENTS.csv says which to assign to the group of migrated
    devices, created by INT-AUTOPILOT. Graph replaces the assignments: the script keeps those that exist.
    Limits: an encrypted value of a custom profile cannot be carried over; the script stops on this policy, to recreate by hand. The
    Defender configuration specific to a tenant is proposed as Ignore. An administrative template based on an imported ADMX is not
    copied. Scripts and remediations are not in the inventory of the sources: check them in the admin center.
#>
$c = Open-TcRemediation

$GroupName = (Get-TcObjectName ' - Migrated devices')
$Roots = @{
    'Compliance'              = @{ Uri = 'v1.0/deviceManagement/deviceCompliancePolicies'; Name = 'displayName' }
    'Configuration'           = @{ Uri = 'v1.0/deviceManagement/deviceConfigurations'; Name = 'displayName' }
    'Settings catalog' = @{ Uri = 'beta/deviceManagement/configurationPolicies'; Name = 'name' }
    "Administrative template" = @{ Uri = 'beta/deviceManagement/groupPolicyConfigurations'; Name = 'displayName' }
}
$ReadOnlyFields = 'id', 'createdDateTime', 'lastModifiedDateTime', 'version', 'supportsScopeTags', 'settingCount', 'isAssigned', 'creationSource', 'priorityMetaData', 'assignments', 'scheduledActionsForRule',
                      'deviceManagementApplicabilityRuleOsEdition', 'deviceManagementApplicabilityRuleOsVersion', 'deviceManagementApplicabilityRuleDeviceMode', 'policyConfigurationIngestionType'
$EmptyGuid = '00000000-0000-0000-0000-000000000000'

function Find-PolicyRow {
    <# Policy of a category, by name; $null if it does not exist on this tenant. #>
    param([string]$Tenant, [string]$Category, [string]$Name)
    $r = $Roots[$Category]
    return @(Invoke-TcGraph -Tenant $Tenant -Uri (Get-TcMember $r 'Uri') -All | Where-Object { $_[(Get-TcMember $r 'Name')] -eq $Name }) | Select-Object -First 1
}

function Get-CopyBody {
    <# Creation body: the policy read, with no read-only field or annotation. #>
    param($Source)
    $h = @{}
    foreach ($k in $Source.Keys) {
        if ($k -in $ReadOnlyFields -or $k -match '@odata\.(context|id|etag)$' -or $null -eq $Source[$k]) { continue }
        $h[$k] = $Source[$k]
    }
    $h['roleScopeTagIds'] = @('0')
    return $h
}

function Copy-CompliancePolicy {
    param([string]$Source, $Policy)
    $x = Invoke-TcGraph -Tenant $Source -Uri ("{0}/{1}?`$expand=scheduledActionsForRule(`$expand=scheduledActionConfigurations)" -f (Get-TcMember $Roots['Compliance'] 'Uri'), (Get-TcMember $Policy 'id'))
    $body = Get-CopyBody $x
    # Graph requires this property at creation; notification templates are specific to the tenant and do not follow.
    $actions = @(foreach ($r in @((Get-TcMember $x 'scheduledActionsForRule') | Where-Object { $_ })) { foreach ($s in @((Get-TcMember $r 'scheduledActionConfigurations') | Where-Object { $_ })) { @{ actionType = (Get-TcMember $s 'actionType'); gracePeriodHours = (Get-TcMember $s 'gracePeriodHours'); notificationTemplateId = $EmptyGuid; notificationMessageCCList = @() } } })
    if (-not $actions.Count) { $actions = @(@{ actionType = 'block'; gracePeriodHours = 0; notificationTemplateId = $EmptyGuid; notificationMessageCCList = @() }) }
    $body.scheduledActionsForRule = @(@{ ruleName = 'PasswordRequired'; scheduledActionConfigurations = $actions })
    return (Invoke-TcGraph -Tenant 'Target' -Method POST -Uri (Get-TcMember $Roots['Compliance'] 'Uri') -Body $body)
}

function Copy-ConfigurationPolicy {
    param([string]$Source, $Policy)
    $x = Invoke-TcGraph -Tenant $Source -Uri ("{0}/{1}" -f (Get-TcMember $Roots['Configuration'] 'Uri'), (Get-TcMember $Policy 'id'))
    $secretItems = @(@((Get-TcMember $x 'omaSettings')) | Where-Object { (Get-TcMember $_ 'isEncrypted') -or (Get-TcMember $_ 'secretReferenceValueId') })
    if ($secretItems.Count) { throw ("{0} holds {1} encrypted value(s): recreate it by hand, then mark it Ignore." -f (Get-TcMember $Policy 'displayName'), $secretItems.Count) }
    return (Invoke-TcGraph -Tenant 'Target' -Method POST -Uri (Get-TcMember $Roots['Configuration'] 'Uri') -Body (Get-CopyBody $x))
}

function Copy-CatalogPolicy {
    param([string]$Source, $Policy)
    $r = (Get-TcMember $Roots['Settings catalog'] 'Uri')
    $x = Invoke-TcGraph -Tenant $Source -Uri "$r/$((Get-TcMember $Policy 'id'))"
    $settingRows = @(Invoke-TcGraph -Tenant $Source -Uri "$r/$((Get-TcMember $Policy 'id'))/settings" -All)
    $body = @{ name = (Get-TcMember $x 'name'); description = (Get-TcMember $x 'description'); platforms = (Get-TcMember $x 'platforms'); technologies = (Get-TcMember $x 'technologies'); roleScopeTagIds = @('0')
                settings = @($settingRows | ForEach-Object { @{ '@odata.type' = '#microsoft.graph.deviceManagementConfigurationSetting'; settingInstance = (Get-TcMember $_ 'settingInstance') } }) }
    $namePattern = Get-TcProperty (Get-TcProperty $x 'templateReference') 'templateId'
    if ($namePattern) { $body.templateReference = @{ templateId = $namePattern } }
    return (Invoke-TcGraph -Tenant 'Target' -Method POST -Uri $r -Body $body)
}

function Copy-AdministrativeTemplate {
    param([string]$Source, $Policy)
    $r = (Get-TcMember $Roots["Administrative template"] 'Uri')
    if ((Get-TcMember $Policy 'policyConfigurationIngestionType') -in 'custom', 'mixed') { throw ("{0} rests on an imported ADMX: recreate it by hand, then mark it Ignore." -f (Get-TcMember $Policy 'displayName')) }
    $values = @(Invoke-TcGraph -Tenant $Source -Uri ("{0}/{1}/definitionValues?`$expand=definition(`$select=id)" -f $r, (Get-TcMember $Policy 'id')) -All)
    $additions = @(foreach ($v in $values) {
        $definitionId = (Get-TcMember (Get-TcMember $v 'definition') 'id')
        $presentations = @(Invoke-TcGraph -Tenant $Source -Uri ("{0}/{1}/definitionValues/{2}/presentationValues?`$expand=presentation(`$select=id)" -f $r, (Get-TcMember $Policy 'id'), (Get-TcMember $v 'id')) -All)
        @{ enabled = (Get-TcMember $v 'enabled'); 'definition@odata.bind' = "https://graph.microsoft.com/beta/deviceManagement/groupPolicyDefinitions('$definitionId')"
           presentationValues = @(foreach ($p in $presentations) {
               $copy = @{ '@odata.type' = $p['@odata.type']; 'presentation@odata.bind' = ("https://graph.microsoft.com/beta/deviceManagement/groupPolicyDefinitions('{0}')/presentations('{1}')" -f $definitionId, (Get-TcMember (Get-TcMember $p 'presentation') 'id')) }
               foreach ($k in 'value', 'values') { if ($p.ContainsKey($k)) { $copy[$k] = $p[$k] } }
               $copy
           }) }
    })
    $n = Invoke-TcGraph -Tenant 'Target' -Method POST -Uri $r -Body @{ displayName = (Get-TcMember $Policy 'displayName'); description = (Get-TcMember $Policy 'description'); roleScopeTagIds = @('0') }
    Invoke-TcGraph -Tenant 'Target' -Method POST -Uri "$r/$((Get-TcMember $n 'id'))/updateDefinitionValues" -Body @{ added = $additions; updated = @(); deletedIds = @() } | Out-Null
    return $n
}

$sources = @(Get-TcRemediationPlanRole -RuleId 'INT-POLICIES')
$targetNames = @(Get-TcRemediationTable 'Target' 'intunePolicies' | ForEach-Object { ([string]$_['Name']).Trim().ToLowerInvariant() })
$proposals = [System.Collections.Generic.List[object]]::new()
$equivalents = [System.Collections.Generic.List[object]]::new()
foreach ($t in $sources) {
    Write-TcRemediationTenant $t
    $policies = @(Get-TcRemediationTable $t 'intunePolicies')
    $missingItems = @($policies | Where-Object { ([string]$_['Name']).Trim().ToLowerInvariant() -notin $targetNames })
    Write-TcRemediationNote ("{0} policy(ies), {1} with no equivalent of the same name in the target" -f $policies.Count, $missingItems.Count)
    foreach ($p in $policies | Where-Object { $_ -notin $missingItems }) { $equivalents.Add([ordered]@{ Tenant = $t; 'Category' = $p['Category']; Name = $p['Name']; Platform = $p['Platform'] }) }
    foreach ($p in $missingItems) {
        $ignoreItems = $p['Category'] -eq 'Enrollment' -or $p['Platform'] -eq 'windowsDefenderAdvancedThreatProtection'
        $proposals.Add([ordered]@{ Tenant = $t; 'Category' = $p['Category']; Name = $p['Name']; Platform = $p['Platform']; Assignments = $p['Assignments']; 'Modified' = $p['Modified']; Proposal = $(if ($ignoreItems) { 'Ignore' } else { 'Recreate' }) })
    }
}
Close-TcRemediationBlock
Export-TcRemediationReport -Name 'equivalent-policies' -Rows @($equivalents) | Out-Null
$decisions = @(Get-TcDecision -Name 'INT-POLICIES' -Proposal @($proposals) -Key 'Tenant', 'Category', 'Name' -Choice 'Recreate', 'Ignore')
$chosenPolicies = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Recreate' })

foreach ($d in $chosenPolicies | Where-Object { (Get-TcMember $_ 'Tenant') -in $c.Tenants }) {
    if (-not $Roots.ContainsKey((Get-TcMember $d 'Category'))) { Write-TcRemediationAlert ("{0} ({1}): category this script cannot copy, to recreate by hand" -f (Get-TcMember $d 'Name'), (Get-TcMember $d 'Category')); continue }
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Name') -Description ("Copy {0} from {1}, with no assignment" -f (Get-TcMember $d 'Name'), (Get-TcMember $d 'Tenant')) -Data @{ Source = (Get-TcMember $d 'Tenant'); Category = (Get-TcMember $d 'Category'); Name = (Get-TcMember $d 'Name') } `
        -Test { param($a) [bool](Find-PolicyRow -Tenant $a.tenant -Category $a.data.Category -Name $a.data.Name) } `
        -Block {
            param($a)
            $p = Find-PolicyRow -Tenant $a.data.Source -Category $a.data.Category -Name $a.data.Name
            if (-not $p) { throw "$($a.data.Name) not found in $($a.data.Source)" }
            $n = switch ($a.data.Category) {
                'Compliance' { Copy-CompliancePolicy -Source $a.data.Source -Policy $p }
                'Configuration' { Copy-ConfigurationPolicy -Source $a.data.Source -Policy $p }
                'Settings catalog' { Copy-CatalogPolicy -Source $a.data.Source -Policy $p }
                default { Copy-AdministrativeTemplate -Source $a.data.Source -Policy $p }
            }
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = ('{0}/{1}' -f (Get-TcMember $Roots[$a.data.Category] 'Uri'), (Get-TcMember $n 'id')) }
        }
}

$assignmentProposals = @($chosenPolicies | Where-Object { $Roots.ContainsKey((Get-TcMember $_ 'Category')) } | ForEach-Object { [ordered]@{ Tenant = (Get-TcMember $_ 'Tenant'); 'Category' = (Get-TcMember $_ 'Category'); Name = (Get-TcMember $_ 'Name'); Platform = (Get-TcMember $_ 'Platform'); Group = $GroupName; Proposal = '' } })
$assignments = @()
if ($assignmentProposals.Count) { $assignments = @(Get-TcDecision -Name 'INT-POLICIES-ASSIGNMENTS' -Proposal $assignmentProposals -Key 'Tenant', 'Category', 'Name' -Choice 'Assign', 'Do not assign' | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Assign' }) }

foreach ($d in $assignments | Where-Object { (Get-TcMember $_ 'Tenant') -in $c.Tenants }) {
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Name') -Description ("Assign {0} to the group of migrated devices" -f (Get-TcMember $d 'Name')) -Data @{ Category = (Get-TcMember $d 'Category'); Name = (Get-TcMember $d 'Name'); Group = $GroupName } `
        -Test {
            param($a)
            $p = Find-PolicyRow -Tenant $a.tenant -Category $a.data.Category -Name $a.data.Name
            if (-not $p) { throw "$($a.data.Name) missing from the target: copy it first" }
            $group = @((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/groups?`$filter=displayName eq '{0}'&`$select=id" -f $a.data.Group)) 'value')) | Select-Object -First 1
            if (-not $group) { throw "Group $($a.data.Group) missing from the target: run DEV-02" }
            $a.data.RootPath = '{0}/{1}' -f (Get-TcMember $Roots[$a.data.Category] 'Uri'), (Get-TcMember $p 'id')
            $a.data.GroupId = (Get-TcMember $group 'id')
            $a.data.ExistingItems = @((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri "$($a.data.RootPath)/assignments") 'value') | ForEach-Object { @{ target = (Get-TcMember $_ 'target') } })
            return [bool]@($a.data.ExistingItems | Where-Object { (Get-TcMember (Get-TcMember $_ 'target') 'groupId') -eq (Get-TcMember $group 'id') }).Count
        } `
        -Block {
            param($a)
            $target = @{ '@odata.type' = '#microsoft.graph.groupAssignmentTarget'; groupId = $a.data.GroupId }
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'POST'; uri = "$($a.data.RootPath)/assign"; body = @{ assignments = @($a.data.ExistingItems) } }
            Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri "$($a.data.RootPath)/assign" -Body @{ assignments = @(@($a.data.ExistingItems) + @(@{ target = $target })) } | Out-Null
        }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $expected = @($chosenPolicies | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and $Roots.ContainsKey((Get-TcMember $_ 'Category')) })
    if (-not $expected.Count) { return }
    $missingOnes = @($expected | Where-Object { -not (Find-PolicyRow -Tenant 'Target' -Category (Get-TcMember $_ 'Category') -Name (Get-TcMember $_ 'Name')) })
    if ($missingOnes.Count) { New-TcRemediationResult Warning ("{0} policy(ies) out of {1} missing from the target" -f $missingOnes.Count, $expected.Count) } else { New-TcRemediationResult OK ("{0} policy(ies) of {1} present in the target" -f $expected.Count, $t) }
}
Close-TcRemediation

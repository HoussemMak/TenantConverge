# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Builds the single list of third-party applications to carry over, with an owner and a time of need (procedure CON-APPLICATIONS).

.DESCRIPTION
    Data read: active third-party service principals, consents and sensitive permissions of each source, then the instance of the
    target. An application present in several sources gives one row: it is consented once in the target.

    decisions\CON-APPLICATIONS.csv: one row per application. Columns to fill: Owner, then Decision among Carry over, Replace or Drop.
    The Carry over proposal only flags an admin consent. The time of need is the cutover of the first source that uses the application.

    This file feeds ENT-APP-PERMISSIONS, ENT-APP-REGISTRATIONS and ENT-THIRD-PARTY-APPS. The script writes to no tenant.
    Limit: identifying SSO and SCIM is not in the snapshot, it is done with the owner.
#>
[void](Open-TcRemediation)

$DecisionFile = 'CON-APPLICATIONS'
$CutoverOrder = @(Get-TcSourceRole)
$CutoverMoment = @{}; foreach ($role in (Get-TcSourceRole)) { $CutoverMoment[$role] = "Cutover of $role" }
$SensitivePermissions = '(?i)(ReadWrite\.All|FullControl|full_access_as_app|Mail\.Send|Mail\.Read|Directory\.ReadWrite|RoleManagement|Application\.ReadWrite|Sites\.Read\.All|Files\.Read\.All|User\.ReadWrite|Exchange\.ManageAsApp)'

$instances = @{}
foreach ($x in Get-TcRemediationTable 'Target' 'servicePrincipals') { $instances[([string]$x['Name']).ToLowerInvariant()] = $x }
$consentedInTarget = @(Get-TcRemediationTable 'Target' 'delegatedConsents' | Where-Object { $_['Consent type'] -like 'Administrator*' } | ForEach-Object { ([string]$_['Application']).ToLowerInvariant() })

$list = [ordered]@{}
foreach ($s in $CutoverOrder) {
    $thirdParty = @(Get-TcRemediationTable $s 'servicePrincipals' | Where-Object { $_['Origin'] -eq 'Third party' -and (ConvertTo-TcBoolean $_['Enabled']) })
    if (-not $thirdParty.Count -and -not (Test-TcCollectionComplete $s 'servicePrincipals')) { Write-TcRemediationAlert ("{0}: service principals: collection incomplete." -f $s) }
    $consented = @{}; foreach ($g in Get-TcRemediationTable $s 'delegatedConsents' | Where-Object { $_['Consent type'] -like 'Administrator*' }) { $consented[([string]$g['Application']).ToLowerInvariant()] = 1 }
    $sensitiveOnes = @{}; foreach ($p in Get-TcRemediationTable $s 'applicationPermissions' | Where-Object { $_['Permission'] -match $SensitivePermissions }) { $k = ([string]$p['Application']).ToLowerInvariant(); $sensitiveOnes[$k] = [int]$sensitiveOnes[$k] + 1 }
    foreach ($x in $thirdParty) {
        $k = ([string]$x['Name']).ToLowerInvariant()
        if (-not $list.Contains($k)) { $list[$k] = @{ Name = $x['Name']; AppId = $x['AppId']; Publisher = $x['Publisher']; Sources = [System.Collections.Generic.List[string]]::new(); Consent = $false; SensitiveOnes = 0 } }
        $list[$k].Sources.Add($s)
        if ($consented[$k]) { $list[$k].Consent = $true }
        $list[$k].SensitiveOnes += [int]$sensitiveOnes[$k]
    }
}

$existingItems = Read-TcDecisionEntry -Name $DecisionFile -Key @('AppId')
$proposals = foreach ($k in $list.Keys) {
    $a = $list[$k]
    $i = $instances[$k]
    $before = $existingItems[([string]$a.AppId).Trim().ToLowerInvariant()]
    [ordered]@{ Application = $a.Name; AppId = $a.AppId; Publisher = $a.Publisher; Sources = ($a.Sources -join ', ')
                'Admin consent' = $(if ($a.Consent) { 'Yes' } else { 'No' }); 'Sensitive permissions' = $a.SensitiveOnes
                'Already in target' = $(if ($i) { 'Yes' } else { 'No' }); 'Active target instance' = $(if ($i) { $(if (ConvertTo-TcBoolean $i['Enabled']) { 'Yes' } else { 'No' }) } else { '' })
                'Target consent' = $(if ($k -in $consentedInTarget) { 'Yes' } else { 'No' }); 'When needed' = $CutoverMoment[$a.Sources[0]]
                Owner = $(if ($before) { (Get-TcMember $before 'Owner') } else { '' }); Proposal = $(if ($a.Consent) { 'Carry over' } else { '' }) }
}

Write-TcRemediationTenant 'Target' 'Single list of applications'
$alreadyThere = @($proposals | Where-Object { (Get-TcMember $_ 'Already in target') -eq 'Yes' }).Count
Write-TcRemediationNote ("{0} distinct third-party application(s) in the sources, including {1} already present in the target" -f $list.Count, $alreadyThere)
foreach ($s in $CutoverOrder) { Write-TcRemediationNote ("{0}: {1} application(s)" -f $s, @($list.Values | Where-Object { $s -in (Get-TcMember $_ 'Sources') }).Count) }
$expectedOne = @(Get-TcRemediationPlanAction -Procedure 'CON-APPLICATIONS' | ForEach-Object { (Get-TcMember $_ 'items') } | Where-Object { $_ }).Count
if ($expectedOne -and $expectedOne -ne $list.Count) { Write-TcRemediationAlert ("The plan has {0} item(s), the list {1}: regenerate the plan after a new snapshot?" -f $expectedOne, $list.Count) }

$decisions = @(Get-TcDecision -Name $DecisionFile -Proposal @($proposals | Where-Object { $_ }) -Key 'AppId' -Choice 'Carry over', 'Replace', 'Drop')
$noOwner = @($proposals | Where-Object { -not (Get-TcMember $_ 'Owner') }).Count
if ($noOwner) { Write-TcRemediationNote ("{0} row(s) without an owner: Owner column of {1}.csv" -f $noOwner, $DecisionFile) }
if ($decisions.Count) {
    Export-TcRemediationReport -Name 'applications-carried-over' -Rows @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Carry over' } | Sort-Object 'When needed' | ForEach-Object {
        [ordered]@{ Application = (Get-TcMember $_ 'Application'); AppId = (Get-TcMember $_ 'AppId'); Sources = (Get-TcMember $_ 'Sources'); 'When needed' = (Get-TcMember $_ 'When needed'); Owner = (Get-TcMember $_ 'Owner') } }) | Out-Null
}

Invoke-TcRemediationPlan
Close-TcRemediation

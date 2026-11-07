# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Adds to the target the chosen third-party applications and carries over their admin consent, on decision (procedure ENT-THIRD-PARTY-APPS).

.DESCRIPTION
    Depends on CON-APPLICATIONS: only the applications marked Carry over in CON-APPLICATIONS.csv are handled.
    Data read: consents of each source and instance of the target.

    decisions\ENT-THIRD-PARTY-APPS.csv: one row per application.
      - Consent (critical): it must work from the first day after cutover; it goes to the report of the go/no-go file;
      - Consent: it is needed later;
      - Postpone: nothing for now;
      - Drop: nothing, to remove from the single list.
    The Scopes column shows what the consent opens: it covers the whole tenant, read it before deciding.

    On decision, the script creates the service principal in the target if missing, then carries over the admin consent of the source,
    limited to the scopes shown. Application permissions go through ENT-APP-PERMISSIONS.

    Limits: SSO, SCIM, assignment to groups and the test with a pilot account are done with the publisher and the owner.
    A single-tenant application of a publisher cannot be added by its AppId: follow its own steps.
#>
$c = Open-TcRemediation

$ApplicationFile = 'CON-APPLICATIONS'
$ConsentChoices = @('Consent (critical)', 'Consent')

function Find-ServicePrincipalId {
    param([string]$Tenant, [string]$AppId)
    $l = @(Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/servicePrincipals?`$filter=appId eq '{0}'&`$select=id,appId" -f $AppId) -All)
    if ($l.Count) { return (Get-TcMember $l[0] 'id') }
    return $null
}

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Third-party applications read'
    $thirdParty = @(Get-TcRemediationTable $t 'servicePrincipals' | Where-Object { $_['Origin'] -eq 'Third party' -and (ConvertTo-TcBoolean $_['Enabled']) })
    $admin = @(Get-TcRemediationTable $t 'delegatedConsents' | Where-Object { $_['Consent type'] -like 'Administrator*' } | ForEach-Object { $_['Application'] } | Sort-Object -Unique)
    Write-TcRemediationNote ("{0} third-party application(s), {1} admin consent(s)" -f $thirdParty.Count, $admin.Count)
}

$applications = if (Test-TcDecisionFile $ApplicationFile) { @(Read-TcDecisionRow $ApplicationFile) } else { @() }
if (-not (Get-TcCount $applications)) { Write-TcRemediationAlert 'The single list does not exist yet: run CON-APPLICATIONS first.' }
$chosenPolicies = @($applications | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Carry over' })
if ((Get-TcCount $applications)) { Write-TcRemediationNote ("{0} application(s) out of {1} marked Carry over in the single list" -f $chosenPolicies.Count, (Get-TcCount $applications)) }

$scopes = @{}
$consentSources = @{}
foreach ($t in @(Get-TcSourceRole)) {
    foreach ($g in Get-TcRemediationTable $t 'delegatedConsents' | Where-Object { $_['Consent type'] -like 'Administrator*' }) {
        $k = ([string]$g['Application']).ToLowerInvariant()
        if (-not $scopes[$k]) { $scopes[$k] = [System.Collections.Generic.HashSet[string]]::new(); $consentSources[$k] = $t }
        foreach ($p in ([string]$g['Scopes'] -split '\s+')) { if ($p) { [void]$scopes[$k].Add($p) } }
    }
}

$proposals = foreach ($a in $chosenPolicies) {
    $k = ([string]$a.Application).ToLowerInvariant()
    [ordered]@{ Application = $a.Application; AppId = $a.AppId; Sources = $a.Sources; 'When needed' = $a.'When needed'; Owner = $a.Owner
                'Already in target' = $a.'Already in target'; 'Consent source' = $consentSources[$k]; Scopes = (@($scopes[$k] | Sort-Object) -join ' '); Proposal = '' }
}
$decisions = @(Get-TcDecision -Name 'ENT-THIRD-PARTY-APPS' -Proposal @($proposals | Where-Object { $_ }) -Key 'AppId' -Choice 'Consent (critical)', 'Consent', 'Postpone', 'Drop')
$toConsent = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -in $ConsentChoices })

foreach ($d in $toConsent) {
    if ((Get-TcMember $d 'Already in target') -ne 'Yes') {
        Add-TcGraphAction -Tenant 'Target' -Method POST -Uri 'v1.0/servicePrincipals' -Body @{ appId = (Get-TcMember $d 'AppId') } -Object (Get-TcMember $d 'Application') -Description ("Add {0} to the enterprise applications of the target" -f (Get-TcMember $d 'Application')) `
            -Test { param($a) [bool](Find-ServicePrincipalId $a.tenant $a.body.appId) }
    }
    if ((Get-TcMember $d 'Scopes') -and (Get-TcMember $d 'Consent source')) {
        Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Application') -Description ("Grant admin consent to {0}: {1}" -f (Get-TcMember $d 'Application'), (Get-TcMember $d 'Scopes')) `
            -Data @{ AppId = (Get-TcMember $d 'AppId'); Source = (Get-TcMember $d 'Consent source'); Scopes = @((Get-TcMember $d 'Scopes') -split ' ' | Where-Object { $_ }) } `
            -Test {
                param($a)
                $id = Find-ServicePrincipalId $a.tenant $a.data.AppId
                if (-not $id) { return $false }
                $granted = @(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/oauth2PermissionGrants?`$filter=clientId eq '{0}'" -f $id) -All | Where-Object { (Get-TcMember $_ 'consentType') -eq 'AllPrincipals' } | ForEach-Object { (Get-TcMember $_ 'scope') -split '\s+' })
                return -not @($a.data.Scopes | Where-Object { $_ -notin $granted }).Count
            } `
            -Block {
                param($a)
                $client = Find-ServicePrincipalId $a.tenant $a.data.AppId
                if (-not $client) { throw "Application missing from the target: $($a.data.AppId)" }
                $undos = [System.Collections.Generic.List[object]]::new()
                $sourceId = Find-ServicePrincipalId $a.data.Source $a.data.AppId
                foreach ($g in @(Invoke-TcGraph -Tenant $a.data.Source -Uri ("v1.0/oauth2PermissionGrants?`$filter=clientId eq '{0}'" -f $sourceId) -All | Where-Object { (Get-TcMember $_ 'consentType') -eq 'AllPrincipals' })) {
                    $result = Invoke-TcGraph -Tenant $a.data.Source -Uri ("v1.0/servicePrincipals/{0}?`$select=appId" -f (Get-TcMember $g 'resourceId'))
                    $resource = Find-ServicePrincipalId $a.tenant (Get-TcMember $result 'appId')
                    if (-not $resource) { Write-TcRemediationAlert ("Resource missing from the target: {0}" -f (Get-TcMember $result 'appId')); continue }
                    $scopes = @((Get-TcMember $g 'scope') -split '\s+' | Where-Object { $_ -and $_ -in $a.data.Scopes })
                    if (-not $scopes.Count) { continue }
                    $existingOne = @(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/oauth2PermissionGrants?`$filter=clientId eq '{0}'" -f $client) -All | Where-Object { (Get-TcMember $_ 'resourceId') -eq $resource -and (Get-TcMember $_ 'consentType') -eq 'AllPrincipals' }) | Select-Object -First 1
                    if ($existingOne) {
                        $undos.Add(@{ type = 'Graph'; tenant = $a.tenant; method = 'PATCH'; uri = "v1.0/oauth2PermissionGrants/$((Get-TcMember $existingOne 'id'))"; body = @{ scope = (Get-TcMember $existingOne 'scope') } })
                        $a.undo = @($undos)
                        Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri "v1.0/oauth2PermissionGrants/$((Get-TcMember $existingOne 'id'))" -Body @{ scope = (@(@((Get-TcMember $existingOne 'scope') -split '\s+') + $scopes | Where-Object { $_ } | Select-Object -Unique) -join ' ') } | Out-Null
                    }
                    else {
                        $n = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri 'v1.0/oauth2PermissionGrants' -Body @{ clientId = $client; consentType = 'AllPrincipals'; resourceId = $resource; scope = ($scopes -join ' ') }
                        $undos.Add(@{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "v1.0/oauth2PermissionGrants/$((Get-TcMember $n 'id'))" })
                        $a.undo = @($undos)
                    }
                }
            }
    }
    Add-TcManualAction -Tenant 'Target' -Object (Get-TcMember $d 'Application') -Description ("Reconfigure and test {0} with the publisher" -f (Get-TcMember $d 'Application')) -Who 'Application owner' `
        -Instruction @(("{0}: ask the publisher for its procedure for a tenant change and its lead time." -f (Get-TcMember $d 'Application')),
                    'Reconfigure SSO and SCIM with the values of the target. Assign the application to the groups of the business unit.',
                    'Validate account matching if the application identifies accounts by UPN or by address.',
                    'Test with a pilot account before the target accounts are opened; record the result in the go/no-go file.')
}

$criticalOnes = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Consent (critical)' })
if ($criticalOnes.Count) { Export-TcRemediationReport -Name 'critical-applications' -Rows @($criticalOnes | ForEach-Object { [ordered]@{ Application = (Get-TcMember $_ 'Application'); AppId = (Get-TcMember $_ 'AppId'); Sources = (Get-TcMember $_ 'Sources'); 'When needed' = (Get-TcMember $_ 'When needed'); Owner = (Get-TcMember $_ 'Owner') } }) | Out-Null }

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne (@($c.Tenants) | Select-Object -First 1)) { return }
    $missingOnes = @($toConsent | Where-Object { -not (Find-ServicePrincipalId 'Target' (Get-TcMember $_ 'AppId')) })
    if ($missingOnes.Count) { New-TcRemediationResult Blocking ("{0} application(s) missing from the target: {1}" -f $missingOnes.Count, (@($missingOnes | ForEach-Object { (Get-TcMember $_ 'Application') }) -join ', ')) }
    else { New-TcRemediationResult OK ("{0} application(s) kept, all present in the target" -f $toConsent.Count) }
}
Close-TcRemediation

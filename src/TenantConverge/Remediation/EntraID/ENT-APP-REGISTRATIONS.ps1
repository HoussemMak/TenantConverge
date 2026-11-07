# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Exports the application registrations of the sources and recreates in the target those the customer keeps (procedure ENT-APP-REGISTRATIONS).

.DESCRIPTION
    Data read: the applications table of each source and, in an -Apply run, the configuration of each registration on the source.
    In an -Apply run, the script first exports the configuration of the sources to exports\registrations-<tenant>.json: URIs, audience,
    allowed APIs, exposed roles. The export holds no secret value, only the count and the end dates.

    decisions\ENT-APP-REGISTRATIONS.csv: one row per registration, Carry over or Drop. The applications of this module are proposed for Drop.

    For a Carry over row, the script creates the registration in the target and its service principal:
      - same name and same redirect URIs, single tenant;
      - only the permissions marked Grant in target in ENT-APP-PERMISSIONS.csv, never a copy of the source;
      - actually assigning these permissions falls to ENT-APP-PERMISSIONS, to run again after a new snapshot.

    Limits: the script creates no secret, because its value must not be written. The owner creates it, stores it in the customer vault
    and updates the configuration of the application: tenant identifier, application identifier, credentials.
    The identifierUris and delegated permissions stay to carry over by hand: the URI often holds the old AppId.
    Deleting the source registrations happens at closure.
#>
$c = Open-TcRemediation

$SelectList = 'id,appId,displayName,signInAudience,web,spa,publicClient,isFallbackPublicClient,identifierUris,requiredResourceAccess,appRoles,api,optionalClaims,passwordCredentials,keyCredentials'
$PermissionFile = 'ENT-APP-PERMISSIONS'
$OwnApps = (Get-TcRemediationOption 'ProtectedApplicationPattern')

function ConvertTo-ExportCopy {
    <# Copy with no sensitive value: only the count and end dates of credentials are kept. #>
    param($App)
    return [ordered]@{ displayName = (Get-TcMember $App 'displayName'); appId = (Get-TcMember $App 'appId'); signInAudience = (Get-TcMember $App 'signInAudience'); web = (Get-TcMember $App 'web'); spa = (Get-TcMember $App 'spa'); publicClient = (Get-TcMember $App 'publicClient')
                       isFallbackPublicClient = (Get-TcMember $App 'isFallbackPublicClient'); identifierUris = (Get-TcMember $App 'identifierUris'); requiredResourceAccess = (Get-TcMember $App 'requiredResourceAccess'); appRoles = (Get-TcMember $App 'appRoles'); api = (Get-TcMember $App 'api'); optionalClaims = (Get-TcMember $App 'optionalClaims')
                       secretItems = @((Get-TcMember $App 'passwordCredentials') | Where-Object { $_ }).Count; certificates = @((Get-TcMember $App 'keyCredentials') | Where-Object { $_ }).Count; credentialEnds = @(@((Get-TcMember $App 'passwordCredentials')) + @((Get-TcMember $App 'keyCredentials')) | Where-Object { $_ } | ForEach-Object { (Get-TcMember $_ 'endDateTime') }) }
}

function Get-KeptAccess {
    <# requiredResourceAccess of the target, built from the review: the resource and the role are resolved on the target by name. #>
    param([string]$Tenant, [object[]]$ChosenPolicies)
    $byResource = @{}
    foreach ($p in @($ChosenPolicies)) {
        $r = @(Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/servicePrincipals?`$filter=displayName eq '{0}'&`$select=appId,appRoles" -f [uri]::EscapeDataString((Get-TcMember $p 'Resource'))) -All) | Select-Object -First 1
        $role = if ($r) { @((Get-TcMember $r 'appRoles') | Where-Object { (Get-TcMember $_ 'value') -eq (Get-TcMember $p 'Permission') }) | Select-Object -First 1 }
        if (-not $role) { Write-TcRemediationAlert ("Permission not found in the target: {0} ({1})" -f (Get-TcMember $p 'Permission'), (Get-TcMember $p 'Resource')); continue }
        if (-not $byResource[(Get-TcMember $r 'appId')]) { $byResource[$r.appId] = [System.Collections.Generic.List[object]]::new() }
        $byResource[(Get-TcMember $r 'appId')].Add(@{ id = (Get-TcMember $role 'id'); type = 'Role' })
    }
    return @($byResource.Keys | ForEach-Object { @{ resourceAppId = $_; resourceAccess = @($byResource[$_]) } })
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Registrations read'
    $rows = @(Get-TcRemediationTable $t 'applications')
    if (-not $rows.Count -and -not (Test-TcCollectionComplete $t 'applications')) { Write-TcRemediationAlert 'Registrations: collection incomplete, an empty table proves nothing.' }
    Write-TcRemediationNote ("{0} app registration(s)" -f $rows.Count)
    foreach ($l in $rows) {
        [ordered]@{ Tenant = $t; Application = $l['Name']; AppId = $l['AppId']; Audience = $l['Audience']; Created = $l['Created']; SecretItems = $l['Secrets']; Certificates = $l['Certificates']
                    Proposal = $(if ($l['Name'] -match $OwnApps) { 'Drop' } else { '' }) }
    }
}
$decisions = @(Get-TcDecision -Name 'ENT-APP-REGISTRATIONS' -Proposal @($proposals | Where-Object { $_ }) -Key 'Tenant', 'AppId' -Choice 'Carry over', 'Drop')

foreach ($t in $c.Tenants) {
    Add-TcBlockAction -Tenant $t -Service Graph -Object 'Configuration export' -Description 'Export the registration configuration, without secret values (read only)' -Reason 'Read only.' -Block {
        param($a)
        $apps = @(Invoke-TcGraph -Tenant $a.tenant -Uri "v1.0/applications?`$select=$SelectList" -All | ForEach-Object { ConvertTo-ExportCopy $_ })
        Write-TcJsonFile (Join-Path $script:TcRemediationRun['Folder'] ("exports/registrations-{0}.json" -f $a.tenant)) $apps
        Write-TcRemediationNote ("{0}: {1} registration(s) exported" -f $a.tenant, $apps.Count)
    }
}

$permissions = if (Test-TcDecisionFile $PermissionFile) { @(Read-TcDecisionRow $PermissionFile) } else { @() }
$carriedOver = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Carry over' })
if ($carriedOver.Count -and -not (Get-TcCount $permissions)) { Write-TcRemediationAlert 'The permission review does not exist: registrations will be created without permissions (ENT-APP-PERMISSIONS).' }
$seen = @{}
foreach ($d in $carriedOver) {
    $k = ((Get-TcText $d 'Application')).ToLowerInvariant()
    if ($seen[$k]) { Write-TcRemediationAlert ("{0} is carried over from several sources: only one registration will be created, from {1}" -f (Get-TcMember $d 'Application'), $seen[$k]); continue }
    $seen[$k] = (Get-TcMember $d 'Tenant')
    $chosenPolicies = @($permissions | Where-Object { (Get-TcMember $_ 'Tenant') -eq (Get-TcMember $d 'Tenant') -and (Get-TcMember $_ 'Application') -eq (Get-TcMember $d 'Application') -and (Get-TcMember $_ 'Decision') -eq 'Grant in target' } | ForEach-Object { @{ Resource = (Get-TcMember $_ 'Resource'); Permission = (Get-TcMember $_ 'Permission') } })
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Application') -Description ("Create the registration {0} in the target, from {1}, with {2} kept permission(s)" -f (Get-TcMember $d 'Application'), (Get-TcMember $d 'Tenant'), $chosenPolicies.Count) `
        -Data @{ Source = (Get-TcMember $d 'Tenant'); AppId = (Get-TcMember $d 'AppId'); Name = (Get-TcMember $d 'Application'); ChosenPolicies = $chosenPolicies } `
        -Test { param($a) [bool]@(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/applications?`$filter=displayName eq '{0}'&`$select=id" -f [uri]::EscapeDataString(($a.data.Name -replace "'", "''"))) -All).Count } `
        -Block {
            param($a)
            $s = Invoke-TcGraph -Tenant $a.data.Source -Uri ("v1.0/applications(appId='{0}')?`$select={1}" -f $a.data.AppId, $SelectList)
            $body = @{ displayName = $a.data.Name; signInAudience = 'AzureADMyOrg'; isFallbackPublicClient = [bool](Get-TcMember $s 'isFallbackPublicClient')
                        requiredResourceAccess = @(Get-KeptAccess $a.tenant $a.data.ChosenPolicies)
                        web = @{ redirectUris = @((Get-TcMember (Get-TcMember $s 'web') 'redirectUris')); logoutUrl = (Get-TcMember (Get-TcMember $s 'web') 'logoutUrl'); homePageUrl = (Get-TcMember (Get-TcMember $s 'web') 'homePageUrl') }
                        spa = @{ redirectUris = @((Get-TcMember (Get-TcMember $s 'spa') 'redirectUris')) }; publicClient = @{ redirectUris = @((Get-TcMember (Get-TcMember $s 'publicClient') 'redirectUris')) } }
            $n = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri 'v1.0/applications' -Body $body
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "v1.0/applications/$((Get-TcMember $n 'id'))" }
            Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri 'v1.0/servicePrincipals' -Body @{ appId = (Get-TcMember $n 'appId') } | Out-Null
            Write-TcRemediationNote ("{0}: new application identifier {1}, to hand over to the owner" -f $a.data.Name, (Get-TcMember $n 'appId'))
        }
    Add-TcManualAction -Tenant 'Target' -Object (Get-TcMember $d 'Application') -Description ("Hand the application {0} over to its owner and test it" -f (Get-TcMember $d 'Application')) -Who 'Application owner' `
        -Instruction @(("{0}: create a certificate or secret in the target, App registrations > Certificates and secrets. Put the value in the customer's vault." -f (Get-TcMember $d 'Application')),
                    'Update the application configuration: tenant identifier, application identifier, credentials. Test before the cutover.',
                    'Compare with exports\registrations-<tenant>.json: identifierUris, exposed roles and delegated permissions.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -eq 'Target') { return }
    foreach ($d in $carriedOver | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t }) {
        $n = @(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/applications?`$filter=displayName eq '{0}'&`$select=appId,signInAudience" -f [uri]::EscapeDataString(((Get-TcMember $d 'Application') -replace "'", "''"))) -All).Count
        if ($n) { New-TcRemediationResult OK ("{0} present in the target" -f (Get-TcMember $d 'Application')) } else { New-TcRemediationResult Blocking ("{0} missing from the target" -f (Get-TcMember $d 'Application')) }
    }
}
Close-TcRemediation

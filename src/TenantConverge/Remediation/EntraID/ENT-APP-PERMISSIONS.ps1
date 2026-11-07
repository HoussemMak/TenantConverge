# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the broad permissions reviewed, then grants or removes them in the target according to the decisions (procedure ENT-APP-PERMISSIONS).

.DESCRIPTION
    Data read: the sensitive permissions of the plan for each tenant, the list CON-APPLICATIONS.csv and the service principals of the
    target. In the target, an application permission covers the whole tenant, including the other business units.

    decisions\ENT-APP-PERMISSIONS.csv: one row per application, resource and permission.
      - row of a source: Grant in target or Do not carry over;
      - row of the target: Keep or Remove.
    An application marked Drop or Replace in CON-APPLICATIONS is proposed as Do not carry over.

    -Apply run: only the written decision counts. A permission to grant needs the application to exist already in the target: run
    ENT-APP-REGISTRATIONS and ENT-THIRD-PARTY-APPS, refresh the snapshot, then run this script again.

    Limits: warning the publisher and confirming that it works stay human steps. Delegated permissions are carried over by
    ENT-THIRD-PARTY-APPS with the admin consent.
#>
$c = Open-TcRemediation

$ApplicationFile = 'CON-APPLICATIONS'
$OwnApps = (Get-TcRemediationOption 'ProtectedApplicationPattern')

function Find-ServicePrincipal {
    <# Service principal by AppId, otherwise by name: a registration recreated in the target keeps its name, not its AppId. #>
    param([string]$Tenant, [string]$AppId, [string]$Name)
    $filters = @(); if ($AppId) { $filters += "appId eq '$AppId'" }; if ($Name) { $filters += "displayName eq '{0}'" -f [uri]::EscapeDataString(($Name -replace "'", "''")) }
    foreach ($f in $filters) {
        $l = @(Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/servicePrincipals?`$filter={0}&`$select=id,appId,displayName,appRoles" -f $f) -All)
        if ($l.Count) { return $l[0] }
    }
    return $null
}

function Find-RoleAssignment {
    <# Returns the client, the resource, the role and the existing assignment; the check before the write and the write share this read. #>
    param($A)
    $d = $A.data
    $client = Find-ServicePrincipal -Tenant $A.tenant -AppId (Get-TcMember $d 'AppId') -Name (Get-TcMember $d 'Application')
    $resource = Find-ServicePrincipal -Tenant $A.tenant -Name (Get-TcMember $d 'Resource')
    $role = if ($resource) { @((Get-TcMember $resource 'appRoles') | Where-Object { (Get-TcMember $_ 'value') -eq (Get-TcMember $d 'Permission') }) | Select-Object -First 1 }
    $att = $null
    if ($client -and $resource -and $role) { $att = @(Invoke-TcGraph -Tenant $A.tenant -Uri ("v1.0/servicePrincipals/{0}/appRoleAssignments" -f (Get-TcMember $client 'id')) -All | Where-Object { (Get-TcMember $_ 'appRoleId') -eq (Get-TcMember $role 'id') -and (Get-TcMember $_ 'resourceId') -eq (Get-TcMember $resource 'id') }) | Select-Object -First 1 }
    return @{ Client = $client; Resource = $resource; Role = $role; Attribution = $att }
}

$applications = if (Test-TcDecisionFile $ApplicationFile) { @(Read-TcDecisionRow $ApplicationFile) } else { @() }
if (-not (Get-TcCount $applications)) { Write-TcRemediationAlert 'The single list does not exist yet: run CON-APPLICATIONS first. The proposals do not take it into account.' }
$appDecision = @{}; foreach ($l in $applications) { $appDecision[((Get-TcText $l 'Application')).ToLowerInvariant()] = $l }

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Sensitive permissions read'
    $items = @(Get-TcRemediationPlanAction -Procedure 'ENT-APP-PERMISSIONS' -Tenant $t | ForEach-Object { (Get-TcMember $_ 'items') } | Where-Object { $_ })
    Write-TcRemediationNote ("{0} sensitive permission(s)" -f $items.Count)
    $principals = @{}; foreach ($x in Get-TcRemediationTable $t 'servicePrincipals') { $principals[([string]$x['Name']).ToLowerInvariant()] = $x }
    foreach ($e in $items) {
        if ([string]$e -notmatch '^(?<a>.*) - (?<r>.+?) - (?<p>.+)$') { Write-TcRemediationAlert "Unreadable plan item: $e"; continue }
        $name = $Matches['a']; $result = $Matches['r']; $permissionRow = $Matches['p']
        $k = $name.ToLowerInvariant()
        $app = $appDecision[$k]
        $appChoice = if ($app) { (Get-TcText $app 'Decision') } else { '' }
        $prop = if ($t -eq 'Target') { $(if ($name -match $OwnApps) { 'Keep' } else { '' }) } elseif ($name -match $OwnApps -or $appChoice -in 'Drop', 'Replace') { 'Do not carry over' } else { '' }
        [ordered]@{ Tenant = $t; Application = $name; AppId = $(if ($principals[$k]) { $principals[$k]['AppId'] }); Resource = $result; Permission = $permissionRow; 'Application decision' = $appChoice; Proposal = $prop }
    }
}

$decisions = @(Get-TcDecision -Name 'ENT-APP-PERMISSIONS' -Proposal @($proposals | Where-Object { $_ }) -Key 'Tenant', 'Application', 'Resource', 'Permission' -Choice 'Grant in target', 'Do not carry over', 'Keep', 'Remove')

$inTargetTenant = @{}; foreach ($x in Get-TcRemediationTable 'Target' 'servicePrincipals') { $inTargetTenant[([string]$x['AppId']).ToLowerInvariant()] = 1; $inTargetTenant[([string]$x['Name']).ToLowerInvariant()] = 1 }
$seen = @{}
foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Grant in target' -and (Get-TcMember $_ 'Tenant') -ne 'Target' }) {
    $k = ('{0}|{1}|{2}' -f (Get-TcMember $d 'Application'), (Get-TcMember $d 'Resource'), (Get-TcMember $d 'Permission')).ToLowerInvariant()
    if ($seen[$k]) { continue }
    $seen[$k] = 1
    $appChoice = if ($appDecision[((Get-TcText $d 'Application')).ToLowerInvariant()]) { (Get-TcText ($appDecision[((Get-TcText $d 'Application')).ToLowerInvariant()]) 'Decision') } else { '' }
    if ($appChoice -in 'Drop', 'Replace') { Write-TcRemediationAlert ("{0}: decision '{1}' in the single list, the permission {2} is not granted" -f (Get-TcMember $d 'Application'), $appChoice, (Get-TcMember $d 'Permission')); continue }
    if (-not ($inTargetTenant[((Get-TcText $d 'AppId')).ToLowerInvariant()] -or $inTargetTenant[((Get-TcText $d 'Application')).ToLowerInvariant()])) {
        Write-TcRemediationAlert ("{0} is not yet in the target: {1} waits for ENT-APP-REGISTRATIONS or ENT-THIRD-PARTY-APPS, then a new snapshot" -f (Get-TcMember $d 'Application'), (Get-TcMember $d 'Permission')); continue
    }
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Application') -Description ("Grant {0} ({1}) to {2}" -f (Get-TcMember $d 'Permission'), (Get-TcMember $d 'Resource'), (Get-TcMember $d 'Application')) `
        -Data @{ Application = (Get-TcMember $d 'Application'); AppId = (Get-TcMember $d 'AppId'); Resource = (Get-TcMember $d 'Resource'); Permission = (Get-TcMember $d 'Permission') } `
        -Test { param($a) [bool](Get-TcMember (Find-RoleAssignment $a) 'Attribution') } `
        -Block {
            param($a)
            $x = Find-RoleAssignment $a
            if (-not (Get-TcMember $x 'Client')) { throw "Application missing from the target: $($a.data.Application)" }
            if (-not (Get-TcMember $x 'Role')) { throw "Permission not found on the resource: $($a.data.Permission)" }
            $uri = "v1.0/servicePrincipals/$((Get-TcMember (Get-TcMember $x 'Resource') 'id'))/appRoleAssignedTo"
            $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri $uri -Body @{ principalId = (Get-TcMember (Get-TcMember $x 'Client') 'id'); resourceId = (Get-TcMember (Get-TcMember $x 'Resource') 'id'); appRoleId = (Get-TcMember (Get-TcMember $x 'Role') 'id') }
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "$uri/$((Get-TcMember $r 'id'))" }
        }
}

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Remove' -and (Get-TcMember $_ 'Tenant') -eq 'Target' }) {
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Application') -Description ("Remove {0} ({1}) from {2}" -f (Get-TcMember $d 'Permission'), (Get-TcMember $d 'Resource'), (Get-TcMember $d 'Application')) `
        -Data @{ Application = (Get-TcMember $d 'Application'); AppId = (Get-TcMember $d 'AppId'); Resource = (Get-TcMember $d 'Resource'); Permission = (Get-TcMember $d 'Permission') } `
        -Test { param($a) -not (Get-TcMember (Find-RoleAssignment $a) 'Attribution') } `
        -Block {
            param($a)
            $x = Find-RoleAssignment $a
            $uri = "v1.0/servicePrincipals/$((Get-TcMember (Get-TcMember $x 'Resource') 'id'))/appRoleAssignedTo"
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'POST'; uri = $uri; body = @{ principalId = (Get-TcMember (Get-TcMember $x 'Client') 'id'); resourceId = (Get-TcMember (Get-TcMember $x 'Resource') 'id'); appRoleId = (Get-TcMember (Get-TcMember $x 'Role') 'id') } }
            Invoke-TcGraph -Tenant $a.tenant -Method DELETE -Uri "$uri/$((Get-TcMember (Get-TcMember $x 'Attribution') 'id'))"
        }
}

$granted = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Grant in target' -and (Get-TcMember $_ 'Tenant') -ne 'Target' })
$toWarn = @($granted | Group-Object Application)
if ($toWarn.Count) {
    Export-TcRemediationReport -Name 'publishers-to-notify' -Rows @($toWarn | ForEach-Object { [ordered]@{ Application = (Get-TcMember $_ 'Name'); Sources = (@((Get-TcMember $_ 'Group') | ForEach-Object { (Get-TcMember $_ 'Tenant') } | Sort-Object -Unique) -join ', '); Permissions = (@((Get-TcMember $_ 'Group') | ForEach-Object { '{0} ({1})' -f (Get-TcMember $_ 'Permission'), (Get-TcMember $_ 'Resource') } | Sort-Object -Unique) -join ' ; ') } }) | Out-Null
    Add-TcManualAction -Tenant 'Target' -Object 'Publishers' -Description ("Notify the publishers of the {0} carried-over application(s) and get their procedure" -f $toWarn.Count) -Who 'Application owner' `
        -Instruction @('Backup, SOC and archiving first: an application that is not carried over leaves a protection gap from the cutover on.', 'List: exports\publishers-to-notify.csv in the log folder.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $expected = @($granted | Select-Object Application, AppId, Resource, Permission -Unique)
    $missingItems = @($expected | Where-Object { -not (Get-TcMember (Find-RoleAssignment @{ tenant = 'Target'; data = @{ Application = (Get-TcMember $_ 'Application'); AppId = (Get-TcMember $_ 'AppId'); Resource = (Get-TcMember $_ 'Resource'); Permission = (Get-TcMember $_ 'Permission') } }) 'Attribution') })
    $extra = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Remove' -and (Get-TcMember $_ 'Tenant') -eq 'Target' } | Where-Object { (Get-TcMember (Find-RoleAssignment @{ tenant = 'Target'; data = @{ Application = (Get-TcMember $_ 'Application'); AppId = (Get-TcMember $_ 'AppId'); Resource = (Get-TcMember $_ 'Resource'); Permission = (Get-TcMember $_ 'Permission') } }) 'Attribution') })
    New-TcRemediationResult $(if ($missingItems.Count -or $extra.Count) { 'Warning' } else { 'OK' }) ("{0} permission(s) kept: {1} missing; {2} to remove still present" -f $expected.Count, $missingItems.Count, $extra.Count)
}
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Restricts invitations and application registration in each tenant (procedure ENT-AUTHORIZATION).

.DESCRIPTION
    Starts from the state in the snapshot: only the settings that differ from the goal become proposals.
    Goal: invitations limited to members, application registration reserved for administrators.
    Decision: decisions\ENT-AUTHORIZATION.csv, one row per tenant and setting, Apply or Keep. With no decision, nothing is planned.
    Migrated accounts lose the right to invite: announce it. Assigning the Application Developer role to those who must keep it
    stays a customer decision and comes before the cut.
#>
$c = Open-TcRemediation

$Uri = 'v1.0/policies/authorizationPolicy'
$TargetInvitations = 'adminsGuestInvitersAndAllMembers'
$AcceptedInTarget = @('adminsGuestInvitersAndAllMembers', 'adminsAndGuestInviters', 'none')

$proposals = [System.Collections.Generic.List[object]]::new()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $invitations = [string](Get-TcRemediationValue $t 'securitySettings' 'Invitations allowed from')
    $createApps = ConvertTo-TcBoolean (Get-TcRemediationValue $t 'securitySettings' 'User permissions.allowedToCreateApps')
    Write-TcRemediationNote ("Read: invitations from '{0}', application registration by users: {1}" -f $invitations, $(if ($createApps) { 'yes' } else { 'no' }))

    if ($invitations -notin $AcceptedInTarget) { $proposals.Add([ordered]@{ Tenant = $t; Setting = 'Invitations'; 'Current value' = $invitations; Proposal = 'Apply' }) }
    if ($createApps) { $proposals.Add([ordered]@{ Tenant = $t; Setting = 'Application registration'; 'Current value' = 'Open to users'; Proposal = 'Apply' }) }
}
$decisions = @(Get-TcDecision -Name 'ENT-AUTHORIZATION' -Proposal @($proposals) -Key 'Tenant', 'Setting' -Choice 'Apply', 'Keep')
$chosen = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Apply' })

foreach ($d in $chosen) {
    $t = (Get-TcMember $d 'Tenant')
    if ((Get-TcMember $d 'Setting') -eq 'Invitations') {
        Add-TcGraphAction -Tenant $t -Method PATCH -Uri $Uri -Body @{ allowInvitesFrom = $TargetInvitations } -Object 'Invitations' `
            -Description "Limit invitations to members and administrators" `
            -Test { param($a) (Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri 'v1.0/policies/authorizationPolicy') 'allowInvitesFrom') -in 'adminsGuestInvitersAndAllMembers', 'adminsAndGuestInviters', 'none' }
    }
    else {
        Add-TcGraphAction -Tenant $t -Method PATCH -Uri $Uri -Body @{ defaultUserRolePermissions = @{ allowedToCreateApps = $false } } -Object 'Application registration' `
            -Description "Reserve application registration to administrators" `
            -Test { param($a) -not (Get-TcMember (Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri 'v1.0/policies/authorizationPolicy') 'defaultUserRolePermissions') 'allowedToCreateApps') } `
            -Undo @{ type = 'Graph'; tenant = $t; method = 'PATCH'; uri = $Uri; body = @{ defaultUserRolePermissions = @{ allowedToCreateApps = $true } } }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $settings = @($chosen | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | ForEach-Object { (Get-TcMember $_ 'Setting') })
    if (-not $settings.Count) { return }
    $p = Invoke-TcGraph -Tenant $t -Uri 'v1.0/policies/authorizationPolicy'
    if ('Invitations' -notin $settings) { }
    elseif ((Get-TcMember $p 'allowInvitesFrom') -in $AcceptedInTarget) { New-TcRemediationResult OK "invitations: $((Get-TcMember $p 'allowInvitesFrom'))" } else { New-TcRemediationResult Blocking "invitations still open: $((Get-TcMember $p 'allowInvitesFrom'))" }
    if ('Application registration' -notin $settings) { }
    elseif ((Get-TcMember (Get-TcMember $p 'defaultUserRolePermissions') 'allowedToCreateApps')) { New-TcRemediationResult Blocking 'users can still register applications' } else { New-TcRemediationResult OK 'application registration reserved to administrators' }
}
Close-TcRemediation

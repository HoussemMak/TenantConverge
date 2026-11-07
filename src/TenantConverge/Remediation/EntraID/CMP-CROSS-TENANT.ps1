# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Creates, in the target and in each source, the partner configuration of the other tenant for the time of the migration (procedure CMP-CROSS-TENANT).

.DESCRIPTION
    For each source, two configurations: the source partner in the target, and the target in the source. Each trusts inbound MFA and
    turns on automatic redemption of invitations, inbound and outbound. The default settings are not touched.
    An existing configuration is only completed if the snapshot already shows it; a conflict error means the snapshot is out of date.

    Decision: decisions\CMP-CROSS-TENANT.csv, one row per source, Trust or Skip. It changes the security posture of a source in
    production: with no decision, nothing is planned.

    The script reports a source with no MFA policy for all (handle ENT-MFA first) and B2B collaboration blocked by default.
    A test with an account of the source stays to be done by a person.
    Closure: removal goes through Undo-TcRemediation on this run, or by deleting the partner configuration.
#>
$c = Open-TcRemediation

$PartnerUri = 'v1.0/policies/crossTenantAccessPolicy/partners'
$SettingRows = @{ inboundTrust = @{ isMfaAccepted = $true }; automaticUserConsentSettings = @{ inboundAllowed = $true; outboundAllowed = $true } }
$targetId = (Get-TcMember (Get-TcRemediationTenant 'Target') 'TenantId')

function Get-Partner {
    param([string]$Tenant, [string]$Partner)
    return (@(Invoke-TcGraph -Tenant $Tenant -Uri $PartnerUri -All) | Where-Object { (Get-TcMember $_ 'tenantId') -eq $Partner } | Select-Object -First 1)
}

function Test-PartnerPresent {
    param([string]$Tenant, [string]$Partner)
    $p = Get-Partner $Tenant $Partner
    return [bool]($p -and (Get-TcMember (Get-TcMember $p 'inboundTrust') 'isMfaAccepted') -and (Get-TcMember (Get-TcMember $p 'automaticUserConsentSettings') 'inboundAllowed') -and (Get-TcMember (Get-TcMember $p 'automaticUserConsentSettings') 'outboundAllowed'))
}

function Add-PartnerAction {
    <# POST if the tenant does not have this partner, PATCH otherwise; POST returns no id, so the undo is written here. #>
    param([string]$Tenant, [string]$Partner, [string]$Name)
    $exists = @(Get-TcRemediationTable $Tenant 'crossTenantPartners' | Where-Object { $_['Tenant'] -eq $Partner }).Count
    $uri = "$PartnerUri/$Partner"
    if ($exists) {
        Add-TcGraphAction -Tenant $Tenant -Method PATCH -Uri $uri -Body $SettingRows -Object "Partner $Name" -Description ("{0}: complete the partner configuration of {1}" -f $Tenant, $Name) `
            -Test { param($a) Test-PartnerPresent $a.tenant ($a.uri -replace '^.*/', '') }
    }
    else {
        Add-TcGraphAction -Tenant $Tenant -Method POST -Uri $PartnerUri -Body (@{ tenantId = $Partner } + $SettingRows) -Object "Partner $Name" -Description ("{0}: create the partner configuration of {1}" -f $Tenant, $Name) `
            -Test { param($a) Test-PartnerPresent $a.tenant $a.body.tenantId } `
            -Undo @{ type = 'Graph'; tenant = $Tenant; method = 'DELETE'; uri = $uri }
    }
}

$proposals = @(foreach ($t in $c.Tenants) {
    $mfa = @(Get-TcRemediationTable $t 'conditionalAccess' | Where-Object { $_['State'] -eq 'enabled' -and (ConvertTo-TcBoolean $_['MFA for all']) }).Count
    [ordered]@{ Tenant = $t; Name = (Get-TcMember (Get-TcRemediationTenant $t) 'Name'); 'MFA for everyone' = $(if ($mfa) { 'Yes' } else { 'No' }); Proposal = 'Trust' }
})
$decisions = @(Get-TcDecision -Name 'CMP-CROSS-TENANT' -Proposal $proposals -Key 'Tenant' -Choice 'Trust', 'Skip')
$trusted = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Trust' } | ForEach-Object { (Get-TcMember $_ 'Tenant') })

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $mfa = @(Get-TcRemediationTable $t 'conditionalAccess' | Where-Object { $_['State'] -eq 'enabled' -and (ConvertTo-TcBoolean $_['MFA for all']) }).Count
    if (-not $mfa) { Write-TcRemediationAlert ("{0}: no active policy requires MFA for everyone; trusting its MFA means trusting its level of protection: handle ENT-MFA first" -f $t) }
    foreach ($x in @(@{ Tenant = 'Target'; Direction = 'b2bCollaborationInbound' }, @{ Tenant = $t; Direction = 'b2bCollaborationOutbound' })) {
        $value = Get-TcRemediationValue (Get-TcMember $x 'Tenant') 'crossTenantSettings' ("Default.{0}.usersAndGroups.accessType" -f (Get-TcMember $x 'Direction'))
        if ($value -and $value -ne 'allowed') { Write-TcRemediationAlert ("{0}: {1} is {2} by default, open B2B collaboration in the partner configuration" -f (Get-TcMember $x 'Tenant'), (Get-TcMember $x 'Direction'), $value) }
    }
    Write-TcRemediationNote ("Partner configurations read: {0} in {1}, {2} in the target" -f @(Get-TcRemediationTable $t 'crossTenantPartners').Count, $t, @(Get-TcRemediationTable 'Target' 'crossTenantPartners').Count)
    if ($t -notin $trusted) { continue }
    Add-PartnerAction -Tenant 'Target' -Partner (Get-TcMember $i 'TenantId') -Name (Get-TcMember $i 'Name')
    Add-PartnerAction -Tenant $t -Partner $targetId -Name 'Target'
    Add-TcManualAction -Tenant $t -Object 'Access test' -Description ("Test the access of an account of {0} to a resource of the target" -f $t) `
        -Instruction @('With a source account, open a test team or site of the target: no consent prompt, no second MFA.', 'Automatic redemption only works if both tenants have enabled it.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -notin $trusted) { return }
    $i = Get-TcRemediationTenant $t
    if (Test-PartnerPresent 'Target' (Get-TcMember $i 'TenantId')) { New-TcRemediationResult OK 'partner configuration present in the target' } else { New-TcRemediationResult Blocking 'partner configuration missing or incomplete in the target' }
    if (Test-PartnerPresent $t $targetId) { New-TcRemediationResult OK 'configuration of the target present in the source' } else { New-TcRemediationResult Blocking 'configuration of the target missing or incomplete in the source' }
}
Close-TcRemediation

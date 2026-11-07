# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Shares free/busy between the target and each source during the migration (procedure CMP-FREE-BUSY).

.DESCRIPTION
    Goes through the Microsoft 365 cross-tenant access policy, not an organization relationship: Microsoft replaces it for this sharing,
    because it depends on EWS, which is turned off in Exchange Online between October 2026 and April 2027.

    The policy is inbound: each tenant allows the other. For each source, in the target and in the source:
      1. Microsoft 365 trust on the partner configuration created by CMP-CROSS-TENANT;
      2. calendar availability capability for this partner;
      3. active organization relationship to the other tenant turned off, because it takes priority over the capability.
    Turning it off waits until the capability is in place: a relationship is never cut before its replacement is there.

    Decision: decisions\CMP-FREE-BUSY.csv, one row per source.
      AvailabilityOnly or LimitedDetails: sets up this sharing, at this level;
      Remove                            : removes the capabilities and relationships, at closure;
      None                              : does nothing.
    LimitedDetails exposes the subject and location of meetings: the customer must validate it.

    Limits: Microsoft rolls this policy out tenant by tenant. If the API does not answer, the action is postponed and the script ends
    with code 1. A capability already present at another level is not changed: the check reports it. The test with the scheduling
    assistant stays to be done by a person.
#>
$c = Open-TcRemediation

$PartnerUri = 'v1.0/policies/crossTenantAccessPolicy/partners'
$Capabilities = [ordered]@{ AvailabilityOnly = 'crossTenantCalendarAvailabilityBasic'; LimitedDetails = 'crossTenantCalendarAvailabilityLimitedDetails' }
$Trust = @{ m365CollaborationInbound = @{ users = @{ accessType = 'allowed'; targets = @(@{ target = 'AllUsers'; targetType = 'user' }) } } }
$Scope = @{ included = @(@{ resourceId = 'All'; resourceType = 'user' }); excluded = @() }
$targetId = (Get-TcMember (Get-TcRemediationTenant 'Target') 'TenantId')
$TargetDomains = @(Get-TcRemediationTable 'Target' 'domains' | Where-Object { (ConvertTo-TcBoolean $_['Verified']) -and $_['Services'] -match '\bEmail\b' } | ForEach-Object { $_['Domain'] })

function Get-PartnerUri { param([string]$Uri) return ($Uri -replace '^.*/partners/([^/]+).*$', '$1') }

function Get-Partner {
    <# Partner configuration, or $null if it does not exist: the direct GET returns an error in that case. #>
    param([string]$Tenant, [string]$Partner)
    if (-not @(Invoke-TcGraph -Tenant $Tenant -Uri $PartnerUri -All | Where-Object { (Get-TcMember $_ 'tenantId') -eq $Partner }).Count) { return $null }
    return (Invoke-TcGraph -Tenant $Tenant -Uri "$PartnerUri/$Partner")
}

function Get-PartnerCapability {
    <# Capability allowed for this partner, or $null. #>
    param([string]$Tenant, [string]$Partner, [string]$Name)
    return (@(Invoke-TcGraph -Tenant $Tenant -Uri "$PartnerUri/$Partner/m365Capabilities" -All) | Where-Object { (Get-TcMember $_ 'name') -eq $Name -and (Get-TcMember (Get-TcMember $_ 'inboundAccess') 'isAllowed') } | Select-Object -First 1)
}

function Get-Relationship {
    param([string]$Tenant, [string]$Name)
    return (Invoke-TcServiceCommand -Tenant $Tenant -Service Exo -Command 'Get-OrganizationRelationship' | Where-Object Name -eq $Name | Select-Object -First 1)
}

function Get-RelationshipTo {
    <# Active relationships of this tenant that share free/busy with these domains, according to the snapshot. #>
    param([string]$Tenant, [string[]]$Domains)
    return @(Get-TcRemediationTable $Tenant 'organizationRelationships' | Where-Object { (ConvertTo-TcBoolean $_['Enabled']) -and (ConvertTo-TcBoolean $_['Free/busy']) -and @([string]$_['Domains'] -split ';\s*' | Where-Object { $_ -in $Domains }).Count })
}

function Get-PairList {
    <# Both directions of a source: the policy is inbound, each tenant allows the other. #>
    param([string]$Source)
    $i = Get-TcRemediationTenant $Source
    return @(
        @{ Tenant = 'Target'; Partner = (Get-TcMember $i 'TenantId'); Name = (Get-TcMember $i 'Name'); Relationships = @(Get-RelationshipTo 'Target' (@((Get-TcMember $i 'InitialDomain')) + @((Get-TcMember $i 'Domains')))) }
        @{ Tenant = $Source; Partner = $targetId; Name = 'Target'; Relationships = @(Get-RelationshipTo $Source $TargetDomains) })
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $relationships = @(Get-PairList $t | ForEach-Object { (Get-TcMember $_ 'Relationships') })
    if ($relationships.Count) { Write-TcRemediationAlert ("{0} organization relationship(s) to replace: they depend on EWS and take priority over the cross-tenant policy" -f $relationships.Count) }
    Write-TcRemediationNote ("{0} active relationship(s) between {1} and the target" -f $relationships.Count, $t)
    $level = @($relationships | ForEach-Object { [string]$_['Level'] } | Where-Object { $_ -in $Capabilities.Keys } | Select-Object -First 1)
    [ordered]@{ Tenant = $t; 'Source domains' = (@((Get-TcMember $i 'InitialDomain')) + @((Get-TcMember $i 'Domains'))) -join ', '; 'Target domains' = $TargetDomains -join ', '
                'Relationships to replace' = @($relationships | ForEach-Object { [string]$_['Name'] } | Select-Object -Unique) -join ', '; Proposal = $(if ($level.Count) { $level[0] } else { 'AvailabilityOnly' }) }
}

$decisions = @(Get-TcDecision -Name 'CMP-FREE-BUSY' -Proposal @($proposals) -Key 'Tenant' -Choice 'AvailabilityOnly', 'LimitedDetails', 'Remove', 'None')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -in $c.Tenants -and (Get-TcMember $_ 'Decision') -ne 'None' }) {
    $t = (Get-TcMember $d 'Tenant')
    foreach ($p in Get-PairList $t) {
        $base = "$PartnerUri/$((Get-TcMember $p 'Partner'))"
        if ((Get-TcMember $d 'Decision') -eq 'Remove') {
            foreach ($name in $Capabilities.Values) {
                Add-TcGraphAction -Tenant (Get-TcMember $p 'Tenant') -Method DELETE -Uri "$base/m365Capabilities/$name" -Object "$name $((Get-TcMember $p 'Name'))" -Description ("{0}: remove the capability {1} from {2}" -f (Get-TcMember $p 'Tenant'), $name, (Get-TcMember $p 'Name')) `
                    -Test { param($a) -not (Get-PartnerCapability $a.tenant (Get-PartnerUri $a.uri) ($a.uri -replace '^.*/', '')) } `
                    -Undo $null -Reason 'Recreate with this script if sharing needs to come back.'
            }
            foreach ($r in (Get-TcMember $p 'Relationships')) {
                Add-TcCommandAction -Tenant (Get-TcMember $p 'Tenant') -Service Exo -Command 'Remove-OrganizationRelationship' -Parameters @{ Identity = [string]$r['Name'] } -Object ([string]$r['Name']) `
                    -Description ("Remove the organization relationship '{0}' from {1}" -f $r['Name'], (Get-TcMember $p 'Tenant')) `
                    -Test { param($a) -not (Get-Relationship $a.tenant $a.parameters.Identity) } `
                    -Reason 'Relationship already replaced by the cross-tenant policy.'
            }
            continue
        }

        $capability = $Capabilities[(Get-TcMember $d 'Decision')]
        Add-TcGraphAction -Tenant (Get-TcMember $p 'Tenant') -Method PATCH -Uri $base -Body $Trust -Object "Trust $((Get-TcMember $p 'Name'))" -Description ("{0}: open Microsoft 365 trust to {1}" -f (Get-TcMember $p 'Tenant'), (Get-TcMember $p 'Name')) `
            -Test {
                param($a)
                $x = Get-Partner $a.tenant (Get-PartnerUri $a.uri)
                if (-not $x) { return (Test-TcPostponed $a 'partner configuration missing: run CMP-CROSS-TENANT') }
                return ((Get-TcMember (Get-TcMember (Get-TcMember $x 'm365CollaborationInbound') 'users') 'accessType') -eq 'allowed')
            }
        Add-TcGraphAction -Tenant (Get-TcMember $p 'Tenant') -Method POST -Uri "$base/m365Capabilities" -Body @{ '@odata.type' = "#microsoft.graph.$capability"; inboundAccess = @{ isAllowed = $true; resourceScopes = $Scope } } `
            -Object "$capability $((Get-TcMember $p 'Name'))" -Description ("{0}: allow {1} to read availability, level {2}" -f (Get-TcMember $p 'Tenant'), (Get-TcMember $p 'Name'), (Get-TcMember $d 'Decision')) `
            -Undo @{ type = 'Graph'; tenant = (Get-TcMember $p 'Tenant'); method = 'DELETE'; uri = "$base/m365Capabilities/$capability" } `
            -Test {
                param($a)
                try { return [bool](Get-PartnerCapability $a.tenant (Get-PartnerUri $a.uri) ($a.body.'@odata.type' -replace '^.*\.', '')) }
                catch { return (Test-TcPostponed $a 'Microsoft 365 capabilities unreadable: policy not yet deployed in this tenant, or missing permission') }
            }
        foreach ($r in (Get-TcMember $p 'Relationships')) {
            Add-TcBlockAction -Tenant (Get-TcMember $p 'Tenant') -Service Exo -Object ([string]$r['Name']) -Description ("Disable in {0} the relationship {1}, replaced by the capability" -f (Get-TcMember $p 'Tenant'), $r['Name']) `
                -Data @{ Name = [string]$r['Name']; Partner = (Get-TcMember $p 'Partner'); Capability = $capability } `
                -Undo @{ command = 'Set-OrganizationRelationship'; parameters = @{ Identity = [string]$r['Name']; Enabled = $true } } `
                -Test {
                    param($a)
                    $x = Get-Relationship $a.tenant $a.data.Name
                    if (-not $x -or -not (Get-TcMember $x 'Enabled')) { return $true }
                    if (-not (Get-PartnerCapability $a.tenant $a.data.Partner $a.data.Capability)) { return (Test-TcPostponed $a 'relationship kept: the capability that replaces it is not in place') }
                    return $false
                } `
                -Block { param($a) Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command 'Set-OrganizationRelationship' -Parameters @{ Identity = $a.data.Name; Enabled = $false } }
        }
    }

    if ((Get-TcMember $d 'Decision') -ne 'Remove') {
        Add-TcManualAction -Tenant 'Target' -Object "Test $t" -Description ("Test availability in both directions with {0}" -f $t) `
            -Instruction @(("With a target account and an account of {0}, open the Outlook scheduling assistant." -f $t), 'Each account must see the availability of the other.', 'If it fails, re-enable the relationship with Undo-TcRemediation and read the log again.')
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $d = $decisions | Where-Object Tenant -eq $t | Select-Object -First 1
    if (-not $d -or (Get-TcMember $d 'Decision') -eq 'None') { return }
    foreach ($p in Get-PairList $t) {
        $presentOnes = @($Capabilities.Values | Where-Object { Get-PartnerCapability (Get-TcMember $p 'Tenant') (Get-TcMember $p 'Partner') $_ })
        if ((Get-TcMember $d 'Decision') -eq 'Remove') {
            if ($presentOnes.Count) { New-TcRemediationResult Blocking ("{0}: capability still present for {1}: {2}" -f (Get-TcMember $p 'Tenant'), (Get-TcMember $p 'Name'), ($presentOnes -join ', ')) } else { New-TcRemediationResult OK ("{0}: no capability for {1}" -f (Get-TcMember $p 'Tenant'), (Get-TcMember $p 'Name')) }
            continue
        }
        $wantedItem = $Capabilities[(Get-TcMember $d 'Decision')]
        if ($wantedItem -in $presentOnes) { New-TcRemediationResult OK ("{0}: {1} allowed, level {2}" -f (Get-TcMember $p 'Tenant'), (Get-TcMember $p 'Name'), (Get-TcMember $d 'Decision')) }
        elseif ($presentOnes.Count) { New-TcRemediationResult Warning ("{0}: {1} has {2}, the decision is {3}" -f (Get-TcMember $p 'Tenant'), (Get-TcMember $p 'Name'), ($presentOnes -join ', '), (Get-TcMember $d 'Decision')) }
        else { New-TcRemediationResult Blocking ("{0}: no capability for {1}" -f (Get-TcMember $p 'Tenant'), (Get-TcMember $p 'Name')) }
        foreach ($r in (Get-TcMember $p 'Relationships')) {
            $x = Get-Relationship (Get-TcMember $p 'Tenant') ([string]$r['Name'])
            if ($x -and (Get-TcMember $x 'Enabled')) { New-TcRemediationResult Warning ("{0}: the relationship {1} is still active and takes priority over the capability" -f (Get-TcMember $p 'Tenant'), $r['Name']) }
        }
    }
}
Close-TcRemediation

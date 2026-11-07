# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the sign-in countries validated, then prepares a block by location if the customer wants it (procedure ENT-COUNTRIES).

.DESCRIPTION
    Data read: the countries of recent sign-ins, named locations and conditional access policies read.
    The first preview creates two files:
      - decisions\ENT-COUNTRIES.csv: one country per row, Legitimate or To examine (ENT-RISK for the latter);
      - decisions\ENT-COUNTRIES-BLOCK.csv: one row per tenant, Do not block, Report only or Enable.

    Nothing is created without a decision. Report only creates the location TC - Validated countries and a report-only policy. Enable
    turns this policy on, once the snapshot shows it in report-only.

    Guards of the activation, whatever the decisions:
      - every country has a decision;
      - the emergency accounts exist, are enabled, have a FIDO2 key in the target and are excluded; otherwise the script refuses;
      - the policy reads as report-only, unchanged for at least three days;
      - security defaults are off.
    Emergency accounts and the sync accounts role are excluded from the policy. The exclusion is read back after the activation: if it is
    missing, the policy goes back to report-only.

    The location takes all the countries decided Legitimate in the file, even with no sign-in in the last snapshot. Removing a country
    from an active policy is refused: put it back in report-only first to observe the effect.

    Limit: an address with no known country does not enter the validated location. Report-only mode shows what this would affect.
#>
$c = Open-TcRemediation

$PolicyName = (Get-TcObjectName ' - Block outside validated countries')
$LocationName = (Get-TcObjectName ' - Validated countries')
$LocationUri = 'v1.0/identity/conditionalAccess/namedLocations'
$ReportOnlyState = $script:TcReportOnlyState
$UsualCountries = @(Get-TcRemediationOption 'UsualCountries')





function Get-LocationPolicy {
    param([string]$Tenant)
    return @(Get-TcRemediationTable $Tenant 'conditionalAccess' | Where-Object { $_['Locations'] -and $_['State'] -ne 'disabled' -and $_['Name'] -ne $PolicyName })
}

$countryProposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Countries read'
    $country = @(Get-TcRemediationTable $t 'signInSummary' | Where-Object { $_['Dimension'] -eq 'Country' -and $_['Value'] -ne '(empty)' })
    if (-not $country.Count -and -not (Test-TcCollectionComplete $t 'signInSummary')) { Write-TcRemediationAlert 'Sign-ins: incomplete collection, an empty table proves nothing.' }
    $unusual = @($country | Where-Object { $_['Value'] -notin $UsualCountries })
    Write-TcRemediationNote ("{0} sign-in countries, of which {1} outside the usual countries" -f $country.Count, $unusual.Count)
    $byLocation = @(Get-LocationPolicy $t)
    if ($byLocation.Count) { Write-TcRemediationNote ("{0} location-based policy(ies) already active, {1} report-only: compare before creating another one (list in ENT-COUNTRIES-BLOCK.csv)" -f @($byLocation | Where-Object { $_['State'] -eq 'enabled' }).Count, @($byLocation | Where-Object { $_['State'] -eq $ReportOnlyState }).Count) }
    foreach ($p in $country | Sort-Object { - [int]$_['Sign-ins'] }) {
        [ordered]@{ Tenant = $t; Country = $p['Value']; SignIns = $p['Sign-ins']; Users = $p['Users']; Proposal = $(if ($p['Value'] -in $UsualCountries) { 'Legitimate' } else { '' }) }
    }
}
$countryDecisions = @(Get-TcDecision -Name 'ENT-COUNTRIES' -Proposal @($countryProposals | Where-Object { $_ }) -Key 'Tenant', 'Country' -Choice 'Legitimate', 'To examine')
foreach ($l in $countryDecisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'To examine' }) { Write-TcRemediationNote ("{0}: country {1} to examine (ENT-RISK)" -f (Get-TcMember $l 'Tenant'), (Get-TcMember $l 'Country')) }

$blockProposals = foreach ($t in $c.Tenants) {
    $existingItem = Get-TcRemediationTable $t 'conditionalAccess' | Where-Object { $_['Name'] -eq $PolicyName } | Select-Object -First 1
    [ordered]@{ Tenant = $t; Policy = $PolicyName; 'State read' = $(if ($existingItem) { $existingItem['State'] } else { 'missing' })
                'Existing location-based policies' = (@(Get-LocationPolicy $t | ForEach-Object { '{0} ({1})' -f $_['Name'], $_['State'] }) -join ' ; '); Proposal = 'Do not block' }
}
$blockDecisions = @(Get-TcDecision -Name 'ENT-COUNTRIES-BLOCK' -Proposal @($blockProposals | Where-Object { $_ }) -Key 'Tenant' -Choice 'Do not block', 'Report only', 'Enable')

foreach ($t in $c.Tenants) {
    $d = $blockDecisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | Select-Object -First 1
    if (-not $d -or (Get-TcMember $d 'Decision') -eq 'Do not block') { continue }
    # the file, not the read: a legitimate country with no recent sign-in must not leave the location
    $validItems = @((Read-TcDecisionEntry -Name 'ENT-COUNTRIES' -Key 'Tenant', 'Country').Values | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Legitimate' } | ForEach-Object { (Get-TcMember $_ 'Country') })
    $pending = @($countryProposals | Where-Object { $_ -and (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Country') -notin @($countryDecisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | ForEach-Object { (Get-TcMember $_ 'Country') }) }).Count
    if ($pending) { Write-TcRemediationAlert ("{0}: {1} countries with no decision: block postponed." -f $t, $pending); continue }
    if (-not $validItems.Count) { Write-TcRemediationAlert ("{0}: no legitimate country decided: block postponed." -f $t); continue }
    if (ConvertTo-TcBoolean (Get-TcRemediationValue $t 'securitySettings' 'Security defaults enabled')) { Write-TcRemediationAlert ("{0}: security defaults are enabled: conditional access cannot be enabled." -f $t); continue }

    $missing = @(Get-TcMissingProtectedAccount $t)
    if ($missing.Count) { Write-TcRemediationAlert ("{0}: emergency accounts missing from the snapshot: {1}; enabling will stay refused." -f $t, ($missing -join ', ')) }
    $existingItem = Get-TcRemediationTable $t 'conditionalAccess' | Where-Object { $_['Name'] -eq $PolicyName } | Select-Object -First 1

    Add-TcBlockAction -Tenant $t -Service Graph -Object $LocationName -Description ("Create or update the named location with {0} validated country(ies)" -f $validItems.Count) -Data @{ Country = @($validItems | Sort-Object) } `
        -Test {
            param($a)
            $l = @(Invoke-TcGraph -Tenant $a.tenant -Uri $LocationUri -All | Where-Object { (Get-TcMember $_ 'displayName') -eq $LocationName }) | Select-Object -First 1
            return [bool]($l -and -not (Compare-Object @((Get-TcMember $l 'countriesAndRegions') | Sort-Object) $a.data.Country))
        } `
        -Block {
            param($a)
            $l = @(Invoke-TcGraph -Tenant $a.tenant -Uri $LocationUri -All | Where-Object { (Get-TcMember $_ 'displayName') -eq $LocationName }) | Select-Object -First 1
            $type = '#microsoft.graph.countryNamedLocation'
            if ($l) {
                $removedItems = @((Get-TcMember $l 'countriesAndRegions') | Where-Object { $_ -notin $a.data.Country })
                $s = Get-TcConditionalAccessPolicy $a.tenant $PolicyName
                if ($removedItems.Count -and $s -and (Get-TcMember $s 'state') -eq 'enabled') { throw ("Reduction refused: removing {0} would cut these countries off without observation. Put the policy back in report-only mode, observe, then run again." -f ($removedItems -join ', ')) }
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'PATCH'; uri = "$LocationUri/$((Get-TcMember $l 'id'))"; body = @{ '@odata.type' = $type; countriesAndRegions = @((Get-TcMember $l 'countriesAndRegions')) } }
                Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri "$LocationUri/$((Get-TcMember $l 'id'))" -Body @{ '@odata.type' = $type; countriesAndRegions = $a.data.Country }
            }
            else {
                $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri $LocationUri -Body @{ '@odata.type' = $type; displayName = $LocationName; countriesAndRegions = $a.data.Country; includeUnknownCountriesAndRegions = $false }
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "$LocationUri/$((Get-TcMember $r 'id'))" }
            }
        }

    if (-not $existingItem) {
        Add-TcBlockAction -Tenant $t -Service Graph -Object $PolicyName -Description ("Create policy {0} in report-only mode" -f $PolicyName) `
            -Test { param($a) [bool](Get-TcConditionalAccessPolicy $a.tenant $PolicyName) } `
            -Block {
                param($a)
                $l = @(Invoke-TcGraph -Tenant $a.tenant -Uri $LocationUri -All | Where-Object { (Get-TcMember $_ 'displayName') -eq $LocationName }) | Select-Object -First 1
                if (-not $l) { throw "Location missing: $LocationName" }
                $x = Resolve-TcAccountId $a.tenant @(Get-TcProtectedAccount $a.tenant)
                foreach ($u in (Get-TcMember $x 'Missing')) { Write-TcRemediationAlert ("{0} does not exist yet: to exclude before enabling, the script handles it at that time" -f $u) }
                $body = @{ displayName = $PolicyName; state = $ReportOnlyState
                            conditions = @{ users = @{ includeUsers = @('All'); excludeUsers = @((Get-TcMember $x 'Ids')); excludeRoles = @($script:TcSyncRoleId) }
                                            applications = @{ includeApplications = @('All') }; clientAppTypes = @('all')
                                            locations = @{ includeLocations = @('All'); excludeLocations = @((Get-TcMember $l 'id')) } }
                            grantControls = @{ operator = 'OR'; builtInControls = @('block') } }
                $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri $script:TcPolicyUri -Body $body
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "$script:TcPolicyUri/$((Get-TcMember $r 'id'))" }
            }
    }

    if ((Get-TcMember $d 'Decision') -eq 'Enable') {
        if (-not $existingItem) { Write-TcRemediationAlert ("{0}: enabling decided, but the policy is not yet in the snapshot: create, observe, refresh the snapshot." -f $t) }
        elseif ($missing.Count -or -not @(Get-TcProtectedAccount $t).Count) { Write-TcRemediationAlert ("{0}: enabling blocked: emergency accounts missing." -f $t) }
        elseif ($existingItem['State'] -eq $ReportOnlyState) { Add-TcPolicyActivation -Tenant $t -Name $PolicyName }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $p = Get-TcConditionalAccessPolicy $t $PolicyName
    if (-not $p) { New-TcRemediationResult Info 'no country block policy created by this script'; return }
    New-TcRemediationResult $(if ((Get-TcMember $p 'state') -eq 'enabled') { 'OK' } else { 'Info' }) ("policy {0}: {1}" -f $PolicyName, (Get-TcMember $p 'state'))
    if ($script:TcSyncRoleId -notin @((Get-TcMember (Get-TcMember (Get-TcMember $p 'conditions') 'users') 'excludeRoles'))) { New-TcRemediationResult Blocking 'the role of the sync accounts is not excluded' }
    Get-TcExclusionResult -Tenant $t -Policy $p
}
Close-TcRemediation

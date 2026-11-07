# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Produces the list, order and volumes of the site copy, and the decisions file (procedure SPO-LARGE-SITES).

.DESCRIPTION
    The copy goes through a third-party tool: the script assumes no tool. It gives a CSV ready to use: order (largest to smallest), source
    site, target address (from CON-SITES), volume, running total and largest library.
    decisions\SPO-LARGE-SITES.csv says for each site: Copy, Split by library or Exclude.
    The sites excluded by SPO-INACTIVE are proposed as Exclude. The large site threshold comes from the LargeSiteGb setting.
    In an -Apply run, the script reads the real size of the sites on the source.
    Limit: splitting, incremental passes and measuring the last pass are done in the chosen tool.
#>
$c = Open-TcRemediation

$ThresholdGb = [double](Get-TcRemediationOption 'LargeSiteGb')
$TechnicalSites = '^(SPSMSITEHOST|SRCHCEN|APPCATALOG|POINTPUBLISHING|REDIRECTSITE|TEAMCHANNEL)'

function Read-OtherDecision {
    param([string]$Name)
    $f = $Name
    if (Test-TcDecisionFile $f) { return @(Read-TcDecisionRow $f) }
    return @()
}

$addresses = @{}
foreach ($l in Read-OtherDecision 'CON-SITES.csv') { $addresses[((Get-TcText $l 'Source site')).TrimEnd('/').ToLowerInvariant()] = (Get-TcMember $l 'Target address') }
$excludedItems = @{}
foreach ($l in Read-OtherDecision 'SPO-INACTIVE.csv') { if ((Get-TcMember $l 'Decision') -in 'Read only', 'Archive', 'Delete') { $excludedItems[((Get-TcText $l 'Site')).TrimEnd('/').ToLowerInvariant()] = 1 } }
if (-not $addresses.Count) { Write-TcRemediationAlert 'Target addresses missing: run CON-SITES first (BUILD-04)' }

$proposals = [System.Collections.Generic.List[object]]::new()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    if (-not (Test-TcCollectionComplete $t 'sites')) { Write-TcRemediationAlert 'Incomplete site collection: the list may be partial' }
    $sites = @(Get-TcRemediationTable $t 'sites' | Where-Object { $_['Template'] -notmatch $TechnicalSites } | Sort-Object { - [double]$_['Storage MB'] })
    $large = @($sites | Where-Object { [double]$_['Storage MB'] / 1024 -ge $ThresholdGb })
    $volume = (Get-TcMember (@($sites | ForEach-Object { [double]$_['Storage MB'] }) | Measure-Object -Sum) 'Sum') / 1024
    Write-TcRemediationNote ("{0} site(s), {1:N1} GB, {2} of {3} GB or more" -f $sites.Count, $volume, $large.Count, $ThresholdGb)
    $libraries = @(Get-TcRemediationTable $t 'libraries' | Where-Object { $_['Size MB'] })
    $rank = 0
    $total = 0
    foreach ($s in $sites) {
        $rank++
        $key = ([string]$s['Url']).TrimEnd('/').ToLowerInvariant()
        $go = [math]::Round([double]$s['Storage MB'] / 1024, 1)
        $total += $go
        $b = $libraries | Where-Object { ([string]$_['Site']).TrimEnd('/').ToLowerInvariant() -eq $key } | Sort-Object { - [double]$_['Size MB'] } | Select-Object -First 1
        $isLarge = $go -ge $ThresholdGb
        $proposals.Add([ordered]@{ Tenant = $t; Order = $rank; Site = $s['Url']; 'Target address' = $addresses[$key]; 'Volume GB' = $go; 'Total GB' = [math]::Round($total, 1); 'Large site' = $(if ($isLarge) { 'Yes' } else { 'No' })
                                      'Largest library' = $(if ($b) { '{0} ({1:N0} Mo)' -f $b['List'], [double]$b['Size MB'] } else { '' }); 'Days inactive' = $s['Days inactive']
                                      Proposal = $(if ($excludedItems[$key]) { 'Exclude' } else { 'Copy' }) })
    }
}
$decisions = @(Get-TcDecision -Name 'SPO-LARGE-SITES' -Proposal @($proposals) -Key 'Tenant', 'Site' -Choice 'Copy', 'Split by library', 'Exclude')

$bySite = @{}
foreach ($d in $decisions) { $bySite[('{0}|{1}' -f (Get-TcMember $d 'Tenant'), (Get-TcMember $d 'Site'))] = (Get-TcMember $d 'Decision') }
foreach ($t in $c.Tenants) {
    $copyRows = @($proposals | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | ForEach-Object {
        $l = [pscustomobject]$_
        $l | Add-Member -NotePropertyName 'Decision' -NotePropertyValue ([string]$bySite[('{0}|{1}' -f $t, (Get-TcMember $_ 'Site'))]) -PassThru })
    Export-TcRemediationReport -Name "site-copy-plan-$t" -Rows $copyRows | Out-Null
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $thresholdMb = $ThresholdGb * 1024
    $realOnes = @(Invoke-TcServiceCommand -Tenant $t -Service Pnp -Command 'Get-PnPTenantSite' -Parameters @{ Detailed = $true } | Where-Object { (Get-TcMember $_ 'StorageUsageCurrent') -ge $thresholdMb })
    $plannedItems = @(Get-TcRemediationTable $t 'sites' | Where-Object { [double]$_['Storage MB'] -ge $thresholdMb })
    New-TcRemediationResult Info ("{0} large site(s) read on the source, {1} in the snapshot" -f $realOnes.Count, $plannedItems.Count)
    if ($realOnes.Count -ne $plannedItems.Count) { New-TcRemediationResult Warning 'The number of large sites changed: take a new snapshot before the pre-copy' }
}
Close-TcRemediation

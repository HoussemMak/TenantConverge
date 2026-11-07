# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Gives each site of the sources a prefixed target address, with no duplicate between sources (procedure CON-SITES).

.DESCRIPTION
    Prefixes all the addresses with the prefix of the source, even those not in conflict.
    Sets aside the technical sites that are not copied: host, search, catalog, redirect, publishing and channels (they follow their team).
    Read only: no connection. Writes decisions\CON-SITES.csv, which feeds the mapping plan of the copy tool and that CMP-SITE-URLS,
    SPO-LARGE-SITES and TMS-GUESTS read. The sites excluded by SPO-INACTIVE keep a row there, marked Excluded.
    Limits: the site address of a team follows from the group alias, to coordinate with CON-ALIASES. The rule is validated during the POC.
#>
$c = Open-TcRemediation

$TechnicalSites = '^(SPSMSITEHOST|SRCHCEN|APPCATALOG|POINTPUBLISHING|REDIRECTSITE|TEAMCHANNEL)'
$InactiveFile = 'SPO-INACTIVE'
$excludedItems = @{}
if (Test-TcDecisionFile $InactiveFile) {
    foreach ($l in Read-TcDecisionRow $InactiveFile) { if ((Get-TcMember $l 'Decision') -in 'Read only', 'Archive', 'Delete') { $excludedItems[((Get-TcText $l 'Site')).TrimEnd('/').ToLowerInvariant()] = 1 } }
}

function ConvertTo-TargetSegment {
    <# Last segment of the address, with no accent or space, prefixed once only. #>
    param([string]$Url, [string]$Prefix)
    $pathValue = [uri]::UnescapeDataString(($Url.TrimEnd('/') -replace '^https://[^/]+', ''))
    $segment = ($pathValue -split '/')[-1]
    if (-not $segment) { $segment = 'Root' }
    $segment = (($segment -replace '[\p{Cs}\p{Cn}]', ' ').Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{Mn}', '') -replace '[^A-Za-z0-9_.-]+', '-'
    return ('{0}-{1}' -f $Prefix, ($segment.Trim('-') -ireplace "^$Prefix-", ''))
}

$TargetHost = (Get-TcMember (Get-TcRemediationTenant 'Target') 'InitialDomain') -replace '\.onmicrosoft\.com$', ''
$sources = @($c.Tenants | Where-Object { $_ -ne 'Target' })
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($t in $sources) {
    Write-TcRemediationTenant $t
    if (-not (Test-TcCollectionComplete $t 'sites')) { Write-TcRemediationAlert 'Incomplete site collection: the list may be partial' }
    $i = Get-TcRemediationTenant $t
    $everyone = @(Get-TcRemediationTable $t 'sites')
    $useful = @($everyone | Where-Object { $_['Template'] -notmatch $TechnicalSites })
    Write-TcRemediationNote ("{0} site(s) to copy out of {1} read, prefix {2}-" -f $useful.Count, $everyone.Count, (Get-TcMember $i 'Prefix'))
    foreach ($s in $useful) {
        $segment = ConvertTo-TargetSegment $s['Url'] (Get-TcMember $i 'Prefix')
        $rows.Add([pscustomobject]@{ Tenant = $t; 'Source site' = $s['Url']; Title = $s['Title']; 'Template' = $s['Template']; 'Group site' = $(if ($s['Group']) { 'Yes' } else { 'No' })
                                       'Target address' = ('https://{0}.sharepoint.com/sites/{1}' -f $TargetHost, $segment); Alias = $segment
                                       Excluded = $(if ($excludedItems[([string]$s['Url']).TrimEnd('/').ToLowerInvariant()]) { 'Yes' } else { 'No' }) })
    }
}

$shared = @(Get-TcRemediationPlanAction -Procedure 'CON-SITES' | ForEach-Object { (Get-TcMember $_ 'items') })
if ('Target' -in $c.Tenants) { Write-TcRemediationTenant 'Target' }
Write-TcRemediationNote ("{0} path(s) identical in several sources according to the plan" -f $shared.Count)
$duplicates = @($rows | Group-Object 'Target address' | Where-Object { (Get-TcCount $_) -gt 1 })
foreach ($g in $duplicates) { Write-TcRemediationAlert ("Duplicate target address: {0} ({1})" -f (Get-TcMember $g 'Name'), (((Get-TcMember $g 'Group') | ForEach-Object { (Get-TcMember $_ 'Source site') }) -join ' ; ')) }
if (-not $duplicates.Count) { Write-TcRemediationNote ("No duplicate target address in {0}" -f $rows.Count) }

Export-TcRemediationReport -Name 'site-target-addresses' -Rows @($rows) | Out-Null
$decisionFolder = Get-TcDecisionFolder
New-Item -ItemType Directory -Force -Path $decisionFolder | Out-Null
$stable = Join-Path $decisionFolder 'CON-SITES.csv'
$rows | Export-Csv -LiteralPath $stable -Encoding utf8BOM -NoTypeInformation
Write-TcRemediationNote "File for the copy tool: $stable"

Invoke-TcRemediationPlan
Close-TcRemediation

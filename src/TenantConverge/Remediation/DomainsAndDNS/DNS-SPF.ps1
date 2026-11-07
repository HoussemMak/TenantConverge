# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Publishes an SPF, on decision, for the domains that have none (procedure DNS-SPF).

.DESCRIPTION
    Report spf-<tenant>.csv: SPF read and number of mechanisms with a DNS lookup. Nested includes are not counted: the limit of 10 is
    confirmed with an online tool.

    Decision: decisions\DNS-SPF.csv, one row per domain with no SPF.
      Publish    : SPF that includes Exchange Online.
      No sending : v=spf1 -all, for a domain that sends no email.
      Ignore     : nothing is published.

    An SPF present without Exchange Online is shown, with no action: its legitimate senders are confirmed in a workshop first.

    Domains with an Unknown DNS host are telephony or third-party service domains: their zone does not seem managed by the customer,
    hence the Ignore proposal. The list of legitimate senders is drawn up in a workshop; for migrated domains, the replacement happens
    when the MX, SPF and Autodiscover records move.
#>
$c = Open-TcRemediation

$Microsoft = 'include:spf.protection.outlook.com'
$TokenVariable = [string](Get-TcRemediationOption 'DnsApiTokenVariable')

function Get-NewSpf {
    param([string]$Current, [string]$Choice)
    if ($Choice -eq 'No sending') { return 'v=spf1 -all' }
    if (-not $Current -or $Current -eq 'Missing') { return "v=spf1 $Microsoft -all" }
    if ($Current -match [regex]::Escape($Microsoft)) { return $Current }
    return ($Current -replace '\s+([~\-?+]all)$', " $Microsoft `$1")
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $domains = @(Get-TcRemediationTable $t 'dnsSummary')
    $report = foreach ($e in $domains) {
        $spf = [string]$e['SPF']
        [ordered]@{ Domain = $e['Domain']; 'Host' = $e['DNS host']; SPF = $spf; 'DNS lookup mechanisms' = (Get-TcCount ([regex]::Matches($spf, '(?i)(?<![\w.-])(include:|exists:|redirect=|a(?=[\s:/]|$)|mx(?=[\s:/]|$)|ptr(?=[\s:]|$))'))) }
    }
    [void](Export-TcRemediationReport -Name "spf-$t" -Rows @($report))
    foreach ($r in @($report | Where-Object { $_['DNS lookup mechanisms'] -gt 10 })) { Write-TcRemediationAlert ("{0}: {1} DNS lookup mechanisms for a limit of 10" -f (Get-TcMember $r 'Domain'), $r['DNS lookup mechanisms']) }
    foreach ($g in @(Get-TcRemediationTable $t 'publicDns' | Where-Object { $_['Type'] -eq 'TXT (SPF)' } | Group-Object { $_['Record'] } | Where-Object { (Get-TcCount $_) -gt 1 })) { Write-TcRemediationAlert ("{0}: {1} SPF records published, which invalidates the SPF" -f (Get-TcMember $g 'Name'), (Get-TcCount $g)) }
    $gaps = @($domains | Where-Object { $_['SPF'] -eq 'Missing' })
    Write-TcRemediationNote ("{0} domain(s) out of {1} with no SPF" -f $gaps.Count, $domains.Count)
    $noMicrosoft = @($domains | Where-Object { $_['SPF'] -ne 'Missing' -and -not (ConvertTo-TcBoolean $_['Microsoft SPF']) })
    if ($noMicrosoft.Count) { Write-TcRemediationNote ("{0} domain(s) have an SPF without Exchange Online, outside the finding: to review in a workshop with their senders ({1})" -f $noMicrosoft.Count, (($noMicrosoft | ForEach-Object { $_['Domain'] }) -join ', ')) }
    foreach ($e in $gaps) {
        [ordered]@{ Tenant = $t; Domain = $e['Domain']; 'Host' = $e['DNS host']; 'Current SPF' = $e['SPF']; Proposal = $(if ($e['DNS host'] -eq 'Unknown') { 'Ignore' } else { 'Publish' }) }
    }
}

$decisions = @(Get-TcDecision -Name 'DNS-SPF' -Proposal @($proposals) -Key 'Tenant', 'Domain' -Choice 'Publish', 'No sending', 'Ignore')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -ne 'Ignore' }) {
    if ((Get-TcDnsHost (Get-TcMember $d 'Domain')) -eq 'Cloudflare' -and $c.Apply -and -not [Environment]::GetEnvironmentVariable($TokenVariable)) { Write-TcRemediationAlert ("{0}: Cloudflare token missing (variable {1}), domain skipped" -f (Get-TcMember $d 'Domain'), $TokenVariable); continue }
    $value = Get-NewSpf -Current (Get-TcMember $d 'Current SPF') -Choice (Get-TcMember $d 'Decision')
    Add-TcDnsAction -Tenant (Get-TcMember $d 'Tenant') -Zone (Get-TcMember $d 'Domain') -Name (Get-TcMember $d 'Domain') -Type TXT -Value $value -Action Set -Description ("SPF of {0}: {1}" -f (Get-TcMember $d 'Domain'), $value) `
        -Test { param($a) $spf = @(Resolve-TcDnsEntry -Name $a.dns.name -Type TXT | Where-Object { (Get-TcMember $_ 'value') -like 'v=spf1*' }); (Get-TcCount $spf) -eq 1 -and (Get-TcMember $spf[0] 'value') -eq $a.dns.value }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -ne 'Ignore' }) {
        $n = @(Resolve-TcDnsEntry -Name (Get-TcMember $d 'Domain') -Type TXT | Where-Object { (Get-TcMember $_ 'value') -like 'v=spf1*' }).Count
        if ($n -eq 1) { New-TcRemediationResult OK "$((Get-TcMember $d 'Domain')): single SPF" } else { New-TcRemediationResult Blocking "$((Get-TcMember $d 'Domain')): $n SPF records published" }
    }
}
Close-TcRemediation

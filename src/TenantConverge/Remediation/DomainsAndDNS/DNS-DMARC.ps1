# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Publishes DMARC, then hardens it, domain by domain, on decision (procedure DNS-DMARC).

.DESCRIPTION
    Decision: decisions\DNS-DMARC.csv, one row per domain with no DMARC or at p=none.
      p=none, p=quarantine, p=reject: value to publish; the report address goes in Note.
      Ignore                        : nothing is published.
    p=none is published before the cutover. Hardening is decided only after reading the aggregate reports: run the script again after
    changing the decision. Going up in stages with a partial pct value is done by hand.

    The report address is a customer decision: the script proposes none and skips the row if Note is empty.
    An address outside the domain needs the authorization of the domain that receives it.
    Domains with an Unknown DNS host are telephony or third-party service domains, hence the Ignore proposal.
#>
$c = Open-TcRemediation

$TokenVariable = [string](Get-TcRemediationOption 'DnsApiTokenVariable')

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $gaps = @(Get-TcRemediationTable $t 'dnsSummary' | Where-Object { $_['DMARC'] -in 'Missing', 'none' })
    Write-TcRemediationNote ("{0} domain(s) with no DMARC or with p=none" -f $gaps.Count)
    foreach ($e in $gaps) {
        [ordered]@{ Tenant = $t; Domain = $e['Domain']; 'Host' = $e['DNS host']; 'Current DMARC' = $e['DMARC']
                    Proposal = $(if ($e['DNS host'] -eq 'Unknown') { 'Ignore' } elseif ($e['DMARC'] -eq 'Missing') { 'p=none' } else { '' }) }
    }
}

$decisions = @(Get-TcDecision -Name 'DNS-DMARC' -Proposal @($proposals) -Key 'Tenant', 'Domain' -Choice 'p=none', 'p=quarantine', 'p=reject', 'Ignore')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -ne 'Ignore' }) {
    $address = ((Get-TcText $d 'Note')).Trim()
    if ($address -notmatch '^[^@\s;]+@[^@\s;]+\.[^@\s;]+$') { Write-TcRemediationAlert ("{0}: enter the reports address in Note, row skipped" -f (Get-TcMember $d 'Domain')); continue }
    if ((Get-TcDnsHost (Get-TcMember $d 'Domain')) -eq 'Cloudflare' -and $c.Apply -and -not [Environment]::GetEnvironmentVariable($TokenVariable)) { Write-TcRemediationAlert ("{0}: Cloudflare token missing (variable {1}), domain skipped" -f (Get-TcMember $d 'Domain'), $TokenVariable); continue }
    $value = if ((Get-TcMember $d 'Decision') -eq 'p=none') { "v=DMARC1; p=none; rua=mailto:$address" } else { "v=DMARC1; $((Get-TcMember $d 'Decision')); pct=100; rua=mailto:$address" }
    Add-TcDnsAction -Tenant (Get-TcMember $d 'Tenant') -Zone (Get-TcMember $d 'Domain') -Name ("_dmarc.{0}" -f (Get-TcMember $d 'Domain')) -Type TXT -Value $value -Action Set -Description ("DMARC of {0}: {1}" -f (Get-TcMember $d 'Domain'), (Get-TcMember $d 'Decision')) `
        -Test { param($a) [bool]@(Resolve-TcDnsEntry -Name $a.dns.name -Type TXT | Where-Object { (Get-TcMember $_ 'value') -eq $a.dns.value }).Count }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -ne 'Ignore' }) {
        $v = @(Resolve-TcDnsEntry -Name ("_dmarc.{0}" -f (Get-TcMember $d 'Domain')) -Type TXT | Where-Object { (Get-TcMember $_ 'value') -like 'v=DMARC1*' })
        if ($v.Count -eq 1) { New-TcRemediationResult OK ("{0}: {1}" -f (Get-TcMember $d 'Domain'), (Get-TcMember $v[0] 'value')) } else { New-TcRemediationResult Blocking ("{0}: {1} DMARC record(s)" -f (Get-TcMember $d 'Domain'), $v.Count) }
    }
}
Close-TcRemediation

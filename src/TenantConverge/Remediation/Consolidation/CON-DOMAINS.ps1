# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Draws up the state of the domains to move and confirms the reachable person for each (procedure CON-DOMAINS).

.DESCRIPTION
    Report domains-to-move.csv: DNS host, mode (API or manual), flow, MX TTL, default domain of the source, presence in the target.
    In an -Apply run, the script also reads the public NS servers and the real state of the domain in the source and in the target.

    Decision: decisions\CON-DOMAINS.csv, one row per domain. Enter Confirmed, the reachable person on the cutover evening in Decision
    maker and their backup in Note.
    The write test at each DNS host is in DNS-HOST.
#>
$c = Open-TcRemediation

function Get-NameServer {
    param([string]$Domain)
    try { return @(Resolve-TcDnsTransport -Name $Domain -Type NS -Server (Get-TcRemediationOption 'DnsServer') | Where-Object { (Get-TcMember $_ 'Type') -eq 'NS' } | ForEach-Object { ((Get-TcText $_ 'NameHost')).TrimEnd('.').ToLowerInvariant() }) }
    catch { return @() }
}

$inTarget = @(Get-TcRemediationTable 'Target' 'domains' | ForEach-Object { ([string]$_['Domain']).ToLowerInvariant() })
$rows = [System.Collections.Generic.List[object]]::new()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $domains = @((Get-TcMember (Get-TcRemediationTenant $t) 'Domains'))
    if (-not $domains.Count) { Write-TcRemediationNote 'No domain to move from this tenant.'; continue }
    foreach ($d in $domains) {
        $s = Get-TcRemediationTable $t 'dnsSummary' | Where-Object { $_['Domain'] -eq $d } | Select-Object -First 1
        $domain = Get-TcRemediationTable $t 'domains' | Where-Object { $_['Domain'] -eq $d } | Select-Object -First 1
        $h = Get-TcDnsHost $d
        Write-TcRemediationNote ("{0}: DNS host {1}, mode {2}, MX TTL {3} s" -f $d, $h, $(if ($h -eq 'Cloudflare') { 'API' } else { 'manual' }), $s['MX TTL'])
        if ($d.ToLowerInvariant() -in $inTarget) { Write-TcRemediationAlert "$d already exists in the target: a domain can live in only one tenant." }
        $rows.Add([ordered]@{ Tenant = $t; Domain = $d; 'Host' = $h; Mode = $(if ($h -eq 'Cloudflare') { 'API' } else { 'Manual' }); 'Inbound mail flow' = $s['Inbound mail flow']; 'MX TTL' = $s['MX TTL']
                                'Default in the source' = $(if ($domain -and $domain['Default']) { 'Yes' } else { 'No' }); 'Present in target' = $(if ($d.ToLowerInvariant() -in $inTarget) { 'Yes' } else { 'No' }) })
    }
}

$decisions = @(Get-TcDecision -Name 'CON-DOMAINS' -Proposal @($rows | ForEach-Object { [ordered]@{ Tenant = (Get-TcMember $_ 'Tenant'); Domain = (Get-TcMember $_ 'Domain'); 'Host' = $_['Host'] } }) -Key 'Tenant', 'Domain' -Choice 'Confirmed')
foreach ($l in $rows) {
    $d = $decisions | Where-Object { (Get-TcMember $_ 'Domain') -eq (Get-TcMember $l 'Domain') } | Select-Object -First 1
    $l['Reachable person'] = $(if ($d) { (Get-TcMember $d 'Decision maker') })
    $l['Backup'] = $(if ($d) { (Get-TcMember $d 'Note') })
    if ($d -and (-not (Get-TcMember $d 'Decision maker') -or -not (Get-TcMember $d 'Note'))) { Write-TcRemediationAlert ("{0}: enter the reachable person in Decision maker and their backup in Note" -f (Get-TcMember $l 'Domain')) }
}
[void](Export-TcRemediationReport -Name 'domains-to-move' -Rows $rows.ToArray())

Invoke-TcRemediationPlan -Verify {
    param($t)
    $domains = @((Get-TcMember (Get-TcRemediationTenant $t) 'Domains'))
    if (-not $domains.Count) { return }
    $source = @(Invoke-TcGraph -Tenant $t -Uri 'v1.0/domains' -All)
    $target = @(Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/domains' -All)
    foreach ($d in $domains) {
        $ns = @(Get-NameServer $d)
        $h = Get-TcDnsHost $d
        if (-not $ns.Count) { New-TcRemediationResult Blocking "${d}: no NS server read" }
        elseif ($h -eq 'Cloudflare' -and -not @($ns | Where-Object { $_ -match 'cloudflare' }).Count) { New-TcRemediationResult Warning ("{0}: NS {1}, Cloudflare attendu" -f $d, ($ns -join ', ')) }
        else { New-TcRemediationResult OK ("{0}: NS {1}" -f $d, ($ns -join ', ')) }
        $s = $source | Where-Object { (Get-TcMember $_ 'id') -eq $d } | Select-Object -First 1
        if ($s) { New-TcRemediationResult OK ("{0}: present in the source{1}" -f $d, $(if ((Get-TcMember $s 'isDefault')) { ', default domain to change before its removal (RELEASE-DOMAIN)' } else { '' })) } else { New-TcRemediationResult Info "${d}: missing from the source" }
        if (@($target | Where-Object { (Get-TcMember $_ 'id') -eq $d }).Count) { New-TcRemediationResult Warning "${d}: already present in the target" } else { New-TcRemediationResult OK "${d}: missing from the target, as expected before the cutover" }
    }
}
Close-TcRemediation

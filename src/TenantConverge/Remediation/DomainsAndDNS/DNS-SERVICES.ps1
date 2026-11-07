# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Prepares and checks MX, SPF and Autodiscover of the migrated domains (procedure DNS-SERVICES).

.DESCRIPTION
    These records are published during the cutover: this script does not redo that.
    Before the cutover, it reports what must be ready: TTL, DNS host, Cloudflare token, SPF to publish.
    Keep the senders of the current SPF and its qualifier: review them after the cutover (DNS-SPF).
    After the records move, in an -Apply run, it compares the public DNS with the values read in the target: MX, one SPF, Autodiscover, old
    MX left over. The values only exist after the domains are added and verified: before that, the check says so and stops for this domain.
    If a gateway is chosen (EXO-CONNECTORS), the MX points to it: the gap reported is then normal.
#>
$c = Open-TcRemediation

$Target = [int](Get-TcRemediationOption 'DnsTtl')
$TokenVariable = [string](Get-TcRemediationOption 'DnsApiTokenVariable')

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $public = @(Get-TcRemediationTable $t 'publicDns')
    $rows = foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        $s = Get-TcRemediationTable $t 'dnsSummary' | Where-Object { $_['Domain'] -eq $d } | Select-Object -First 1
        $h = Get-TcDnsHost $d
        $spf = [string]$s['SPF']
        $plannedOne = if ($spf -match 'include:spf\.protection\.outlook\.com') { $spf } elseif ($spf -and $spf -ne 'Missing') { $spf -replace '\s+([~\-?+]all)$', ' include:spf.protection.outlook.com $1' } else { 'Value read in the target when the records move' }
        $high = @($public | Where-Object { $_['Domain'] -eq $d -and $_['Type'] -in 'MX', 'TXT (SPF)' -and [int]$_['TTL'] -gt $Target }) + @($public | Where-Object { $_['Record'] -eq "autodiscover.$d" -and [int]$_['TTL'] -gt $Target })
        if ($high.Count) { Write-TcRemediationAlert ("{0}: {1} record(s) above {2} s: run DNS-TTL at least 48 hours before the cutover" -f $d, $high.Count, $Target) }
        if ($h -eq 'Cloudflare' -and -not [Environment]::GetEnvironmentVariable($TokenVariable)) { if ($c.Apply) { Write-TcRemediationAlert ("{0}: no Cloudflare token (variable {1}): the record change will fail" -f $d, $TokenVariable) } else { Write-TcRemediationNote ("{0}: the Cloudflare token must exist before the -Apply run" -f $d) } }
        Write-TcRemediationNote ("{0}: MX {1}, TTL {2} s, publishing {3}" -f $d, $s['MX'], $s['MX TTL'], $(if ($h -eq 'Cloudflare') { 'through the API' } else { "by hand at $h" }))
        [ordered]@{ Tenant = $t; Domain = $d; 'Host' = $h; 'Current MX' = $s['MX']; 'MX TTL' = $s['MX TTL']; 'Current SPF' = $spf; 'SPF to publish' = $plannedOne; 'Current Autodiscover' = $s['Autodiscover'] }
    }
    [void](Export-TcRemediationReport -Name "dns-services-$t" -Rows @($rows))
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $domains = @(Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/domains' -All)
    foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        $o = $domains | Where-Object { (Get-TcMember $_ 'id') -eq $d } | Select-Object -First 1
        if (-not $o -or -not (Get-TcMember $o 'isVerified')) { New-TcRemediationResult Blocking "${d}: not verified in the target, values unavailable" 'Wait until the domains are added and verified in the target.'; continue }
        $expectedItems = @(Invoke-TcGraph -Tenant 'Target' -Uri "v1.0/domains/$d/serviceConfigurationRecords" -All | Where-Object { (Get-TcMember $_ 'supportedService') -eq 'Email' })
        $mx = (Get-TcMember ($expectedItems | Where-Object { (Get-TcMember $_ 'recordType') -eq 'Mx' } | Select-Object -First 1) 'mailExchange')
        $published = @(Resolve-TcDnsEntry -Name $d -Type MX)
        if (@($published | Where-Object { (Get-TcMember $_ 'value') -eq $mx }).Count) { New-TcRemediationResult OK "${d}: MX to the target" } else { New-TcRemediationResult Blocking ("{0}: MX published {1}, {2} expected" -f $d, (($published | ForEach-Object { (Get-TcMember $_ 'value') }) -join ', '), $mx) }
        $oldOnes = @($published | Where-Object { (Get-TcMember $_ 'value') -ne $mx })
        if ($oldOnes.Count) { New-TcRemediationResult Warning ("{0}: MX to remove: {1}" -f $d, (($oldOnes | ForEach-Object { (Get-TcMember $_ 'value') }) -join ', ')) }
        $spf = @(Resolve-TcDnsEntry -Name $d -Type TXT | Where-Object { (Get-TcMember $_ 'value') -like 'v=spf1*' })
        if ((Get-TcCount $spf) -ne 1) { New-TcRemediationResult Blocking "${d}: $((Get-TcCount $spf)) SPF published, one expected" }
        elseif ((Get-TcMember $spf[0] 'value') -notmatch 'include:spf\.protection\.outlook\.com') { New-TcRemediationResult Blocking "${d}: the SPF does not include Exchange Online" }
        else { New-TcRemediationResult OK "${d}: one SPF, Exchange Online included" }
        $cname = ($expectedItems | Where-Object { (Get-TcMember $_ 'recordType') -eq 'CName' } | Select-Object -First 1)
        $auto = @(Resolve-TcDnsEntry -Name "autodiscover.$d" -Type CNAME)
        if (-not $cname) { New-TcRemediationResult Info "${d}: no Autodiscover expected by the target" }
        elseif (@($auto | Where-Object { (Get-TcMember $_ 'value') -eq (Get-TcMember $cname 'canonicalName') }).Count) { New-TcRemediationResult OK "${d}: Autodiscover as expected" }
        else { New-TcRemediationResult Blocking ("{0}: Autodiscover {1}, {2} attendu" -f $d, (($auto | ForEach-Object { (Get-TcMember $_ 'value') }) -join ', '), (Get-TcMember $cname 'canonicalName')) }
    }
}
if ($c.Apply) { [void](Export-TcRemediationReport -Name 'dns-services-check' -Rows @($script:TcRemediationRun['Results'])) }
Close-TcRemediation

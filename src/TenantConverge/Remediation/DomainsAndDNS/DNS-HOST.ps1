# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Proves write access to the DNS host of each domain to move (procedure DNS-HOST).

.DESCRIPTION
    For each domain: publishes a TXT with no effect, _tc-access-test.<domain>, waits to see it in the public DNS, then removes it.
    Cloudflare: through the API, with the token of the variable named in the remediation settings.
    Other hosts: the script shows the record to publish or remove, then watches the public DNS and goes on alone.

    In an -Apply run, with no token, the Cloudflare zones are skipped and reported: no action starts halfway.
    Getting the token and the named accounts stays a human action. The token must be limited to the migrated zones and revoked at
    closure; it is never written to a file.
#>
$c = Open-TcRemediation

$Prefix = '_tc-access-test'
$Value = 'tc-access-test'
$TokenVariable = [string](Get-TcRemediationOption 'DnsApiTokenVariable')
$token = [bool][Environment]::GetEnvironmentVariable($TokenVariable)

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        $h = Get-TcDnsHost $d
        if ($h -eq 'Cloudflare' -and -not $token) {
            if ($c.Apply) { Write-TcRemediationAlert ("{0}: Cloudflare token missing (variable {1}), zone skipped" -f $d, $TokenVariable); continue }
            Write-TcRemediationNote ("{0}: the Cloudflare token must exist before the -Apply run (variable {1})" -f $d, $TokenVariable)
        }
        else { Write-TcRemediationNote ("{0}: DNS host {1}, {2}" -f $d, $h, $(if ($h -eq 'Cloudflare') { 'written through the API' } else { 'manual write, the script watches public DNS' })) }
        $name = "$Prefix.$d"
        Add-TcDnsAction -Tenant $t -Zone $d -Name $name -Type TXT -Value $Value -Action Add -Description "Publish the test TXT $name" `
            -Test { param($a) [bool]@(Resolve-TcDnsEntry -Name $a.dns.name -Type TXT | Where-Object { (Get-TcMember $_ 'value') -eq $a.dns.value }).Count }
        Add-TcDnsAction -Tenant $t -Zone $d -Name $name -Type TXT -Value $Value -Action Remove -Description "Remove the test TXT $name" `
            -Test { param($a) -not @(Resolve-TcDnsEntry -Name $a.dns.name -Type TXT | Where-Object { (Get-TcMember $_ 'value') -eq $a.dns.value }).Count }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        if (@(Resolve-TcDnsEntry -Name "$Prefix.$d" -Type TXT).Count) { New-TcRemediationResult Warning "${d}: the test TXT is still visible" } else { New-TcRemediationResult OK "${d}: write access proven, test TXT removed" }
    }
}
Close-TcRemediation

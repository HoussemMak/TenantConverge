# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Checks that each migrated domain is verified in the target, with mail active (procedure TARGET-DOMAIN).

.DESCRIPTION
    The domains are added and verified during the cutover: this script does not redo that. It checks and reports.
    In preview, it lists the domains to follow and their state in the source.
    In an -Apply run, it reads in the target the state of the domain, its services, the accepted domain of Exchange and the public
    verification TXT, then writes domain-check.csv. Run it as often as needed: the script writes nothing.
#>
$c = Open-TcRemediation

$inTarget = @(Get-TcRemediationTable 'Target' 'domains' | ForEach-Object { ([string]$_['Domain']).ToLowerInvariant() })
$rows = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        $s = Get-TcRemediationTable $t 'domains' | Where-Object { $_['Domain'] -eq $d } | Select-Object -First 1
        $h = Get-TcDnsHost $d
        Write-TcRemediationNote ("{0}: {1} in the source, {2} in the target, DNS host {3}" -f $d, $(if ($s) { 'present' } else { 'missing' }), $(if ($d.ToLowerInvariant() -in $inTarget) { 'present' } else { 'missing' }), $h)
        [ordered]@{ Tenant = $t; Domain = $d; 'Host' = $h; 'Present in the source (snapshot)' = $(if ($s) { 'Yes' } else { 'No' }); 'Present in the target (snapshot)' = $(if ($d.ToLowerInvariant() -in $inTarget) { 'Yes' } else { 'No' }) }
    }
}
[void](Export-TcRemediationReport -Name 'domains-to-follow' -Rows @($rows))

Invoke-TcRemediationPlan -Verify {
    param($t)
    $domains = @(Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/domains' -All)
    $accepted = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-AcceptedDomain' | ForEach-Object { ((Get-TcText $_ 'DomainName')).ToLowerInvariant() })
    foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        $o = $domains | Where-Object { (Get-TcMember $_ 'id') -eq $d } | Select-Object -First 1
        if (-not $o) { New-TcRemediationResult Blocking "${d}: missing from the target" 'Wait for the removal from the source to finish, then resume the cutover.'; continue }
        if ((Get-TcMember $o 'isVerified')) { New-TcRemediationResult OK "${d}: verified" } else { New-TcRemediationResult Blocking "${d}: not verified yet" 'Verification often takes about ten minutes after the TXT is published.' }
        $services = @((Get-TcMember $o 'supportedServices'))
        $short = @('Email', 'OfficeCommunicationsOnline' | Where-Object { $_ -notin $services })
        if ($short.Count) { New-TcRemediationResult Blocking ("{0}: service(s) missing: {1}" -f $d, ($short -join ', ')) } else { New-TcRemediationResult OK "${d}: Email and OfficeCommunicationsOnline active" }
        if ($d.ToLowerInvariant() -in $accepted) { New-TcRemediationResult OK "${d}: accepted domain in Exchange Online" } else { New-TcRemediationResult Blocking "${d}: not in the accepted domains" }
    }
}
if ($c.Apply) { [void](Export-TcRemediationReport -Name 'domain-check' -Rows @($script:TcRemediationRun['Results'])) }
Close-TcRemediation

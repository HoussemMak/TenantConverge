# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Handles the legacy Skype and Teams records of the migrated domains (procedure DNS-SKYPE).

.DESCRIPTION
    Decision: decisions\DNS-SKYPE.csv, one row per record read in publicDns. Remove or Keep.
    The federation SRV is proposed as Keep: removing it can cut the external conversations of the domain.

    Run it after the domains are verified in the target: the expected values are read there. In an -Apply run, while the domain is not
    verified there, the script does nothing and says so. A record the target expects stays in place, whatever the decision.

    The cutover publishes the Email service only. Add-TcDnsAction does not handle SRV: their removal goes through an instruction, and the
    script watches the public DNS. The test of an external conversation stays to be done by a person.
#>
$c = Open-TcRemediation

$Reason = '^(lyncdiscover|sip)\.|^_sip\._tls\.|^_sipfederationtls\._tcp\.'
$TokenVariable = [string](Get-TcRemediationOption 'DnsApiTokenVariable')
$Tracking = @{}

function Test-SrvMissing {
    param([string]$Name)
    try { return -not @(Resolve-TcDnsTransport -Name $Name -Type SRV -Server (Get-TcRemediationOption 'DnsServer') | Where-Object { (Get-TcMember $_ 'Type') -eq 'SRV' }).Count }
    catch { return $true }
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $readItems = @(Get-TcRemediationTable $t 'publicDns' | Where-Object { $_['Record'] -match $Reason })
    Write-TcRemediationNote ("{0} legacy record(s) read" -f $readItems.Count)
    foreach ($e in $readItems) {
        [ordered]@{ Tenant = $t; Domain = $e['Domain']; Record = $e['Record']; Type = $e['Type']; Value = $e['Value']
                    Proposal = $(if ($e['Record'] -like '_sipfederationtls*') { 'Keep' } else { 'Remove' }) }
    }
}

$decisions = @(Get-TcDecision -Name 'DNS-SKYPE' -Proposal @($proposals) -Key 'Tenant', 'Record' -Choice 'Remove', 'Keep')

foreach ($t in $c.Tenants) {
    foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        $removals = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Domain') -eq $d -and (Get-TcMember $_ 'Decision') -eq 'Remove' })
        $h = Get-TcDnsHost $d
        $expectedItems = @()
        if ($c.Apply) {
            $domain = @(Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/domains' -All) | Where-Object { (Get-TcMember $_ 'id') -eq $d } | Select-Object -First 1
            if (-not $domain -or -not (Get-TcMember $domain 'isVerified')) { Write-TcRemediationAlert "$d is not verified in the target: run again after the domains are verified in the target"; continue }
            $expectedItems = @(Invoke-TcGraph -Tenant 'Target' -Uri "v1.0/domains/$d/serviceConfigurationRecords" -All | Where-Object { (Get-TcMember $_ 'supportedService') -eq 'OfficeCommunicationsOnline' } | ForEach-Object { ((Get-TcText $_ 'label')).ToLowerInvariant() })
        }
        foreach ($r in $removals) {
            $name = (Get-TcText $r 'Record')
            if ($name.ToLowerInvariant() -in $expectedItems) { Write-TcRemediationAlert "${name}: the target expects this record, Remove decision ignored"; continue }
            if ((Get-TcMember $r 'Type') -eq 'CNAME') {
                if ($h -eq 'Cloudflare' -and $c.Apply -and -not [Environment]::GetEnvironmentVariable($TokenVariable)) { Write-TcRemediationAlert ("{0}: Cloudflare token missing (variable {1}), skipped" -f $name, $TokenVariable); continue }
                Add-TcDnsAction -Tenant $t -Zone $d -Name $name -Type CNAME -Value ((Get-TcText $r 'Value')) -Action Remove -Description "Remove the legacy CNAME $name" `
                    -Test { param($a) -not @(Resolve-TcDnsEntry -Name $a.dns.name -Type CNAME).Count }
            }
            else {
                $object = "$((Get-TcMember $r 'Type')) $name"
                $Tracking[$object] = $name
                Add-TcManualAction -Tenant $t -Object $object -Description "Remove the legacy record $object" -Minutes 120 -IntervalSeconds 120 -Instruction @(
                    "To do at $h, zone ${d}: remove the $((Get-TcMember $r 'Type')) record $name (value $((Get-TcMember $r 'Value'))).",
                    'The script watches public DNS and continues on its own.') -WaitUntil { param($a) Test-SrvMissing -Name $Tracking[$a.object] }
            }
        }
        if (@($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Domain') -eq $d }).Count) {
            Add-TcManualAction -Tenant $t -Object "External conversation $d" -Description "Test an external Teams chat from an account of $d" -Instruction @("After the cutover, open a Teams chat with a contact from another organization from an account of $d, in both directions.")
        }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        $name = "_sipfederationtls._tcp.$d"
        $srv = try { @(Resolve-TcDnsTransport -Name $name -Type SRV -Server (Get-TcRemediationOption 'DnsServer') | Where-Object { (Get-TcMember $_ 'Type') -eq 'SRV' }) } catch { @() }
        if (-not @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Domain') -eq $d }).Count) { continue }
        if (-not (Get-TcCount $srv)) { New-TcRemediationResult Warning "${name}: missing, external exchanges may be cut off" }
        elseif ((Get-TcText $srv[0] 'NameTarget') -match 'sipfed\.online\.lync\.com' -and [int](Get-TcMember $srv[0] 'Port') -eq 5061) { New-TcRemediationResult OK "${name}: as expected" }
        else { New-TcRemediationResult Warning ("{0}: {1}:{2}, sipfed.online.lync.com:5061 attendu" -f $name, (Get-TcMember $srv[0] 'NameTarget'), (Get-TcMember $srv[0] 'Port')) }
    }
}
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Lowers to 300 s the TTL of the MX, SPF and Autodiscover of the domains to move (procedure DNS-TTL).

.DESCRIPTION
    Starts from the publicDns table: only the records above the goal become actions. The zone read is first exported to CSV, as a backup.
    Cloudflare: the TTL changes through the API. Other hosts: the instruction shows, then the script asks the NS server of the domain and
    goes on alone as soon as the TTL is at the goal.

    The TTL is read on the NS server of the domain: a public resolver shows a countdown and a cached entry can look right. For this
    reason, a manual action goes through Add-TcManualAction: Add-TcDnsAction -Action TTL checks nothing at a host with no API.

    The 48 hours of waiting before the cutover must be kept: the DNS check verifies it at the go/no-go.
#>
$c = Open-TcRemediation

$Target = [int](Get-TcRemediationOption 'DnsTtl')
$TokenVariable = [string](Get-TcRemediationOption 'DnsApiTokenVariable')
$Tracking = @{}

function Get-AuthoritativeTtl {
    <# TTL read on the NS server of the zone; $null if it cannot be read. #>
    param([string]$Zone, [string]$Name, [string]$Type)
    try {
        $ns = @(Resolve-TcDnsTransport -Name $Zone -Type NS -Server (Get-TcRemediationOption 'DnsServer') | Where-Object { (Get-TcMember $_ 'Type') -eq 'NS' } | ForEach-Object { ((Get-TcText $_ 'NameHost')).TrimEnd('.') }) | Select-Object -First 1
        if (-not $ns) { return $null }
        $r = @(Resolve-TcDnsTransport -Name $Name -Type $Type -Server $ns | Where-Object { (Get-TcMember $_ 'Type') -eq $Type })
        if (-not $r.Count) { return $null }
        return [int]((Get-TcMember ($r | ForEach-Object { (Get-TcMember $_ 'TTL') } | Measure-Object -Maximum) 'Maximum'))
    }
    catch { return $null }
}

function Test-TargetTtl {
    param([string]$Zone, [string]$Name, [string]$Type)
    $v = Get-AuthoritativeTtl -Zone $Zone -Name $Name -Type $Type
    return ($null -ne $v -and $v -le $Target)
}

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $public = @(Get-TcRemediationTable $t 'publicDns')
    [void](Export-TcRemediationReport -Name "zone-before-ttl-$t" -Rows $public)
    foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        $h = Get-TcDnsHost $d
        $high = @($public | Where-Object { $_['Domain'] -eq $d -and [int]$_['TTL'] -gt $Target -and ($_['Type'] -in 'MX', 'TXT (SPF)' -or ($_['Type'] -eq 'CNAME' -and $_['Record'] -eq "autodiscover.$d")) })
        Write-TcRemediationNote ("{0}: {1} record(s) above {2} s, DNS host {3}" -f $d, $high.Count, $Target, $h)
        if ($h -eq 'Cloudflare' -and $high.Count -and $c.Apply -and -not [Environment]::GetEnvironmentVariable($TokenVariable)) { Write-TcRemediationAlert ("{0}: Cloudflare token missing (variable {1}), zone skipped" -f $d, $TokenVariable); continue }
        foreach ($e in $high) {
            $name = [string]$e['Record']
            $type = ([string]$e['Type'] -split ' ')[0]
            $text = "Lower the TTL of $type $name from $($e['TTL']) s to $Target s"
            if ($h -eq 'Cloudflare') {
                Add-TcDnsAction -Tenant $t -Zone $d -Name $name -Type $type -Ttl $Target -Action TTL -Description $text `
                    -Test { param($a) Test-TargetTtl -Zone $a.dns.zone -Name $a.dns.name -Type $a.dns.type }
            }
            else {
                $object = "$type $name"
                $Tracking[$object] = @{ Zone = $d; Name = $name; Type = $type }
                Add-TcManualAction -Tenant $t -Object $object -Description $text -Minutes 120 -IntervalSeconds 120 -Instruction @(
                    "To do at $h, zone ${d}: set the TTL of the $type $name record back to $Target s, without changing its value.",
                    'Note the actual value if the DNS host imposes a minimum, and extend the wait before the cutover accordingly.',
                    'The script queries the NS server of the domain and continues on its own.') -WaitUntil { param($a) $s = $Tracking[$a.object]; Test-TargetTtl -Zone (Get-TcMember $s 'Zone') -Name (Get-TcMember $s 'Name') -Type (Get-TcMember $s 'Type') }
            }
        }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        foreach ($e in @(@($d, 'MX'), @($d, 'TXT'), @("autodiscover.$d", 'CNAME'))) {
            $v = Get-AuthoritativeTtl -Zone $d -Name $e[0] -Type $e[1]
            if ($null -eq $v) { New-TcRemediationResult Warning ("{0} {1}: TTL unreadable on the NS server" -f $e[1], $e[0]) }
            elseif ($v -le $Target) { New-TcRemediationResult OK ("{0} {1}: TTL {2} s" -f $e[1], $e[0], $v) }
            else { New-TcRemediationResult Blocking ("{0} {1}: TTL {2} s, target {3} s" -f $e[1], $e[0], $v, $Target) }
        }
    }
}
Close-TcRemediation

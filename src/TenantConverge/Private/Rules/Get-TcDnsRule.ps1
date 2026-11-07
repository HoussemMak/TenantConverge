function Get-TcDnsRule {
    <#
    .SYNOPSIS
    Returns the domain and DNS rules, as script blocks that take the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Public DNS of the domains
        param($Role)
        $domains = @(Get-TcRuleRow $Role 'dnsSummary')
        if (-not $domains.Count) { return }

        $spf = @($domains | Where-Object { (Get-TcProperty $_ 'SPF') -eq 'Missing' -or (Get-TcProperty $_ 'SPF') -like 'Multiple*' })
        if ($spf.Count) { Add-TcFinding 'DNS-SPF' $Role -Values @{ count = $spf.Count } -Items ($spf | ForEach-Object { '{0} - {1}' -f (Get-TcProperty $_ 'Domain'), (Get-TcProperty $_ 'SPF') }) }

        $dmarc = @($domains | Where-Object { (Get-TcProperty $_ 'DMARC') -in 'Missing', 'none' })
        if ($dmarc.Count) { Add-TcFinding 'DNS-DMARC' $Role -Values @{ count = $dmarc.Count } -Items ($dmarc | ForEach-Object { '{0} - DMARC {1}' -f (Get-TcProperty $_ 'Domain'), (Get-TcProperty $_ 'DMARC') }) }

        if ($Role -eq 'Target') { return }

        $ttl = [int](Get-TcRuleThreshold 'maxTtlSeconds')
        $long = @($domains | Where-Object { $v = Get-TcProperty $_ 'MX TTL'; "$v" -ne '' -and [int]$v -gt $ttl })
        if ($long.Count) { Add-TcFinding 'DNS-TTL' $Role -Values @{ ttl = $ttl; count = $long.Count } -Items ($long | ForEach-Object { '{0} - TTL {1} s' -f (Get-TcProperty $_ 'Domain'), (Get-TcProperty $_ 'MX TTL') }) }

        Add-TcFinding 'DNS-HOST' $Role -Items ($domains | ForEach-Object { '{0} - {1} - flow {2}' -f (Get-TcProperty $_ 'Domain'), (Get-TcProperty $_ 'DNS host'), (Get-TcProperty $_ 'Inbound mail flow') })

        $skype = @($domains | Where-Object { Test-TcRowTrue $_ 'Teams or legacy Skype' })
        if ($skype.Count) { Add-TcFinding 'DNS-SKYPE' $Role -Values @{ count = $skype.Count } -Items ($skype | ForEach-Object { Get-TcProperty $_ 'Domain' }) }

        $gateway = @($domains | Where-Object { (Get-TcProperty $_ 'Inbound mail flow') -eq 'Third-party gateway' })
        if ($gateway.Count) { Add-TcFinding 'DNS-GATEWAY' $Role -Values @{ count = $gateway.Count } -Items ($gateway | ForEach-Object { '{0} - MX {1}' -f (Get-TcProperty $_ 'Domain'), (Get-TcProperty $_ 'MX') }) }
    }
}

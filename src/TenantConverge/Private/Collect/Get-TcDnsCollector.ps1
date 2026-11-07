function Get-TcDnsCollector {
    <#
    .SYNOPSIS
    Lists the Domains and DNS collectors, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @(
        @{
            Id       = 'DNS-01'
            Workload = 'Domains and DNS'
            Title    = 'Public DNS of each domain: host, MX, SPF, DMARC, DKIM, Autodiscover, Teams, Intune'
            Service  = 'Graph'
            Collect  = {
                if (-not (Get-Command Resolve-DnsName -ErrorAction SilentlyContinue)) { throw 'Resolve-DnsName is not recognized as a name of a cmdlet (the Windows DnsClient module is required)' }
                $domains = @(Get-TcTable 'domains' | Where-Object { (Get-TcProperty $_ 'Verified') -and (Get-TcProperty $_ 'Domain') -notmatch '\.(onmicrosoft|mail\.onmicrosoft)\.com$' } | ForEach-Object { (Get-TcProperty $_ 'Domain') })
                if (-not $domains.Count) { $domains = @((Get-TcProperty (Get-TcGraphObject 'v1.0/domains') 'value') | Where-Object { (Get-TcProperty $_ 'isVerified') -and (Get-TcProperty $_ 'id') -notmatch 'onmicrosoft\.com$' } | ForEach-Object { (Get-TcProperty $_ 'id') }) }
                $dnsServer = Get-TcCollectionSetting 'dnsServer'
                $resolver = @{ Server = $dnsServer; Fallback = $false }
                $queryDns = {
                    param($recordName, $type)
                    $asked["$recordName|$type"] = $true
                    $answer = Resolve-TcDnsRecord -Name $recordName -Type $type -Resolver $resolver
                    if ($answer.Failed) { $unanswered["$recordName|$type"] = $answer.Error }
                    $answer.Records
                }
                $answered = { param($recordName, $type) -not $unanswered.ContainsKey("$recordName|$type") }
                $rawRecords = [System.Collections.Generic.List[object]]::new(); $summary = [System.Collections.Generic.List[object]]::new()
                foreach ($d in $domains) {
                    $asked = @{}; $unanswered = @{}
                    $ns = @(& $queryDns $d 'NS'); $mx = @(& $queryDns $d 'MX'); $txt = @(& $queryDns $d 'TXT'); $dmarcRecords = @(& $queryDns "_dmarc.$d" 'TXT')
                    $dkimOne = @(& $queryDns "selector1._domainkey.$d" 'CNAME'); $dkimTwo = @(& $queryDns "selector2._domainkey.$d" 'CNAME'); $autodiscover = @(& $queryDns "autodiscover.$d" 'CNAME')
                    $lyncDiscover = @(& $queryDns "lyncdiscover.$d" 'CNAME'); $sip = @(& $queryDns "_sip._tls.$d" 'SRV'); $federation = @(& $queryDns "_sipfederationtls._tcp.$d" 'SRV')
                    $enterpriseRegistration = @(& $queryDns "enterpriseregistration.$d" 'CNAME'); $enterpriseEnrollment = @(& $queryDns "enterpriseenrollment.$d" 'CNAME')
                    if ($unanswered.Count) {
                        Add-TcCollectorWarning ('DNS of {0} ({1} of {2} queries)' -f $d, $unanswered.Count, $asked.Count) @($unanswered.Values)[0]
                        # A domain that gave no answer at all has nothing to say: no row is better than a row of Missing.
                        if ($unanswered.Count -eq $asked.Count) { continue }
                    }
                    $spf = @($txt | ForEach-Object { -join (Get-TcProperty $_ 'Strings') } | Where-Object { $_ -like 'v=spf1*' })
                    $dmarc = @($dmarcRecords | ForEach-Object { -join (Get-TcProperty $_ 'Strings') } | Where-Object { $_ -like 'v=DMARC1*' }) | Select-Object -First 1
                    foreach ($r in $ns) {
                        $rawRecords.Add([ordered]@{
                                'Domain' = $d
                                'Record' = $d
                                'Type'   = 'NS'
                                'Value'  = (Get-TcProperty $r 'NameHost')
                                'TTL'    = (Get-TcProperty $r 'TTL')
                            })
                    }
                    foreach ($r in $mx) {
                        $rawRecords.Add([ordered]@{
                                'Domain' = $d
                                'Record' = $d
                                'Type'   = 'MX'
                                'Value'  = ('{0} {1}' -f (Get-TcProperty $r 'Preference'), (Get-TcProperty $r 'NameExchange'))
                                'TTL'    = (Get-TcProperty $r 'TTL')
                            })
                    }
                    foreach ($v in $spf) {
                        $rawRecords.Add([ordered]@{
                                'Domain' = $d
                                'Record' = $d
                                'Type'   = 'TXT (SPF)'
                                'Value'  = $v
                                'TTL'    = (Get-TcProperty @($txt)[0] 'TTL')
                            })
                    }
                    if ($dmarc) {
                        $rawRecords.Add([ordered]@{
                                'Domain' = $d
                                'Record' = "_dmarc.$d"
                                'Type'   = 'TXT (DMARC)'
                                'Value'  = $dmarc
                                'TTL'    = (Get-TcProperty @($dmarcRecords)[0] 'TTL')
                            })
                    }
                    foreach ($p in @(@("selector1._domainkey.$d", $dkimOne), @("selector2._domainkey.$d", $dkimTwo), @("autodiscover.$d", $autodiscover), @("lyncdiscover.$d", $lyncDiscover), @("enterpriseregistration.$d", $enterpriseRegistration), @("enterpriseenrollment.$d", $enterpriseEnrollment))) {
                        foreach ($r in @($p[1])) {
                            $rawRecords.Add([ordered]@{
                                    'Domain' = $d
                                    'Record' = $p[0]
                                    'Type'   = 'CNAME'
                                    'Value'  = (Get-TcProperty $r 'NameHost')
                                    'TTL'    = (Get-TcProperty $r 'TTL')
                                })
                        }
                    }
                    foreach ($p in @(@("_sip._tls.$d", $sip), @("_sipfederationtls._tcp.$d", $federation))) {
                        foreach ($r in @($p[1])) {
                            $rawRecords.Add([ordered]@{
                                    'Domain' = $d
                                    'Record' = $p[0]
                                    'Type'   = 'SRV'
                                    'Value'  = ('{0}:{1}' -f (Get-TcProperty $r 'NameTarget'), (Get-TcProperty $r 'Port'))
                                    'TTL'    = (Get-TcProperty $r 'TTL')
                                })
                        }
                    }
                    $mxHosts = @($mx | Sort-Object Preference | ForEach-Object { [string](Get-TcProperty $_ 'NameExchange') })
                    $nameServers = (@($ns | ForEach-Object { [string](Get-TcProperty $_ 'NameHost') }) -join ' ').ToLowerInvariant()
                    $summary.Add([ordered]@{
                            'Domain'                = $d
                            'DNS host'              = $(switch -Regex ($nameServers) { 'cloudflare' { 'Cloudflare' } 'domaincontrol' { 'GoDaddy' } 'awsdns' { 'Amazon Route 53' } 'azure-dns' { 'Azure DNS' } 'registrar-servers' { 'Namecheap' } default { if ($nameServers) { $nameServers.Split(' ')[0] } else { 'Unknown' } } })
                            'MX'                    = ($mxHosts -join ', ')
                            'Inbound mail flow'     = $(if (-not (& $answered $d 'MX')) { 'Unknown' } elseif (-not $mxHosts.Count) { 'No MX' } elseif ($mxHosts[0] -match 'mail\.protection\.outlook\.com$') { 'Exchange Online direct' } else { 'Third-party gateway' })
                            'MX TTL'                = $(if ($mx.Count) { (Get-TcProperty ($mx | Measure-Object TTL -Maximum) 'Maximum') })
                            'SPF'                   = $(if (-not (& $answered $d 'TXT')) { 'Unknown' } elseif ($spf.Count -gt 1) { 'Multiple (invalid)' } elseif ($spf.Count) { $spf[0] } else { 'Missing' })
                            'Microsoft SPF'         = $(if (& $answered $d 'TXT') { [bool](@($spf | Where-Object { $_ -match 'spf\.protection\.outlook\.com' }).Count) })
                            'DMARC'                 = $(if (-not (& $answered "_dmarc.$d" 'TXT')) { 'Unknown' } elseif ($dmarc -match 'p=(\w+)') { $Matches[1] } elseif ($dmarc) { 'present' } else { 'Missing' })
                            'DKIM published'        = $(if ((& $answered "selector1._domainkey.$d" 'CNAME') -and (& $answered "selector2._domainkey.$d" 'CNAME')) { [bool]($dkimOne.Count -and $dkimTwo.Count) })
                            'Autodiscover'          = $(if ($autodiscover.Count) { [string](Get-TcProperty $autodiscover[0] 'NameHost') } elseif (& $answered "autodiscover.$d" 'CNAME') { 'Missing' } else { 'Unknown' })
                            'Teams or legacy Skype' = $(if ($lyncDiscover.Count -or $sip.Count -or $federation.Count) { $true } elseif ((& $answered "lyncdiscover.$d" 'CNAME') -and (& $answered "_sip._tls.$d" 'SRV') -and (& $answered "_sipfederationtls._tcp.$d" 'SRV')) { $false })
                            'Intune enrollment'     = $(if ($enterpriseEnrollment.Count -or $enterpriseRegistration.Count) { $true } elseif ((& $answered "enterpriseregistration.$d" 'CNAME') -and (& $answered "enterpriseenrollment.$d" 'CNAME')) { $false })
                        })
                }
                if ($resolver['Fallback'] -and $summary.Count) { Add-TcCollectorNote "The DNS server $dnsServer could not be reached: the system resolver answered instead." }
                Add-TcTable 'publicDns' $rawRecords
                Add-TcTable 'dnsSummary' $summary
            }
        }

    )
}
# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Creates the DKIM selectors at 2048 bits, publishes the CNAMEs and turns signing on (procedure EXO-DKIM).

.DESCRIPTION
    Target tenant (MAIL-01, by default): domains of the target with DKIM off, except onmicrosoft.com domains.
    Source tenant, with -Tenant S1 (CUT-01): migrated domains of this source. All the actions apply to the target.

    Decision: decisions\EXO-DKIM.csv, one row per domain, Sign or Skip. The script writes at the DNS host of the customer and a rotation
    cannot be undone: with no decision, nothing is planned.

    A domain only reaches the target at the cutover: each -Test checks that it is accepted there. Otherwise the action is postponed and
    the script ends with code 1. Run it again after the domains are verified, and before DKIM is set up by any other tool.

    Three cases according to the configuration found:
      missing                : created at 2048 bits, disabled;
      disabled at 1024 bits  : replaced, nothing signs with it yet;
      enabled at 1024 bits   : rotation to 2048 bits. Microsoft moves only the inactive selector to 2048: run again after the
                               rotation, four days later, for the second one.

    The CNAMEs come from the target at run time: their value is specific to the domain and the tenant. Cloudflare is written through the
    API. At other hosts, the script shows the record and watches the public DNS.
    Limit: checking dkim=pass in the headers of a test email stays to be done by a person.
#>
$c = Open-TcRemediation

$TargetBits = 2048

function Get-DkimConfiguration {
    param([string]$Domain)
    return (Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-DkimSigningConfig' | Where-Object { (Get-TcMember $_ 'Domain') -eq $Domain -or (Get-TcMember $_ 'Name') -eq $Domain } | Select-Object -First 1)
}

function Test-Key2048 { param($Config) return ([int](Get-TcMember $Config 'Selector1KeySize') -ge $TargetBits -and [int](Get-TcMember $Config 'Selector2KeySize') -ge $TargetBits) }

$Domains = @{}
$proposals = [System.Collections.Generic.List[object]]::new()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $table = @(Get-TcRemediationTable 'Target' 'dkim')
    if ($t -eq 'Target') {
        $list = @($table | Where-Object { -not (ConvertTo-TcBoolean $_['Enabled']) -and $_['Domain'] -notmatch '\.onmicrosoft\.com$' } | ForEach-Object { $_['Domain'] })
        Write-TcRemediationNote ("{0} domain(s) of the target with no DKIM signature" -f $list.Count)
    }
    else {
        $signed = @($table | Where-Object { ConvertTo-TcBoolean $_['Enabled'] } | ForEach-Object { $_['Domain'] })
        $list = @((Get-TcMember (Get-TcRemediationTenant $t) 'Domains') | Where-Object { $_ -notin $signed })
        Write-TcRemediationNote ("{0} migrated domain(s) to sign in the target" -f $list.Count)
    }
    foreach ($d in $list) { $proposals.Add([ordered]@{ Tenant = $t; Domain = $d; 'DNS host' = (Get-TcDnsHost $d); Proposal = 'Sign' }) }
}
$decisions = @(Get-TcDecision -Name 'EXO-DKIM' -Proposal @($proposals) -Key 'Tenant', 'Domain' -Choice 'Sign', 'Skip')

foreach ($t in $c.Tenants) {
    $Domains[$t] = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Sign' } | ForEach-Object { (Get-TcMember $_ 'Domain') })

    foreach ($d in $Domains[$t]) {
        Add-TcBlockAction -Tenant 'Target' -Service Exo -Object $d -Data @{ Domain = $d } -Description ("Create the DKIM selectors of {0} at {1} bits, disabled" -f $d, $TargetBits) `
            -Test {
                param($a)
                $n = $a.data.Domain
                if (-not (Test-TcTargetDomain $n)) { return Test-TcPostponed $a ("{0} is not accepted in the target: run again after the domains are verified in the target" -f $n) }
                $k = Get-DkimConfiguration $n
                if (-not $k) { return $false }
                return ([bool](Get-TcMember $k 'Enabled') -or (Test-Key2048 $k))
            } `
            -Undo @{ command = 'Remove-DkimSigningConfig'; parameters = @{ Identity = $d } } `
            -Block {
                param($a)
                $n = $a.data.Domain
                if (Get-DkimConfiguration $n) { Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Remove-DkimSigningConfig' -Parameters @{ Identity = $n } | Out-Null }
                Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'New-DkimSigningConfig' -Parameters @{ DomainName = $n; Enabled = $false; KeySize = $TargetBits } | Out-Null
            }

        Add-TcBlockAction -Tenant 'Target' -Service Exo -Object $d -Data @{ Domain = $d } -Description ("Publish the CNAMEs of {0} and enable signing" -f $d) `
            -Test {
                param($a)
                $n = $a.data.Domain
                if (-not (Test-TcTargetDomain $n)) { return Test-TcPostponed $a ("{0} is not accepted in the target: run again after the domains are verified in the target" -f $n) }
                $k = Get-DkimConfiguration $n
                if (-not $k) { return Test-TcPostponed $a ("{0} has no DKIM configuration" -f $n) }
                return [bool](Get-TcMember $k 'Enabled')
            } `
            -Undo @{ command = 'Set-DkimSigningConfig'; parameters = @{ Identity = $d; Enabled = $false } } `
            -Block {
                param($a)
                $n = $a.data.Domain
                $k = Get-DkimConfiguration $n
                foreach ($s in 1, 2) {
                    $name = "selector$s._domainkey.$n"
                    $value = ([string]$k."Selector${s}CNAME").TrimEnd('.')
                    if (-not $value) { throw "Selector${s}CNAME is empty for $n" }
                    if (@(Resolve-TcDnsEntry -Name $name -Type CNAME | Where-Object { (Get-TcMember $_ 'value') -eq $value }).Count) { continue }
                    Invoke-TcDnsRecord -Action $a -Zone $n -Name $name -Type CNAME -Value $value -Ttl ([int](Get-TcRemediationOption 'DnsTtl'))
                }
                Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Set-DkimSigningConfig' -Parameters @{ Identity = $n; Enabled = $true } | Out-Null
            }

        Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Rotate-DkimSigningConfig' -Parameters @{ Identity = $d; KeySize = $TargetBits } -Object $d `
            -Description ("Move {0} to {1} bits if a shorter key remains active" -f $d, $TargetBits) -Reason 'A key rotation cannot be undone.' `
            -Test {
                param($a)
                $n = $a.parameters.Identity
                if (-not (Test-TcTargetDomain $n)) { return Test-TcPostponed $a ("{0} is not accepted in the target: run again after the domains are verified in the target" -f $n) }
                $k = Get-DkimConfiguration $n
                if (-not $k -or -not (Get-TcMember $k 'Enabled')) { return Test-TcPostponed $a ("signing of {0} not yet active" -f $n) }
                if (Test-Key2048 $k) { return $true }
                if ((Get-TcMember $k 'RotateOnDate') -and [datetime](Get-TcMember $k 'RotateOnDate') -gt (Get-TcRemediationNow)) { return Test-TcPostponed $a ("rotation of {0} in progress until {1:yyyy-MM-dd}: run again afterwards" -f $n, [datetime](Get-TcMember $k 'RotateOnDate')) }
                return $false
            }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($d in $Domains[$t]) {
        if (-not (Test-TcTargetDomain $d)) { New-TcRemediationResult Info ("{0}: not yet in the target, to resume after the domains are verified in the target" -f $d); continue }
        $k = Get-DkimConfiguration $d
        if (-not $k) { New-TcRemediationResult Blocking ("{0}: no DKIM configuration" -f $d); continue }
        if ((Get-TcMember $k 'Enabled') -and (Get-TcText $k 'Status') -eq 'Valid') { New-TcRemediationResult OK ("{0}: signature active" -f $d) } else { New-TcRemediationResult Blocking ("{0}: Enabled {1}, Status {2}" -f $d, (Get-TcMember $k 'Enabled'), (Get-TcMember $k 'Status')) }
        if (-not (Test-Key2048 $k)) { New-TcRemediationResult Warning ("{0}: keys of {1} and {2} bits, target {3}" -f $d, (Get-TcMember $k 'Selector1KeySize'), (Get-TcMember $k 'Selector2KeySize'), $TargetBits) }
        foreach ($s in 1, 2) {
            $expectedOne = ([string]$k."Selector${s}CNAME").TrimEnd('.')
            if (@(Resolve-TcDnsEntry -Name "selector$s._domainkey.$d" -Type CNAME | Where-Object { (Get-TcMember $_ 'value') -eq $expectedOne }).Count) { New-TcRemediationResult OK ("selector$s._domainkey.$d published") } else { New-TcRemediationResult Blocking ("selector$s._domainkey.$d missing from public DNS") }
        }
    }
}
Close-TcRemediation

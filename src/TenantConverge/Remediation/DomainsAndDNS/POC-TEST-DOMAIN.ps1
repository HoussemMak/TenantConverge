# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Moves the POC test domain from a source to the target (procedure POC-TEST-DOMAIN).

.DESCRIPTION
    Decision: decisions\POC-TEST-DOMAIN.csv. Enter Use and the name of the domain in Note.
    With no decision, nothing is planned. A production domain or an onmicrosoft.com domain is refused.

    The script removes the domain from the source and waits for the removal to finish, adds it to the target, publishes the verification
    TXT, verifies the domain, turns on mail, then publishes MX, SPF and Autodiscover. The values are only known once the domain is added:
    these actions read the target when they run.
    The domain must have no reference left in the source: otherwise the script stops and names them.

    DNS host with no API: the instruction shows, the script watches the public DNS and goes on alone.
    No undo for the removal from the source: going back needs the procedure the other way around.
    The send and receive test, with the end-to-end delay, stays to be done by a person.
#>
$c = Open-TcRemediation

$RemovalMinutes = 60

function Test-DomainVerified {
    param([string]$Domain)
    $d = @(Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/domains' -All | Where-Object { (Get-TcMember $_ 'id') -eq $Domain }) | Select-Object -First 1
    return [bool]($d -and (Get-TcMember $d 'isVerified'))
}

$productionDomains = @(foreach ($t in (Get-TcSourceRole)) { (Get-TcMember (Get-TcRemediationTenant $t) 'Domains') }) + @(Get-TcRemediationTable 'Target' 'domains' | ForEach-Object { $_['Domain'] })
$productionDomains = @($productionDomains | ForEach-Object { ([string]$_).ToLowerInvariant() })

$decisions = @(Get-TcDecision -Name 'POC-TEST-DOMAIN' -Proposal @($c.Tenants | ForEach-Object { [ordered]@{ Tenant = $_; Object = 'Test domain (name in Note)' } }) -Key 'Tenant', 'Object' -Choice 'Use')

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $row = $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | Select-Object -First 1
    if (-not $row) { Write-TcRemediationNote 'No test domain decided: nothing to move.'; continue }
    $d = ((Get-TcText $row 'Note')).Trim().ToLowerInvariant()
    if ($d -notmatch '^([a-z0-9-]+\.)+[a-z]{2,}$' -or $d -like '*.onmicrosoft.com' -or $d -in $productionDomains) { Write-TcRemediationAlert "$d refused: enter a valid test domain, outside production, in Note."; continue }
    $h = Get-TcDnsHost $d
    Write-TcRemediationNote ("Test domain {0}, DNS host {1}" -f $d, $h)

    Add-TcBlockAction -Tenant $t -Service Graph -Object $d -Description "Remove $d from $t and wait for the removal to finish" -Critical -Data @{ Domain = $d } `
        -Reason 'To go back: remove the domain from the target, then add it back to the source.' `
        -Test {
            param($a)
            if (-not (Test-TcTenantDomain -Tenant $a.tenant -Domain $a.data.Domain)) { return $true }
            $refs = @(Invoke-TcGraph -Tenant $a.tenant -Uri "v1.0/domains/$($a.data.Domain)/domainNameReferences" -All)
            if ($refs.Count) { throw ("{0} is still referenced by {1} object(s): {2}" -f $a.data.Domain, $refs.Count, (($refs | ForEach-Object { (Get-TcMember $_ 'displayName') }) -join ', ')) }
            return $false
        } `
        -Block {
            param($a)
            Invoke-TcGraph -Tenant $a.tenant -Method DELETE -Uri "v1.0/domains/$($a.data.Domain)" | Out-Null
            $end = (Get-TcRemediationNow).AddMinutes($RemovalMinutes)
            while (Test-TcTenantDomain -Tenant $a.tenant -Domain $a.data.Domain) {
                if ((Get-TcRemediationNow) -ge $end) { throw "$($a.data.Domain) still present after $RemovalMinutes minutes: run again later." }
                Wait-TcRemediation -Seconds 30
            }
        }

    Add-TcGraphAction -Tenant 'Target' -Method POST -Uri 'v1.0/domains' -Body @{ id = $d } -Object $d -Description "Add $d to the target" -Critical `
        -Test { param($a) Test-TcTenantDomain -Tenant 'Target' -Domain $a.object }

    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object $d -Description "Publish the verification TXT of $d" -Critical -Data @{ Domain = $d } `
        -Reason 'TXT with no effect once the domain is verified; it goes away with the domain.' `
        -Test { param($a) Test-DomainVerified -Domain $a.data.Domain } `
        -Block {
            param($a)
            $n = $a.data.Domain
            $txt = (Get-TcMember (@(Invoke-TcGraph -Tenant 'Target' -Uri "v1.0/domains/$n/verificationDnsRecords" -All | Where-Object { (Get-TcMember $_ 'recordType') -eq 'Txt' }) | Select-Object -First 1) 'text')
            if (-not $txt) { throw "Verification TXT value not found for $n" }
            Invoke-TcDnsRecord -Action $a -Zone $n -Name $n -Type TXT -Value $txt -Verb Add
        }

    Add-TcGraphAction -Tenant 'Target' -Method POST -Uri "v1.0/domains/$d/verify" -Object $d -Description "Verify $d in the target" -Critical `
        -Reason 'The verification goes away when the domain is removed.' -Test { param($a) Test-DomainVerified -Domain $a.object }

    Add-TcGraphAction -Tenant 'Target' -Method PATCH -Uri "v1.0/domains/$d" -Body @{ supportedServices = @('Email', 'OfficeCommunicationsOnline') } -Object $d -Description "Enable mail and Teams for $d" `
        -Test { param($a) 'Email' -in @((Get-TcMember (Invoke-TcGraph -Tenant 'Target' -Uri "v1.0/domains/$($a.object)") 'supportedServices')) }

    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object $d -Description "Publish the MX, SPF and Autodiscover of $d" -Data @{ Domain = $d } `
        -Reason 'Records of the test domain: they go away with its zone at the end of the POC.' -Block {
            param($a)
            $n = $a.data.Domain
            foreach ($r in @(Invoke-TcGraph -Tenant 'Target' -Uri "v1.0/domains/$n/serviceConfigurationRecords" -All | Where-Object { (Get-TcMember $_ 'supportedService') -eq 'Email' })) {
                $type, $name, $value, $priority = switch ((Get-TcMember $r 'recordType')) {
                    'Mx' { 'MX', $n, (Get-TcMember $r 'mailExchange'), [int](Get-TcMember $r 'preference') }
                    'Txt' { 'TXT', $n, (Get-TcMember $r 'text'), 0 }
                    'CName' { 'CNAME', (Get-TcMember $r 'label'), (Get-TcMember $r 'canonicalName'), 0 }
                }
                if (-not $type) { continue }
                Invoke-TcDnsRecord -Action $a -Zone $n -Name $name -Type $type -Value $value -Priority $priority
            }
        }

    Add-TcManualAction -Tenant 'Target' -Object "Mail test $d" -Description "Test sending and receiving on $d and measure the delay" -Instruction @(
        "Send an email from and to a mailbox of $d, internally and externally.",
        "Record the end-to-end delay and the SPF, DKIM and DMARC results in the POC report.")
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($l in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t }) {
        $d = ((Get-TcText $l 'Note')).Trim().ToLowerInvariant()
        if (Test-TcTenantDomain -Tenant $t -Domain $d) { New-TcRemediationResult Blocking "$d still present in $t" } else { New-TcRemediationResult OK "$d removed from $t" }
        if (Test-DomainVerified -Domain $d) { New-TcRemediationResult OK "$d verified in the target" } else { New-TcRemediationResult Blocking "$d not verified in the target" }
    }
}
Close-TcRemediation

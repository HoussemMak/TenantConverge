# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the flow of the migrated domains decided and adjusts the connectors of the target accordingly (procedure EXO-CONNECTORS).

.DESCRIPTION
    The mail flow of the target is in production: nothing is written without a decision. A mail gateway may exist in both tenants, with
    its own connectors.

    Data read: connectors of the source and the target, dnsDomains table (MX, SPF, inbound flow).

    Decisions:
      decisions\EXO-CONNECTORS-FLOW.csv, one row per migrated domain: Direct or Gateway.
      decisions\EXO-CONNECTORS.csv, one row per connector of the source:
        Covered : the target already has the equivalent, nothing to create (proposed when the name or the IP addresses match);
        Create  : recreated in the target with the prefix of the source;
        Drop    : nothing to do.

    Security choices:
      -RestrictDomainsToIPAddresses is not passed. With -SenderDomains '*', it would reject any email that does not come from these IP
      addresses, while the MX of the target arrives directly on Exchange Online. Locking only the migrated domains, with
      -AssociatedAcceptedDomains, needs them to be in the target already: it is a separate step, after the cutover.
      An outbound connector with no domain is created with -IsTransportRuleScoped, otherwise it would touch all outbound mail.
      -EFSkipLastIP is turned on only if a domain goes through the gateway.

    Guards: refuses an inbound connector whose IP addresses are already covered in the target, and an outbound connector to *.
    Limits: the cutover publishes the Microsoft records; a domain on Gateway needs them adapted by hand.
#>
$c = Open-TcRemediation

function Get-DecisionList { param([string]$Text) return @($Text -split ';\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Get-NormalizedName { param([string]$Name) return ($Name -replace '\s+', '').ToLowerInvariant() }

function Get-ConnectorDomain {
    <# smtp:*;1 in the snapshot: keeps *. #>
    param([string]$Text)
    if ($Text -match '^smtp:([^;]+);\d+$') { return @($Matches[1]) }
    return @(Get-DecisionList $Text)
}

$TargetConnectors = @(Get-TcRemediationTable 'Target' 'connectors')

function Find-EquivalentConnector {
    <# Connector of the target in the same direction, by name or by shared IP addresses. #>
    param($Connector)
    $hosts = @(Get-DecisionList $Connector['Hosts or IPs'])
    foreach ($x in $TargetConnectors | Where-Object { $_['Direction'] -eq $Connector['Direction'] }) {
        if ((Get-NormalizedName $x['Name']) -eq (Get-NormalizedName $Connector['Name'])) { return $x }
        if ($Connector['Direction'] -eq 'Inbound' -and @(Get-DecisionList $x['Hosts or IPs'] | Where-Object { $_ -in $hosts }).Count) { return $x }
    }
    return $null
}

$flow = foreach ($t in $c.Tenants) {
    foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        $l = Get-TcRemediationTable $t 'dnsSummary' | Where-Object { $_['Domain'] -eq $d } | Select-Object -First 1
        [ordered]@{ Tenant = $t; Domain = $d; MX = $(if ($l) { $l['MX'] }); 'Inbound mail flow' = $(if ($l) { $l['Inbound mail flow'] }); SPF = $(if ($l) { $l['SPF'] }); Proposal = $(if ($l -and $l['Inbound mail flow'] -eq 'Exchange Online direct') { 'Direct' } else { '' }) }
    }
}
$flowDecisions = @(Get-TcDecision -Name 'EXO-CONNECTORS-FLOW' -Proposal @($flow) -Key 'Tenant', 'Domain' -Choice 'Direct', 'Gateway')

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $list = @(Get-TcRemediationTable $t 'connectors')
    if (-not $list.Count -and -not (Test-TcCollectionComplete $t 'connectors')) { Write-TcRemediationAlert 'Incomplete connector collection: run Invoke-TcAssessment again'; continue }
    Write-TcRemediationNote ("{0} connector(s) in the source, {1} in the target" -f $list.Count, $TargetConnectors.Count)
    foreach ($x in $list) {
        $e = Find-EquivalentConnector $x
        [ordered]@{ Tenant = $t; Connector = $x['Name']; Direction = $x['Direction']; Type = $x['Type']; Domains = (@(Get-ConnectorDomain $x['Domains']) -join ', '); 'Hosts or IPs' = $x['Hosts or IPs']; TLS = $x['TLS']
                    'Target equivalent' = $(if ($e) { $e['Name'] }); Proposal = $(if ($e) { 'Covered' } else { '' }) }
    }
}
$decisions = @(Get-TcDecision -Name 'EXO-CONNECTORS' -Proposal @($proposals) -Key 'Tenant', 'Connector' -Choice 'Create', 'Covered', 'Drop')

$Created = [System.Collections.Generic.List[object]]::new()
foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -in $c.Tenants -and (Get-TcMember $_ 'Decision') -eq 'Create' }) {
    $t = (Get-TcMember $d 'Tenant')
    $x = Get-TcRemediationTable $t 'connectors' | Where-Object { $_['Name'] -eq (Get-TcMember $d 'Connector') } | Select-Object -First 1
    if (-not $x) { Write-TcRemediationAlert ("{0}: connector missing from the snapshot" -f (Get-TcMember $d 'Connector')); continue }
    $name = '{0}-{1}' -f (Get-TcMember (Get-TcRemediationTenant $t) 'Prefix'), $x['Name']
    $hosts = @(Get-DecisionList $x['Hosts or IPs'])
    $domains = @(Get-ConnectorDomain $x['Domains'])

    if ($x['Direction'] -eq 'Inbound') {
        $e = Find-EquivalentConnector $x
        $commonItems = if ($e) { @(Get-DecisionList $e['Hosts or IPs'] | Where-Object { $_ -in $hosts }) } else { @() }
        if ((Get-TcCount $commonItems)) { Write-TcRemediationAlert ("{0}: {1} already covers {2}; two connectors on the same IP addresses are not created here" -f $x['Name'], $e['Name'], ($commonItems -join ', ')); continue }
        $p = @{ Name = $name; ConnectorType = $x['Type']; SenderDomains = $domains; SenderIPAddresses = $hosts; RequireTls = (ConvertTo-TcBoolean $x['TLS']) }
        if (@($flowDecisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Gateway' }).Count) { $p.EFSkipLastIP = $true }
        Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'New-InboundConnector' -Parameters $p -Object $name -Description ("Create the inbound connector {0}, restricted to {1} IP address(es)" -f $name, $hosts.Count) `
            -Test { param($a) [bool](Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-InboundConnector' | Where-Object Name -eq $a.parameters.Name) } `
            -Undo @{ command = 'Remove-InboundConnector'; parameters = @{ Identity = $name } }
    }
    else {
        if ('*' -in $domains) { Write-TcRemediationAlert ("{0}: an outbound connector to * would divert all the email of the target, creation refused" -f $x['Name']); continue }
        $p = @{ Name = $name; ConnectorType = $x['Type']; UseMXRecord = $false; SmartHosts = $hosts }
        if ($x['TLS'] -in 'EncryptionOnly', 'CertificateValidation', 'DomainValidation') { $p.TlsSettings = $x['TLS'] }
        if ($domains.Count) { $p.RecipientDomains = $domains } else { $p.IsTransportRuleScoped = $true }
        Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'New-OutboundConnector' -Parameters $p -Object $name -Description ("Create the outbound connector {0} to {1}" -f $name, ($hosts -join ', ')) `
            -Test { param($a) [bool](Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-OutboundConnector' | Where-Object Name -eq $a.parameters.Name) } `
            -Undo @{ command = 'Remove-OutboundConnector'; parameters = @{ Identity = $name } }
    }
    $Created.Add(@{ Name = $name; Direction = $x['Direction']; Tenant = $t })
}

foreach ($t in $c.Tenants) {
    $choice = @($flowDecisions | Where-Object Tenant -eq $t)
    if (-not $choice.Count) { continue }
    $gateway = @($choice | Where-Object 'Decision' -eq 'Gateway' | ForEach-Object { (Get-TcMember $_ 'Domain') })
    $instruction = @(("Record the decided flow in the DNS manifest entry: {0}." -f (@($choice | ForEach-Object { '{0} {1}' -f (Get-TcMember $_ 'Domain'), (Get-TcMember $_ 'Decision') }) -join ', ')))
    if ($gateway.Count) { $instruction += ("When the MX, SPF and Autodiscover records move, the MX published is the Microsoft one: for {0}, adapt the MX and the SPF to the gateway before the cutover." -f ($gateway -join ', ')) }
    else { $instruction += "Direct flow: remove the gateway from the SPF if it no longer sends for these domains." }
    Add-TcManualAction -Tenant 'Target' -Object "DNS sheet $t" -Description ("Carry the flow of {0} into the DNS manifest entry (when the MX, SPF and Autodiscover records move)" -f $t) -Instruction $instruction
}
if ($Created.Count) {
    Add-TcManualAction -Tenant 'Target' -Object 'Connector test' -Description ("Test the {0} connector(s) created before the MX, SPF and Autodiscover records move" -f $Created.Count) `
        -Instruction @("Validate the connectors in the Exchange admin center > Mail flow > Connectors.", 'Check that the mail flow of the current domains of the target does not change: otherwise a failure is only discovered during the cutover.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $inbound = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-InboundConnector')
    $outbound = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-OutboundConnector')
    foreach ($x in $Created | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t }) {
        $vu = if ((Get-TcMember $x 'Direction') -eq 'Inbound') { $inbound | Where-Object Name -eq (Get-TcMember $x 'Name') } else { $outbound | Where-Object Name -eq (Get-TcMember $x 'Name') }
        if ($vu) { New-TcRemediationResult OK ("{0} present, active: {1}" -f (Get-TcMember $x 'Name'), (Get-TcMember $vu 'Enabled')) } else { New-TcRemediationResult Blocking ("{0} missing from the target" -f (Get-TcMember $x 'Name')) }
    }
    $restricted = @($inbound | Where-Object { (Get-TcMember $_ 'RestrictDomainsToIPAddresses') -and '*' -in @((Get-TcMember $_ 'SenderDomains') | ForEach-Object { ([string]$_) -replace '^smtp:([^;]+).*$', '$1' }) })
    if ($restricted.Count) { New-TcRemediationResult Warning ("Connector(s) that reject any sender outside their IP addresses: {0}. To review with the direct MX of the target." -f (@((Get-TcMember $restricted 'Name')) -join ', ')) }
}
Close-TcRemediation

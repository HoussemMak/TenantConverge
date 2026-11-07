# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Recreates in the target, in audit mode and limited to the migrated domains, the chosen transport rules (procedure EXO-RULES).

.DESCRIPTION
    Data read: transport rules of the source and the target. The script first exports the rules of the source to XML to keep a
    reference. Import-TransportRuleCollection is never used: it would replace all the rules of the target.

    Decision: decisions\EXO-RULES.csv, one row per rule.
      Audit-Inbound  : recreated in audit, limited to messages to the migrated domains (RecipientDomainIs);
      Audit-Outbound : recreated in audit, limited to messages from the migrated domains (SenderDomainIs);
      Enforce        : moves a rule already created to enforcement;
      Covered        : the target already has this rule (proposed when the name is the same);
      Drop           : nothing to do (proposed for disabled rules and signatures, carried over by the signature tool).

    Two steps: Audit-* before the cutover. After reading the results, change the decision to Enforce and run again; moving to
    enforcement is postponed while the domains of the source are not in the target.

    Copying a rule: the conditions and actions are read in the source at run time. Only those of the list $Copiables are carried over.
    A rule that aims at a group, a connector or a recipient of the source cannot be moved: the action fails and says so, and the rule is
    recreated by hand. This copy has never run on a tenant.
    Limit: the priority order stays to be reviewed after the addition, the check lists the rules in order.
#>
$c = Open-TcRemediation

$Witnesses = @{}
$Metadata = @('Name', 'Identity', 'Priority', 'Mode', 'Enabled', 'Comments', 'ActivationDate', 'ExpiryDate', 'DlpPolicy', 'Confirm', 'WhatIf', 'UseLegacyRegex')
$Kept = @('RuleErrorAction', 'SenderAddressLocation', 'StopRuleProcessing')
$Conditions = @('FromScope', 'SentToScope', 'SenderDomainIs', 'RecipientDomainIs', 'FromAddressContainsWords', 'FromAddressMatchesPatterns', 'SenderIpRanges', 'RecipientAddressContainsWords', 'RecipientAddressMatchesPatterns', 'SubjectContainsWords', 'SubjectMatchesPatterns',
                'SubjectOrBodyContainsWords', 'SubjectOrBodyMatchesPatterns', 'HeaderContainsMessageHeader', 'HeaderContainsWords', 'HeaderMatchesMessageHeader', 'HeaderMatchesPatterns', 'AttachmentExtensionMatchesWords',
                'AttachmentNameMatchesPatterns', 'AttachmentSizeOver', 'MessageSizeOver', 'MessageTypeMatches', 'SCLOver', 'WithImportance')
$Actions = @('SetSCL', 'SetHeaderName', 'SetHeaderValue', 'RemoveHeader', 'PrependSubject', 'ApplyHtmlDisclaimerText', 'ApplyHtmlDisclaimerLocation', 'ApplyHtmlDisclaimerFallbackAction', 'RejectMessageReasonText', 'RejectMessageEnhancedStatusCode', 'DeleteMessage', 'Quarantine')
$Copiable = @($Kept + $Conditions + $Actions + @($Conditions | ForEach-Object { "ExceptIf$_" }))

function Get-TargetRule {
    param([string]$Name)
    return (Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-TransportRule' | Where-Object Name -eq $Name | Select-Object -First 1)
}

function ConvertTo-RuleParameter {
    <# Parameters of New-TransportRule from a rule read; refuses what aims at an object specific to the source. #>
    param($Rule)
    $knownParameters = Get-TcCommandParameter -Command 'New-TransportRule'
    $p = @{}
    $refused = [System.Collections.Generic.List[string]]::new()
    foreach ($x in $Rule.PSObject.Properties) {
        if (-not $knownParameters.ContainsKey((Get-TcMember $x 'Name')) -or (Get-TcMember $x 'Name') -in $Metadata) { continue }
        $v = (Get-TcMember $x 'Value')
        if ($null -eq $v -or ($v -is [bool] -and -not $v) -or ([string]$v) -eq '' -or ($v -is [System.Collections.ICollection] -and -not (Get-TcCount $v))) { continue }
        if ((Get-TcMember $x 'Name') -in $Copiable) { $p[$x.Name] = $v } else { $refused.Add((Get-TcMember $x 'Name')) }
    }
    if ($refused.Count) { throw ("Rule that cannot be carried over, to recreate by hand: {0}" -f ($refused -join ', ')) }
    return $p
}

$TargetNames = @(Get-TcRemediationTable 'Target' 'transportRules' | ForEach-Object { $_['Name'] })

function Get-TargetName {
    param([string]$Prefix, [string]$Name)
    $n = '{0}-{1}' -f $Prefix, $Name
    if ((Get-TcMember $n 'Length') -gt 64) { return $n.Substring(0, 64) }
    return $n
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $rules = @(Get-TcRemediationTable $t 'transportRules')
    if (-not $rules.Count -and -not (Test-TcCollectionComplete $t 'transportRules')) { Write-TcRemediationAlert 'Incomplete rule collection: run Invoke-TcAssessment again'; continue }
    Write-TcRemediationNote ("{0} rule(s), of which {1} active" -f $rules.Count, @($rules | Where-Object { $_['State'] -eq 'Enabled' }).Count)
    Add-TcBlockAction -Tenant $t -Service Exo -Object 'Rules export' -Description ("Export the rules of {0} as XML, as a reference" -f $t) -Data @{ Tenant = $t } -Reason 'Read only: the file stays in the log folder.' `
        -Block {
            param($a)
            $f = Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command 'Export-TransportRuleCollection'
            if (-not (Get-TcMember $f 'FileData')) { throw 'Export-TransportRuleCollection returned no content' }
            $outputFolder = Join-Path $script:TcRemediationRun['Folder'] 'exports'
            New-Item -ItemType Directory -Force -Path $outputFolder | Out-Null
            [System.IO.File]::WriteAllBytes((Join-Path $outputFolder ("rules-{0}.xml" -f $a.tenant)), [byte[]](Get-TcMember $f 'FileData'))
        }
    foreach ($r in $rules) {
        $text = ([string]$r['Description']) -replace '\s+', ' '
        $proposal = if ($r['Name'] -in $TargetNames) { 'Covered' } elseif ($r['State'] -ne 'Enabled' -or $text -match 'signature|disclaimer') { 'Drop' } else { '' }
        [ordered]@{ Tenant = $t; 'Rule' = $r['Name']; 'State' = $r['State']; 'Priority' = $r['Priority']; Mode = $r['Mode']; Description = $text; Proposal = $proposal }
    }
}

$decisions = @(Get-TcDecision -Name 'EXO-RULES' -Proposal @($proposals) -Key 'Tenant', 'Rule' -Choice 'Audit-Inbound', 'Audit-Outbound', 'Enforce', 'Covered', 'Drop')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -in $c.Tenants -and (Get-TcMember $_ 'Decision') -in 'Audit-Inbound', 'Audit-Outbound', 'Enforce' }) {
    $t = (Get-TcMember $d 'Tenant')
    $i = Get-TcRemediationTenant $t
    $name = Get-TargetName (Get-TcMember $i 'Prefix') (Get-TcMember $d 'Rule')

    if ((Get-TcMember $d 'Decision') -eq 'Enforce') {
        $Witnesses[$name] = (@((Get-TcMember $i 'Domains')) | Select-Object -First 1)
        Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Set-TransportRule' -Parameters @{ Identity = $name; Mode = 'Enforce' } -Object $name -Description ("Switch {0} to enforcement" -f $name) `
            -Test {
                param($a)
                $witness = $Witnesses[$a.parameters.Identity]
                if (-not (Test-TcTargetDomain $witness)) { return Test-TcPostponed $a ("{0} is not accepted in the target: run again after the cutover" -f $witness) }
                $r = Get-TargetRule $a.parameters.Identity
                if (-not $r) { return Test-TcPostponed $a ("rule {0} missing from the target: create it first with Audit-Inbound or Audit-Outbound" -f $a.parameters.Identity) }
                $a.undo = @{ command = 'Set-TransportRule'; parameters = @{ Identity = $a.parameters.Identity; Mode = (Get-TcText $r 'Mode') } }
                return (Get-TcText $r 'Mode') -eq 'Enforce'
            }
        continue
    }

    $scope = if ((Get-TcMember $d 'Decision') -eq 'Audit-Inbound') { 'RecipientDomainIs' } else { 'SenderDomainIs' }
    Add-TcBlockAction -Tenant 'Target' -Service Exo -Object $name -Data @{ Source = $t; Rule = (Get-TcMember $d 'Rule'); Name = $name; Scope = $scope; Domains = @((Get-TcMember $i 'Domains')) } `
        -Description ("Recreate {0} in audit mode, limited to {1}" -f $name, (@((Get-TcMember $i 'Domains')) -join ', ')) `
        -Test { param($a) [bool](Get-TargetRule $a.data.Name) } `
        -Undo @{ command = 'Remove-TransportRule'; parameters = @{ Identity = $name } } `
        -Block {
            param($a)
            $x = $a.data
            $r = Invoke-TcServiceCommand -Tenant (Get-TcMember $x 'Source') -Service Exo -Command 'Get-TransportRule' -Parameters @{ Identity = (Get-TcMember $x 'Rule') }
            $p = ConvertTo-RuleParameter $r
            $p.Name = (Get-TcMember $x 'Name')
            $p.Mode = 'Audit'
            $p[$x.Scope] = @((Get-TcMember $x 'Domains'))
            $p.Comments = "Carry over rule {0} from {1}" -f (Get-TcMember $x 'Rule'), (Get-TcMember $x 'Source')
            Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'New-TransportRule' -Parameters $p | Out-Null
        }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $i = Get-TcRemediationTenant $t
    $rules = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-TransportRule')
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -in 'Audit-Inbound', 'Audit-Outbound', 'Enforce' }) {
        $name = Get-TargetName (Get-TcMember $i 'Prefix') (Get-TcMember $d 'Rule')
        $r = $rules | Where-Object Name -eq $name
        if (-not $r) { New-TcRemediationResult Blocking ("{0} missing from the target" -f $name); continue }
        $scope = @((Get-TcMember $r 'SenderDomainIs')) + @((Get-TcMember $r 'RecipientDomainIs')) | Where-Object { $_ }
        if (-not @($scope).Count) { New-TcRemediationResult Blocking ("{0} without a domain scope: it can affect all the email of the target" -f $name) }
        else { New-TcRemediationResult OK ("{0}: mode {1}, priority {2}" -f $name, (Get-TcMember $r 'Mode'), (Get-TcMember $r 'Priority')) }
    }
}
Close-TcRemediation

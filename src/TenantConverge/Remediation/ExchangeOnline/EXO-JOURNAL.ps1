# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the archiving obligation confirmed and carries journaling over to the target if required (procedure EXO-JOURNAL).

.DESCRIPTION
    Data read: journal rules of the source and the target, JournalingReportNdrTo address of the target.

    Decision: decisions\EXO-JOURNAL.csv, one row per rule of the source.
      Covered  : the target already journals all mail with a global rule (proposed if it exists);
      Recreate : creates the prefixed rule in the target. The address aimed at, a list of migrated accounts, goes in the Note column;
      Purview  : the need goes through a Purview retention, with the target design;
      Drop     : no obligation.

    Guard: with no address aimed at, the rule is not created. A global rule to the service of the source would journal all the mail of
    the target. An Exchange Online mailbox cannot receive a journal: the destination stays that of the archiving service. Limits: the
    retention period is a point to confirm with the customer. There must be no period without archiving between the freeze of the
    source and the target rule.
#>
$c = Open-TcRemediation

$TargetRules = @(Get-TcRemediationTable 'Target' 'journalRules')
$NdrAddress = [string](Get-TcRemediationValue 'Target' 'exchangeSettings' 'Transport.JournalingReportNdrTo')

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $rules = @(Get-TcRemediationTable $t 'journalRules')
    if (-not $rules.Count -and -not (Test-TcCollectionComplete $t 'journalRules')) { Write-TcRemediationAlert 'Incomplete journal rule collection: run Invoke-TcAssessment again'; continue }
    Write-TcRemediationNote ("{0} journal rule(s) in the source, {1} in the target; undelivered reports of the target: {2}" -f $rules.Count, $TargetRules.Count, $(if ($NdrAddress) { 'address set' } else { 'address missing' }))
    foreach ($r in $rules) {
        $globalRule = $TargetRules | Where-Object { $_['Scope'] -eq 'Global' -and -not $_['Recipient'] -and (ConvertTo-TcBoolean $_['Enabled']) } | Select-Object -First 1
        [ordered]@{ Tenant = $t; 'Rule' = $r['Name']; Recipient = $r['Recipient']; 'Journal address' = $r['Journal address']; 'Scope' = $r['Scope']; Active = $r['Enabled']
                    'Global target rule' = $(if ($globalRule) { $globalRule['Name'] }); Proposal = $(if ($globalRule) { 'Covered' } else { '' }) }
    }
}

$decisions = @(Get-TcDecision -Name 'EXO-JOURNAL' -Proposal @($proposals) -Key 'Tenant', 'Rule' -Choice 'Covered', 'Recreate', 'Purview', 'Drop')
$Created = [System.Collections.Generic.List[string]]::new()

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -in $c.Tenants }) {
    $t = (Get-TcMember $d 'Tenant')
    if ((Get-TcMember $d 'Decision') -eq 'Purview') {
        Add-TcManualAction -Tenant 'Target' -Object "Retention $t" -Description ("Cover the archiving of {0} with a Purview retention" -f $t) `
            -Instruction @(("Record the need of {0} in the target design, with its retention period." -f $t), 'Keep the source rule active until the freeze: no period without archiving.')
        continue
    }
    if ((Get-TcMember $d 'Decision') -ne 'Recreate') { continue }
    $aimed = ((Get-TcText $d 'Note')).Trim()
    if ($aimed -notmatch '^[^@\s]+@[^@\s]+$') { Write-TcRemediationAlert ("{0}: enter in the Note column the address concerned, a list of the migrated accounts. Rule not created." -f (Get-TcMember $d 'Rule')); continue }
    if (-not $NdrAddress) { Write-TcRemediationAlert 'JournalingReportNdrTo is empty in the target: define a dedicated mailbox, not journaled, before creating the rule.' }
    $name = '{0}-{1}' -f (Get-TcMember (Get-TcRemediationTenant $t) 'Prefix'), (Get-TcMember $d 'Rule')
    $Created.Add($name)
    Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'New-JournalRule' -Parameters @{ Name = $name; JournalEmailAddress = (Get-TcMember $d 'Journal address'); Scope = (Get-TcMember $d 'Scope'); Recipient = $aimed; Enabled = $true } -Object $name `
        -Description ("Create the journal rule {0} for {1}" -f $name, $aimed) `
        -Test { param($a) [bool](Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-JournalRule' | Where-Object Name -eq $a.parameters.Name) } `
        -Undo @{ command = 'Remove-JournalRule'; parameters = @{ Identity = $name } }
}

Invoke-TcRemediationPlan -Verify {
    $rules = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-JournalRule')
    foreach ($n in $Created) {
        $r = $rules | Where-Object Name -eq $n
        if ($r -and (Get-TcMember $r 'Enabled')) { New-TcRemediationResult OK ("{0} active to {1}" -f $n, (Get-TcMember $r 'JournalEmailAddress')) } else { New-TcRemediationResult Blocking ("{0} missing or inactive" -f $n) }
    }
    $x = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-TransportConfig'
    if ((Get-TcMember $x 'JournalingReportNdrTo')) { New-TcRemediationResult OK ("undelivered reports: {0}" -f (Get-TcMember $x 'JournalingReportNdrTo')) } else { New-TcRemediationResult Warning 'JournalingReportNdrTo is empty in the target' }
}
Close-TcRemediation

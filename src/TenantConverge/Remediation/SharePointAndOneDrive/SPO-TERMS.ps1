# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Prepares the copy of the term store to the target before the content (procedure SPO-TERMS).

.DESCRIPTION
    Reads termStore, by non-system term group, and compares it with the target. decisions\SPO-TERMS.csv says for each group: Copy tool
    (preferred if the POC confirms it keeps the identifiers), Copy with PnP, or No copy.
    Copy with PnP exports the group of the source to XML and imports it into the target.
    Guard: a group with the same name in the target is not imported. Rename it first or merge the terms by hand.
    Limits: keeping the identifiers at the PnP import stays to confirm in the POC, and the account must be a term store administrator to
    write. Checking a metadata column on a pilot site stays to be done by a person.
#>
$c = Open-TcRemediation

$targetGroups = @(Get-TcRemediationTable 'Target' 'termStore' | ForEach-Object { $_['Group'] } | Select-Object -Unique)

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    if (-not (Test-TcCollectionComplete $t 'termStore')) { Write-TcRemediationAlert 'Term store collection incomplete: the list may be partial' }
    $rows = @(Get-TcRemediationTable $t 'termStore' | Where-Object { -not (ConvertTo-TcBoolean $_['System or collection']) })
    $groups = @($rows | Group-Object { $_['Group'] })
    $terms = (Get-TcMember (@($rows | ForEach-Object { [int]$_['Terms'] }) | Measure-Object -Sum) 'Sum')
    Write-TcRemediationNote ("{0} term group(s), {1} set(s), {2} term(s)" -f $groups.Count, $rows.Count, [int]$terms)
    foreach ($g in $groups) {
        $n = [int](Get-TcMember (@((Get-TcMember $g 'Group') | ForEach-Object { [int]$_['Terms'] }) | Measure-Object -Sum) 'Sum')
        [ordered]@{ Tenant = $t; Group = (Get-TcMember $g 'Name'); Sets = (Get-TcCount $g); Terms = $n; 'Exists in target' = $(if ((Get-TcMember $g 'Name') -in $targetGroups) { 'Yes' } else { 'No' }); Proposal = $(if ($n) { 'Copy tool' } else { 'No copy' }) }
    }
}
$decisions = @(Get-TcDecision -Name 'SPO-TERMS' -Proposal @($proposals) -Key 'Tenant', 'Group' -Choice 'Copy tool', 'Copy with PnP', 'No copy')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Copy with PnP' }) {
    if ((Get-TcMember $d 'Exists in target') -eq 'Yes') { Write-TcRemediationAlert ("{0}: the group {1} already exists in the target, the import is refused. Rename or merge by hand" -f (Get-TcMember $d 'Tenant'), (Get-TcMember $d 'Group')); continue }
    Add-TcBlockAction -Tenant 'Target' -Service Pnp -Object (Get-TcMember $d 'Group') -Description ("Copy the term group {0} from {1} to the target" -f (Get-TcMember $d 'Group'), (Get-TcMember $d 'Tenant')) -Data @{ Source = (Get-TcMember $d 'Tenant'); Group = (Get-TcMember $d 'Group') } `
        -Test { param($a) [bool](@(Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Get-PnPTermGroup') | Where-Object { (Get-TcMember $_ 'Name') -eq $a.data.Group }) } `
        -Block {
            param($a)
            $f = Join-Path $script:TcRemediationRun['Folder'] ("exports/terms-{0}-{1}.xml" -f $a.data.Source, ($a.data.Group -replace '[^\w-]', '_'))
            Invoke-TcServiceCommand -Tenant $a.data.Source -Service Pnp -Command 'Export-PnPTermGroupToXml' -Parameters @{ Identity = $a.data.Group; Out = $f; FullTemplate = $true; Force = $true } | Out-Null
            Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Import-PnPTermGroupFromXml' -Parameters @{ Path = $f } | Out-Null
            $a.undo = @{ command = 'Remove-PnPTermGroup'; parameters = @{ Identity = $a.data.Group; Force = $true } }
        }
}
foreach ($t in @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -in 'Copy tool', 'Copy with PnP' } | ForEach-Object { (Get-TcMember $_ 'Tenant') } | Select-Object -Unique)) {
    Add-TcManualAction -Tenant $t -Object 'Term identifiers' -Description "Check the identifiers on a sample, then a metadata column on a pilot site" `
        -Instruction @('The term store is copied before the sites. Without the same identifiers, the copied columns lose their link to the terms.', 'Compare Get-PnPTermSet -TermGroup <group> | Format-Table Name,Id between the source and the target.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $wantedRows = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Copy with PnP' -and (Get-TcMember $_ 'Exists in target') -ne 'Yes' } | ForEach-Object { (Get-TcMember $_ 'Group') })
    if (-not $wantedRows.Count) { return }
    $presentItems = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Pnp -Command 'Get-PnPTermGroup' | ForEach-Object { (Get-TcMember $_ 'Name') })
    foreach ($g in $wantedRows) { if ($g -in $presentItems) { New-TcRemediationResult OK "group $g present in the target" } else { New-TcRemediationResult Blocking "group $g missing from the target" } }
}
Close-TcRemediation

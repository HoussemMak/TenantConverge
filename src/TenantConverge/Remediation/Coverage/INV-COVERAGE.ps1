# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Draws up the coverage of the assessment by tenant and says what to rerun (procedure INV-COVERAGE).

.DESCRIPTION
    Reads the coverage of the snapshot and classes each collector that is not OK:
      To rerun  : a module was missing, run Invoke-TcAssessment again for this collector;
      Explained : license or service missing, the reason goes in the report;
      To handle : insufficient access, a person gets the role or the consent.
    Read only on the tenants.
    Limits: any extended access needs the written agreement of the customer. eDiscovery cases are not supported by Microsoft in
    application mode.
#>
$c = Open-TcRemediation

function Get-RowHandling {
    param($Area)
    $text = '{0} {1}' -f (Get-TcProperty $Area 'status'), (Get-TcProperty $Area 'message')
    if ($text -match 'Module missing') { return 'To rerun' }
    if ($text -match 'License or service missing|not licensed') { return 'Explained' }
    'To handle'
}

$report = [System.Collections.Generic.List[object]]::new()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $areas = @(@(Get-TcProperty $script:TcRemediationRun['Snapshot'] 'coverage' @()) | Where-Object { (Get-TcProperty $_ 'role') -eq $t })
    $incomplete = @($areas | Where-Object { (Get-TcProperty $_ 'status') -ne 'OK' })
    Write-TcRemediationNote ('{0} area(s), {1} incomplete' -f $areas.Count, $incomplete.Count)
    foreach ($area in $incomplete) {
        $report.Add([pscustomobject]@{
                Tenant = $t; Area = Get-TcProperty $area 'id'; Title = Get-TcProperty $area 'title'; Workload = Get-TcProperty $area 'workload'; Status = Get-TcProperty $area 'status'
                Message = Get-TcProperty $area 'message'; Remedy = Get-TcProperty $area 'remedy'; Handling = (Get-RowHandling $area)
            })
    }
    $rerun = @($incomplete | Where-Object { (Get-RowHandling $_) -eq 'To rerun' })
    if ($rerun.Count) {
        Add-TcManualAction -Tenant $t -Object 'Assessment' -Description ('Run the assessment again on {0}' -f (@($rerun | ForEach-Object { Get-TcProperty $_ 'id' }) -join ', ')) `
            -Instruction @('Install what is missing: Test-TcPrerequisite -Install', 'Then run Invoke-TcAssessment again. It writes a new snapshot, nothing to undo in the tenant.')
    }
    foreach ($area in @($incomplete | Where-Object { (Get-RowHandling $_) -eq 'To handle' })) {
        Add-TcManualAction -Tenant $t -Object ([string](Get-TcProperty $area 'id')) -Description ('Get access to the area {0} ({1})' -f (Get-TcProperty $area 'id'), (Get-TcProperty $area 'title')) `
            -Instruction @([string](Get-TcProperty $area 'message'), [string](Get-TcProperty $area 'remedy'), 'Any extended access needs the written agreement of the customer. Record the reason if the area stays incomplete.')
    }
}
[void](Export-TcRemediationReport -Name 'inventory-coverage' -Rows @($report))
Invoke-TcRemediationPlan
Close-TcRemediation

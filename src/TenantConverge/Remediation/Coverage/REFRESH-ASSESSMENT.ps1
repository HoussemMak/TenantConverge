# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Shows the age of the snapshot and says how to refresh it (procedure REFRESH-ASSESSMENT).

.DESCRIPTION
    Every remediation reads the snapshot and the plan. This script shows the age and the state of the last snapshot, tenant by
    tenant, with what was not fully read. To refresh them, run Invoke-TcAssessment. It writes nothing to a tenant.
#>
$c = Open-TcRemediation

$snapshot = $script:TcRemediationRun['Snapshot']
$finished = [string](Get-TcProperty (Get-TcProperty $snapshot 'meta') 'finished')
$date = [datetime]::MinValue
$dated = [datetime]::TryParse($finished, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)
$age = if ($dated) { ((Get-TcRemediationNow) - $date).TotalDays } else { $null }
$limit = [int](Get-TcRemediationOption 'MaxSnapshotAgeDays')

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $collectors = @(@(Get-TcProperty $snapshot 'coverage' @()) | Where-Object { (Get-TcProperty $_ 'role') -eq $t })
    $incomplete = @($collectors | Where-Object { (Get-TcProperty $_ 'status') -ne 'OK' })
    Write-TcRemediationNote ('Last snapshot: {0} collector(s), {1} incomplete' -f $collectors.Count, $incomplete.Count)
}

if ($null -eq $age) { Write-TcRemediationAlert 'This snapshot has no date.' }
else {
    Write-TcRemediationNote ('The snapshot is {0:N1} day(s) old, limit {1}.' -f $age, $limit)
    if ($age -gt $limit) { Write-TcRemediationAlert ('The snapshot is {0:N0} days old, the limit is {1}: Invoke-TcRemediation -Apply refuses to write until it is refreshed.' -f $age, $limit) }
}

Add-TcManualAction -Tenant 'Target' -Object 'Assessment' -Description 'Run the assessment again' `
    -Instruction @('Invoke-TcAssessment -Project <project file>', 'The new snapshot goes in the output folder, and the next remediation reads it.')

Invoke-TcRemediationPlan
Close-TcRemediation

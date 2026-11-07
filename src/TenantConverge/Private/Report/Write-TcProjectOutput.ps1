function Write-TcProjectOutput {
    <#
    .SYNOPSIS
    Writes the report and the workbook of a finished assessment, from what the run saved.

    .DESCRIPTION
    The snapshot, the findings and the plan are on disk by now. A report or a workbook that fails says so
    and leaves the other one: each can be written again alone, with New-TcReport or New-TcWorkbook.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][object]$Assessment,
        [switch]$SkipWorkbook
    )

    $outcome = [pscustomobject]@{ Report = $null; Workbook = $null }

    $planPath = [string](Get-TcProperty $Assessment 'Plan')
    if (-not $planPath) {
        Write-TcMessage -Message 'Without a plan there is no report and no workbook. Fix the cause, then run New-TcReport and New-TcWorkbook on the snapshot.' -Level Warning
        return $outcome
    }

    $snapshotPath = [string](Get-TcProperty $Assessment 'Snapshot')
    $plan = Read-TcJsonFile -Path $planPath
    $ruleSet = Read-TcJsonFile -Path (Join-Path (Get-TcProperty $Assessment 'Folder') 'findings.json')

    try {
        $report = New-TcReport -Project $Project -Snapshot $snapshotPath -Plan $plan -RuleSet $ruleSet
        if ($report) {
            $outcome.Report = [string](Get-TcProperty $report 'Path')
            Write-TcMessage -Message "Report: $($outcome.Report)" -Level Success
        }
    }
    catch { Write-TcMessage -Message "The report could not be written: $(Get-TcErrorText $_). The assessment is saved. Run New-TcReport to try again." -Level Warning }

    if ($SkipWorkbook) { return $outcome }

    try {
        $workbook = New-TcWorkbook -Project $Project -Snapshot (Read-TcSnapshot -Path $snapshotPath) -Plan $plan -RuleSet $ruleSet
        if ($workbook) {
            $outcome.Workbook = [string]$workbook
            Write-TcMessage -Message "Workbook: $($outcome.Workbook)" -Level Success
        }
    }
    catch { Write-TcMessage -Message "The workbook could not be written: $(Get-TcErrorText $_). The assessment is saved. Run New-TcWorkbook to try again." -Level Warning }

    $outcome
}

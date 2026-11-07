function Get-TcWorkbookScoreNote {
    <#
    .SYNOPSIS
    Says what the difference between Score and CollectedScore means for one tenant.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$Readiness
    )

    if (-not $Readiness) { return 'This tenant is not in the snapshot: nothing was read.' }

    $lines = @($Readiness.Workloads)
    $read = @($lines | Where-Object { $_.Coverage -notin 'Failed', 'None' })
    if (-not $read.Count) { return 'Nothing could be read in this tenant, so neither score says anything about it.' }

    $missing = @($lines | Where-Object { $_.Applicable -and -not $_.Complete })
    if (-not $missing.Count) { return 'Everything was read: the two scores agree.' }

    $names = @($missing | ForEach-Object {
            $why = if ($_.Coverage -in 'Failed', 'None') { 'not collected' } elseif ($_.RulesStopped) { 'rules stopped' } else { 'partly read' }
            '{0} ({1})' -f $_.Workload, $why
        })
    "What was not read counts for nothing in Score. This gap is unknown, not a result: $($names -join ', ')."
}

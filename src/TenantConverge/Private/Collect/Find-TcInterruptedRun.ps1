function Find-TcInterruptedRun {
    <#
    .SYNOPSIS
    Finds the latest run folder that has a partial snapshot and no final one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $runs = Get-ChildItem -LiteralPath $Path -Directory -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -like '*-assessment' -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'snapshot.partial.json')) -and
            -not (Test-Path -LiteralPath (Join-Path $_.FullName 'snapshot.json'))
        } |
        Sort-Object Name

    $last = $runs | Select-Object -Last 1
    if ($last) { $last.FullName }
}

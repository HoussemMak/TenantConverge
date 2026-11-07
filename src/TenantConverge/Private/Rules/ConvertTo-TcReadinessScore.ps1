function ConvertTo-TcReadinessScore {
    <#
    .SYNOPSIS
    Turns a sum of weights into a score from 0 to 100, a half rounding up. Nothing to count gives 0.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][double]$Sum,
        [Parameter(Mandatory)][int]$Count
    )

    if (-not $Count) { return 0 }
    [int][math]::Floor(100 * $Sum / $Count + 0.5)
}

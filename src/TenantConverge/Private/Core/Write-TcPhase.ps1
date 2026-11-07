function Write-TcPhase {
    <#
    .SYNOPSIS
    Announces a group of steps on screen and in the log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Title,
        [int]$StepCount
    )

    Write-TcMessage -Message ("{0} ({1} steps)" -f $Title.ToUpperInvariant(), $StepCount)
    Write-TcLog -Message "=== $Title"
}

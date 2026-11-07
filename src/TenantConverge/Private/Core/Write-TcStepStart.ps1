function Write-TcStepStart {
    <#
    .SYNOPSIS
    Announces one step on screen and in the log.
    #>
    [CmdletBinding()]
    param(
        [int]$Rank,
        [int]$Total,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Title,
        [string]$Purpose
    )

    Write-TcMessage -Message ("[{0:D2}/{1:D2}] {2,-8}{3}" -f $Rank, $Total, $Id, $Title)
    if ($Purpose) { Write-TcMessage -Message "        $Purpose" }
    Write-TcLog -Message "--- $Id $Title" -Step $Id
}

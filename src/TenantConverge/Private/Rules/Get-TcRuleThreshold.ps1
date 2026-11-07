function Get-TcRuleThreshold {
    <#
    .SYNOPSIS
    Returns a threshold of the running rule set.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name
    )

    $script:TcRuleRun['Thresholds'][$Name]
}

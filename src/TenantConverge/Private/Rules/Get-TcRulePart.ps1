function Get-TcRulePart {
    <#
    .SYNOPSIS
    Returns a piece of text a rule assembles itself, from the parts of its catalog entry.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][string]$Part
    )

    (Get-TcRuleCatalog)[$Id]['parts'][$Part]
}

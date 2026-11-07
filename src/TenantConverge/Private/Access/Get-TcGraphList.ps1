function Get-TcGraphList {
    <#
    .SYNOPSIS
    Returns every row of a Graph collection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Uri
    )

    @(Invoke-TcGraphRead -Uri $Uri -All)
}

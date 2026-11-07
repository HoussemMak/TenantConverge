function Get-TcGraphObject {
    <#
    .SYNOPSIS
    Returns one Graph response as it comes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Uri
    )

    Invoke-TcGraphRead -Uri $Uri
}

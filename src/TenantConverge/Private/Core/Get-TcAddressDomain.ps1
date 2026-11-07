function Get-TcAddressDomain {
    <#
    .SYNOPSIS
    Returns the lowercase domain of an address, or an empty text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string]$Address
    )

    if ($Address -match '@(.+)$') { return $Matches[1].ToLowerInvariant() }
    ''
}

function Get-TcAddressPrefix {
    <#
    .SYNOPSIS
    Returns the part of an address before the at sign, without any smtp: prefix.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string]$Address
    )

    if ($Address -match '^(?:smtp:)?([^@]+)@') { return $Matches[1] }
    $Address
}

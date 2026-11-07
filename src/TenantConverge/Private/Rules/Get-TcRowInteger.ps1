function Get-TcRowInteger {
    <#
    .SYNOPSIS
    Reads a column of a row as a whole number, negative included. An empty value is 0.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Position = 0)][AllowNull()]$Row,
        [Parameter(Mandatory, Position = 1)][string]$Column
    )

    $value = Get-TcProperty $Row $Column
    if ("$value" -eq '') { return 0 }
    [int]$value
}

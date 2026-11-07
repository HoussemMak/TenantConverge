function Get-TcRowNumber {
    <#
    .SYNOPSIS
    Reads a column of a row as a number, negative included. An empty value is 0.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Position = 0)][AllowNull()]$Row,
        [Parameter(Mandatory, Position = 1)][string]$Column
    )

    $value = Get-TcProperty $Row $Column
    if ("$value" -eq '') { return [double]0 }
    [double]$value
}

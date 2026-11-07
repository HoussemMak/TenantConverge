function Test-TcRowTrue {
    <#
    .SYNOPSIS
    Reads a column of a row as true or false. A missing column is false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowNull()]$Row,
        [Parameter(Mandatory, Position = 1)][string]$Column
    )

    Test-TcTrue (Get-TcProperty $Row $Column)
}

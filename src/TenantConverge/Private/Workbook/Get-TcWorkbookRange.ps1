function Get-TcWorkbookRange {
    <#
    .SYNOPSIS
    Returns the absolute address of a column of a table, with its sheet, for a formula.

    .DESCRIPTION
    A range is at least two rows long: EPPlus does not read a range of one cell as a range in COUNTIFS, and
    the row under a table is empty, so it changes no count.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][hashtable]$Table,
        [Parameter(Mandatory, Position = 1)][string]$Column
    )

    $letter = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($Table['Columns'][$Column])
    "'{0}'!`${1}`${2}:`${1}`${3}" -f $Table['SheetName'], $letter, $Table['First'], [math]::Max($Table['Last'], $Table['First'] + 1)
}

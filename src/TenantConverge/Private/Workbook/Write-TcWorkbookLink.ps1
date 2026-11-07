function Write-TcWorkbookLink {
    <#
    .SYNOPSIS
    Writes a link to a place in the workbook.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][int]$Column,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][hashtable]$Book
    )

    Write-TcWorkbookValue -Sheet $Sheet -Row $Row -Column $Column -Value $Text
    $cell = $Sheet.Cells[$Row, $Column]
    $cell.Hyperlink = [OfficeOpenXml.ExcelHyperLink]::new($Target, $Text)
    $cell.Style.Font.UnderLine = $true
    $cell.Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $Book['Theme']['Accent']))
}

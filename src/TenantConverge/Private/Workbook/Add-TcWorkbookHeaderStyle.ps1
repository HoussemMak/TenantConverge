function Add-TcWorkbookHeaderStyle {
    <#
    .SYNOPSIS
    Gives a row the look of a header, for a block that is not an Excel table.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book,
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][int]$LastColumn,
        [int]$FirstColumn = 1
    )

    $cells = $Sheet.Cells[$Row, $FirstColumn, $Row, $LastColumn]
    $cells.Style.Fill.PatternType = 'Solid'
    $cells.Style.Fill.BackgroundColor.SetColor((ConvertTo-TcWorkbookColor $Book['Theme']['Accent']))
    $cells.Style.Font.Color.SetColor([System.Drawing.Color]::White)
    $cells.Style.Font.Bold = $true
    $cells.Style.WrapText = $true
    $cells.Style.VerticalAlignment = 'Center'
}

function Add-TcWorkbookChartSeries {
    <#
    .SYNOPSIS
    Adds to a chart one column of a block of cells, named by the cell of its header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Chart,
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][int]$Header,
        [Parameter(Mandatory)][int]$FirstRow,
        [Parameter(Mandatory)][int]$LastRow,
        [Parameter(Mandatory)][int]$Column,
        [Parameter(Mandatory)][int]$CategoryColumn,
        [string]$Color
    )

    $series = $Chart.Series.Add($Sheet.Cells[$FirstRow, $Column, $LastRow, $Column], $Sheet.Cells[$FirstRow, $CategoryColumn, $LastRow, $CategoryColumn])
    $series.HeaderAddress = [OfficeOpenXml.ExcelAddress]::new($Sheet.Cells[$Header, $Column].FullAddressAbsolute)
    if ($Color) {
        $series.Fill.Style = 'SolidFill'
        $series.Fill.Color = ConvertTo-TcWorkbookColor $Color
    }
}

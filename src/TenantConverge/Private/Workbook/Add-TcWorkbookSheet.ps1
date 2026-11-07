function Add-TcWorkbookSheet {
    <#
    .SYNOPSIS
    Adds a tab with its title band and its way back to the dashboard.

    .DESCRIPTION
    Rows 5 to 8 of a tab with -Filters stay hidden: -AddSlicers shows them and puts its buttons there. A
    row added above the table afterwards would leave the links of the workbook pointing at the wrong row.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][hashtable]$Book,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Title,
        [AllowEmptyString()][string]$Subtitle = '',
        [AllowEmptyString()][string]$Legend = '',
        [string]$Color,
        [int]$Width = 14,
        [switch]$Filters
    )

    $theme = $Book['Theme']
    $sheet = $Book['Package'].Workbook.Worksheets.Add($Name)
    $sheet.View.ShowGridLines = $false
    $sheet.TabColor = ConvertTo-TcWorkbookColor $(if ($Color) { $Color } else { $theme['Accent'] })
    $sheet.PrinterSettings.Orientation = 'Landscape'
    $sheet.PrinterSettings.FitToPage = $true
    $sheet.PrinterSettings.FitToWidth = 1
    $sheet.PrinterSettings.FitToHeight = 0

    Write-TcWorkbookValue -Sheet $sheet -Row 1 -Column 1 -Value ('{0} - {1}' -f (Get-TcProperty $Book['Project'] 'name'), $Title)
    Write-TcWorkbookValue -Sheet $sheet -Row 2 -Column 1 -Value $Subtitle
    foreach ($row in 1, 2) {
        $band = $sheet.Cells[$row, 1, $row, $Width]
        $band.Style.Fill.PatternType = 'Solid'
        $band.Style.Fill.BackgroundColor.SetColor((ConvertTo-TcWorkbookColor $(if ($row -eq 1) { $theme['Band'] } else { $theme['Accent'] })))
        $band.Style.Font.Color.SetColor([System.Drawing.Color]::White)
    }
    $sheet.Cells[1, 1].Style.Font.Size = 16
    $sheet.Cells[1, 1].Style.Font.Bold = $true
    $sheet.Row(1).Height = 28
    $sheet.Row(2).Height = 19

    if ($Name -ne 'Dashboard') { Write-TcWorkbookLink -Sheet $sheet -Row 3 -Column 1 -Text 'Back to the dashboard' -Target "'Dashboard'!A1" -Book $Book }
    if ($Legend) {
        Write-TcWorkbookValue -Sheet $sheet -Row 4 -Column 1 -Value $Legend
        $sheet.Cells[4, 1].Style.Font.Italic = $true
        $sheet.Cells[4, 1].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Muted']))
    }

    if ($Filters) {
        foreach ($row in 5..8) {
            $sheet.Row($row).Height = 20
            $sheet.Row($row).Hidden = $true
        }
    }

    $Book['Sheets'][$Name] = $sheet
    $sheet
}

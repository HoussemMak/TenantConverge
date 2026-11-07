function Add-TcWorkbookChart {
    <#
    .SYNOPSIS
    Adds a chart that reads a block of cells of the same tab.

    .DESCRIPTION
    Readiness is clustered bars by tenant. Moments is stacked bars of items by moment and by status.
    Severity is a doughnut. A chart reads its labels from cells, so no text of a tenant is copied in it.

    Readiness reads hidden cells beside its table, because a tenant that was not read must draw no bar:
    those cells are empty for it, and the chart leaves a gap.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book,
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][ValidateSet('Readiness', 'Moments', 'Severity', 'View')][string]$Kind,
        [Parameter(Mandatory)][int]$Top,
        [Parameter(Mandatory)][int]$Left,
        [Parameter(Mandatory)][int]$Header,
        [Parameter(Mandatory)][int]$FirstRow,
        [Parameter(Mandatory)][int]$LastRow
    )

    $theme = $Book['Theme']
    $block = @{ Sheet = $Sheet; Header = $Header; FirstRow = $FirstRow; LastRow = $LastRow }

    switch ($Kind) {
        'Readiness' {
            $chart = $Sheet.Drawings.AddChart('Readiness', [OfficeOpenXml.Drawing.Chart.eChartType]::ColumnClustered)
            $chart.Title.Text = 'Readiness by tenant'
            Add-TcWorkbookChartSeries @block -Chart $chart -Column 16 -CategoryColumn 18 -Color $theme['Accent']
            Add-TcWorkbookChartSeries @block -Chart $chart -Column 17 -CategoryColumn 18 -Color 'B9C3D1'
            $chart.ShowHiddenData = $true
            $chart.DisplayBlanksAs = [OfficeOpenXml.Drawing.Chart.eDisplayBlanksAs]::Gap
            $chart.YAxis.MinValue = 0
            $chart.YAxis.MaxValue = 100
            $chart.SetSize(460, 260)
        }
        'Moments' {
            $chart = $Sheet.Drawings.AddChart('Moments', [OfficeOpenXml.Drawing.Chart.eChartType]::BarStacked)
            $chart.Title.Text = 'Items by moment and status'
            Add-TcWorkbookChartSeries @block -Chart $chart -Column 4 -CategoryColumn 2 -Color $theme['Good'][1]
            Add-TcWorkbookChartSeries @block -Chart $chart -Column 5 -CategoryColumn 2 -Color $theme['Accent']
            Add-TcWorkbookChartSeries @block -Chart $chart -Column 6 -CategoryColumn 2 -Color $theme['Bad'][1]
            Add-TcWorkbookChartSeries @block -Chart $chart -Column 7 -CategoryColumn 2 -Color 'B9C3D1'
            Add-TcWorkbookChartSeries @block -Chart $chart -Column 8 -CategoryColumn 2 -Color 'E2E8F0'
            $chart.XAxis.Orientation = 'MaxMin'
            $chart.YAxis.Crosses = 'Max'
            $chart.YAxis.RemoveGridlines()
            $chart.SetSize(480, 240)
        }
        'Severity' {
            $chart = $Sheet.Drawings.AddChart('Severity', [OfficeOpenXml.Drawing.Chart.eChartType]::Doughnut)
            $chart.Title.Text = 'Actions by severity'
            Add-TcWorkbookChartSeries @block -Chart $chart -Column 4 -CategoryColumn 2
            $chart.DataLabel.ShowPercent = $true
            $chart.SetSize(320, 220)
            Add-TcWorkbookChartPointColor -Chart $chart -Color @($theme['Bad'][1], 'D97A1E', $theme['Accent'], 'B9C3D1', 'E2E8F0')
        }
        'View' {
            $chart = $Sheet.Drawings.AddChart('View', [OfficeOpenXml.Drawing.Chart.eChartType]::BarStacked)
            $chart.Title.Text = 'Items by moment'
            Add-TcWorkbookChartSeries @block -Chart $chart -Column 5 -CategoryColumn 3 -Color $theme['Good'][1]
            Add-TcWorkbookChartSeries @block -Chart $chart -Column 6 -CategoryColumn 3 -Color 'B9C3D1'
            $chart.XAxis.Orientation = 'MaxMin'
            $chart.YAxis.Crosses = 'Max'
            $chart.YAxis.RemoveGridlines()
            $chart.SetSize(480, 240)
        }
    }

    $chart.Title.Font.Size = 12
    $chart.Legend.Position = 'Bottom'
    $chart.SetPosition($Top, 0, $Left, 0)
}

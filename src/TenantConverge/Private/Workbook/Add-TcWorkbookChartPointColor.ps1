function Add-TcWorkbookChartPointColor {
    <#
    .SYNOPSIS
    Gives each slice of a doughnut its color and a hole of 55 percent. EPPlus has no call for these.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Chart,
        [Parameter(Mandatory)][string[]]$Color
    )

    $document = $Chart.ChartXml
    $chartNamespace = 'http://schemas.openxmlformats.org/drawingml/2006/chart'
    $drawingNamespace = 'http://schemas.openxmlformats.org/drawingml/2006/main'
    $manager = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
    $manager.AddNamespace('c', $chartNamespace)

    $hole = $document.SelectSingleNode('//c:holeSize', $manager)
    if ($hole) { $hole.SetAttribute('val', '55') }

    $series = $document.SelectSingleNode('//c:ser', $manager)
    $before = $series.SelectSingleNode('c:dLbls', $manager)
    if (-not $before) { $before = $series.SelectSingleNode('c:cat', $manager) }

    for ($i = 0; $i -lt $Color.Count; $i++) {
        $point = $document.CreateElement('c', 'dPt', $chartNamespace)
        $index = $document.CreateElement('c', 'idx', $chartNamespace)
        $index.SetAttribute('val', [string]$i)
        [void]$point.AppendChild($index)
        $shape = $document.CreateElement('c', 'spPr', $chartNamespace)
        $fill = $document.CreateElement('a', 'solidFill', $drawingNamespace)
        $rgb = $document.CreateElement('a', 'srgbClr', $drawingNamespace)
        $rgb.SetAttribute('val', $Color[$i])
        [void]$fill.AppendChild($rgb)
        [void]$shape.AppendChild($fill)
        [void]$point.AppendChild($shape)
        [void]$series.InsertBefore($point, $before)
    }
}

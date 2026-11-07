function Add-TcWorkbookValueFormat {
    <#
    .SYNOPSIS
    Colors the cells of a range by their value.

    .PARAMETER Rule
    A dictionary of value and color name of the theme: Good, Info, Warn, Bad or Plain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book,
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Rule
    )

    foreach ($value in $Rule.Keys) {
        $colors = $Book['Theme'][$Rule[$value]]
        $format = $Sheet.ConditionalFormatting.AddEqual($Sheet.Cells[$Address])
        $format.Formula = '"{0}"' -f $value
        $format.Style.Fill.BackgroundColor.Color = ConvertTo-TcWorkbookColor $colors[0]
        $format.Style.Font.Color.Color = ConvertTo-TcWorkbookColor $colors[1]
    }
}

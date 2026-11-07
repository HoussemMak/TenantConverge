function Add-TcWorkbookStateFormat {
    <#
    .SYNOPSIS
    Colors the state of a workload. A state that rests on part of the data keeps its color and its words.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book,
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][string]$Address
    )

    $first = ($Address -split ':')[0]
    foreach ($rule in @(
            @('Blocking', 'Bad'), @('To address', 'Warn'), @('Secondary', 'Info'), @('Passed', 'Good'), @('Not collected', 'Plain'), @('Not used', 'Plain'), @('No service', 'Plain'))) {
        $colors = $Book['Theme'][$rule[1]]
        $format = $Sheet.ConditionalFormatting.AddBeginsWith($Sheet.Cells[$Address])
        $format.Text = $rule[0]
        $format.Formula = 'LEFT({0},{1})="{2}"' -f $first, $rule[0].Length, $rule[0]
        $format.Style.Fill.BackgroundColor.Color = ConvertTo-TcWorkbookColor $colors[0]
        $format.Style.Font.Color.Color = ConvertTo-TcWorkbookColor $colors[1]
    }
}

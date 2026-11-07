function Get-TcWorkbookYellowColumn {
    <#
    .SYNOPSIS
    Names the columns a team fills in, tab by tab, as they stand in the workbook.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $tabs = foreach ($name in 'ActionPlan', 'DetailedSteps', 'TargetConfigurations', 'IdentityMatrix', 'Decisions') {
        $table = $Book['Tables'][$name]
        if ($table) { '{0} ({1})' -f $table['SheetName'], (@($table['Inputs']) -join ', ') }
    }
    $tabs -join '; '
}

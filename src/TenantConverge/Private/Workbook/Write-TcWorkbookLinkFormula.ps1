function Write-TcWorkbookLinkFormula {
    <#
    .SYNOPSIS
    Writes the formulas that tie the tabs together: progress of an item, and links from one tab to another.

    .DESCRIPTION
    A link is a formula that looks up its row, so it stays right after a person sorts a table. A row with
    nothing to open gets no formula: EPPlus shows the text of a HYPERLINK whose target failed, and Excel
    does not.

    EPPlus reads only part of a COUNTIFS with three conditions, so a count that needs three reads a hidden
    column instead: Ticked and Open review here, Open blocker and Closed in Write-TcTenantViewSheet.

    Ticked says that a line counts as a step done. The Status menu is on every row of Detailed steps, and a
    watch point marked Done, as in I have read it, is not a step done: the total of steps leaves it out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $tables = $Book['Tables']
    $plan = $tables['ActionPlan']
    $steps = $tables['DetailedSteps']
    $letter = { param($Table, $Column) [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($Table['Columns'][$Column]) }

    $tickedColumn = $steps['Columns'].Count + 2
    Write-TcWorkbookValue -Sheet $steps['Sheet'] -Row $steps['HeaderRow'] -Column $tickedColumn -Value 'Ticked'
    $steps['Columns']['Ticked'] = $tickedColumn
    $steps['Sheet'].Column($tickedColumn).Hidden = $true
    if ($steps['Count']) {
        $stepType = & $letter $steps 'Type'
        $stepStatus = & $letter $steps 'Status'
        for ($row = $steps['First']; $row -le $steps['Last']; $row++) {
            Write-TcWorkbookFormula -Sheet $steps['Sheet'] -Row $row -Column $tickedColumn -Formula "IF(AND(`$$stepType$row<>`"Watch point`",`$$stepStatus$row=`"Done`"),1,0)"
        }
    }

    if ($plan['Count']) {
        $item = Get-TcWorkbookRange $steps 'Item'
        $ticked = Get-TcWorkbookRange $steps 'Ticked'
        $idLetter = & $letter $plan 'ID'
        $statusLetter = & $letter $plan 'Status'
        $doneLetter = & $letter $plan 'Steps done'
        $countLetter = & $letter $plan 'Steps'
        $sheet = $plan['Sheet']
        $bar = $sheet.Cells[$plan['First'], $plan['Columns']['Progress'], $plan['Last'], $plan['Columns']['Progress']]
        $bar.Style.Numberformat.Format = '0%'

        # A watch point is not ticked. The type of a step does not change, so the count is a plain number.
        $toTick = @{}
        $hasSteps = @{}
        foreach ($line in @($steps['Rows'])) {
            $hasSteps[$line['Item']] = $true
            if ($line['Type'] -eq 'Watch point') { continue }
            $toTick[$line['Item']] = [int]$toTick[$line['Item']] + 1
        }

        for ($row = $plan['First']; $row -le $plan['Last']; $row++) {
            $id = "`$$idLetter$row"
            $status = "`$$statusLetter$row"
            $itemId = $plan['Rows'][$row - $plan['First']]['ID']
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column $plan['Columns']['Steps'] -Value ([int]$toTick[$itemId])
            Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column $plan['Columns']['Steps done'] -Formula "SUMIFS($ticked,$item,$id)"
            Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column $plan['Columns']['Progress'] -Formula "IF(OR($status=`"Done`",$status=`"Not applicable`"),1,IFERROR(`$$doneLetter$row/`$$countLetter$row,0))"
            if ($hasSteps.ContainsKey($itemId)) {
                Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column $plan['Columns']['Open'] -Formula "HYPERLINK(`"#'Detailed steps'!A`"&(MATCH($id,$item,0)+$($steps['HeaderRow'])),`"Open`")"
            }
        }
    }

    $links = @(
        @{ Table = 'TargetConfigurations'; From = 'Action' }
        @{ Table = 'Decisions'; From = 'Reference' }
    )
    $ids = Get-TcWorkbookRange $plan 'ID'
    $known = @{}
    foreach ($line in @($plan['Rows'])) { $known[[string]$line['ID']] = $true }
    foreach ($link in $links) {
        $table = $tables[$link['Table']]
        if (-not $table['Count']) { continue }
        $from = & $letter $table $link['From']
        for ($row = $table['First']; $row -le $table['Last']; $row++) {
            if (-not $known.ContainsKey([string]$table['Rows'][$row - $table['First']][$link['From']])) { continue }
            Write-TcWorkbookFormula -Sheet $table['Sheet'] -Row $row -Column $table['Columns']['Open'] -Formula "HYPERLINK(`"#'Action plan'!A`"&(MATCH(`$$from$row,$ids,0)+$($plan['HeaderRow'])),`"Open`")"
        }
    }

    $matrix = $tables['IdentityMatrix']
    $reviewColumn = $matrix['Columns'].Count + 2
    Write-TcWorkbookValue -Sheet $matrix['Sheet'] -Row $matrix['HeaderRow'] -Column $reviewColumn -Value 'Open review'
    $matrix['Columns']['Open review'] = $reviewColumn
    $matrix['Sheet'].Column($reviewColumn).Hidden = $true
    if ($matrix['Count']) {
        $proposed = & $letter $matrix 'Proposed decision'
        $validated = & $letter $matrix 'Validated decision'
        for ($row = $matrix['First']; $row -le $matrix['Last']; $row++) {
            Write-TcWorkbookFormula -Sheet $matrix['Sheet'] -Row $row -Column $reviewColumn -Formula "IF(AND(`$$proposed$row=`"To review`",`$$validated$row=`"`"),1,0)"
        }
    }
}

function Write-TcTenantViewSheet {
    <#
    .SYNOPSIS
    Writes the Tenant view tab: a filtered list driven by the yellow boxes, then the measures and what could not be read.

    .DESCRIPTION
    Hidden columns of the Action plan tab do the filtering: Rank numbers the rows that match, Scope marks
    those of the tenant and owner chosen, Open blocker and Closed say what a row counts for. The boxes hold
    names of tenants, so formulas compare them with =, never through COUNTIF, which reads a value such as
    >5 or Al* as a condition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $theme = $Book['Theme']
    $plan = $Book['Plan']
    $tenants = @(Get-TcProperty $plan 'tenants' @())
    $meta = Get-TcProperty $plan 'meta'
    $actionPlan = $Book['Tables']['ActionPlan']
    $visible = 60
    $listHeader = 22

    $sheet = Add-TcWorkbookSheet -Book $Book -Name 'Tenant view' -Title 'Tenant view' -Color $theme['Roles']['S1'] -Width 11 `
        -Subtitle 'Choose in the yellow boxes: the figures, the chart and the list follow'

    $widths = @{ 1 = 2; 2 = 20; 3 = 54; 4 = 18; 5 = 14; 6 = 12; 7 = 11; 8 = 25; 9 = 12; 10 = 10; 11 = 22 }
    foreach ($column in $widths.Keys) { $sheet.Column($column).Width = $widths[$column] }

    $title = {
        param([int]$Row, [string]$Text)
        Write-TcWorkbookValue -Sheet $sheet -Row $Row -Column 2 -Value $Text
        $sheet.Cells[$Row, 2].Style.Font.Bold = $true
        $sheet.Cells[$Row, 2].Style.Font.Size = 12
        $sheet.Cells[$Row, 2].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Accent']))
    }

    # The boxes.
    $boxes = @(@('Tenant', 3, 'All', 'TcViewTenant'), @('Moment', 4, 'All', 'TcViewMoment'), @('Owner', 5, 'All', 'TcViewOwner'), @('State', 6, 'Open', 'TcViewState'), @('Blocking', 7, 'All', 'TcViewBlocking'))
    foreach ($box in $boxes) {
        Write-TcWorkbookValue -Sheet $sheet -Row 5 -Column $box[1] -Value $box[0]
        $sheet.Cells[5, $box[1]].Style.Font.Bold = $true
        $sheet.Cells[5, $box[1]].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Muted']))
        Write-TcWorkbookValue -Sheet $sheet -Row 6 -Column $box[1] -Value $box[2]
        $cell = $sheet.Cells[6, $box[1]]
        $cell.Style.Fill.PatternType = 'Solid'
        $cell.Style.Fill.BackgroundColor.SetColor((ConvertTo-TcWorkbookColor $theme['Input']))
        $cell.Style.Font.Bold = $true
        $cell.Style.HorizontalAlignment = 'Center'
        Add-TcWorkbookList -Sheet $sheet -Address $cell.Address -List $box[3]
    }
    $sheet.Row(6).Height = 24

    $boxTenant = "'Tenant view'!`$C`$6"
    $boxMoment = "'Tenant view'!`$D`$6"
    $boxOwner = "'Tenant view'!`$E`$6"
    $boxState = "'Tenant view'!`$F`$6"
    $boxBlocking = "'Tenant view'!`$G`$6"

    # The two hidden columns of the Action plan, past the table with one column left free.
    $source = $actionPlan['Sheet']
    $columns = $actionPlan['Columns']
    $letter = { param([string]$Column) [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($columns[$Column]) }
    $rankColumn = $columns.Count + 2
    $scopeColumn = $columns.Count + 3
    $blockerColumn = $columns.Count + 4
    $closedColumn = $columns.Count + 5
    $rankLetter = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($rankColumn)
    $scopeLetter = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($scopeColumn)
    $header = $actionPlan['HeaderRow']
    Write-TcWorkbookValue -Sheet $source -Row $header -Column $rankColumn -Value 'Rank'
    Write-TcWorkbookValue -Sheet $source -Row $header -Column $scopeColumn -Value 'Scope'
    Write-TcWorkbookValue -Sheet $source -Row $header -Column $blockerColumn -Value 'Open blocker'
    Write-TcWorkbookValue -Sheet $source -Row $header -Column $closedColumn -Value 'Closed'
    if ($actionPlan['Count']) {
        foreach ($row in $actionPlan['First']..$actionPlan['Last']) {
            $tenantCell = "`$$(& $letter 'Tenant')$row"
            $momentCell = "`$$(& $letter 'Moment')$row"
            $ownerCell = "`$$(& $letter 'Owner')$row"
            $statusCell = "`$$(& $letter 'Status')$row"
            $blockingCell = "`$$(& $letter 'Blocking')$row"
            $scope = "AND(OR($boxTenant=`"All`",$tenantCell=$boxTenant),OR($boxOwner=`"All`",$ownerCell=$boxOwner))"
            Write-TcWorkbookFormula -Sheet $source -Row $row -Column $scopeColumn -Formula "IF($scope,1,0)"
            Write-TcWorkbookFormula -Sheet $source -Row $row -Column $blockerColumn -Formula "IF(AND($blockingCell=`"Yes`",$statusCell<>`"Done`",$statusCell<>`"Not applicable`"),1,0)"
            Write-TcWorkbookFormula -Sheet $source -Row $row -Column $closedColumn -Formula "IF(OR($statusCell=`"Done`",$statusCell=`"Not applicable`"),1,0)"
            Write-TcWorkbookFormula -Sheet $source -Row $row -Column $rankColumn -Formula ("IF(AND(`${0}{1}=1,OR({2}=`"All`",{3}={2}),OR({4}=`"All`",IF({4}=`"Open`",AND({5}<>`"Done`",{5}<>`"Not applicable`"),{5}={4})),OR({6}=`"All`",{7}=`"Yes`")),COUNT(`${8}`${9}:`${8}{10})+1,`"`")" -f $scopeLetter, $row, $boxMoment, $momentCell, $boxState, $statusCell, $boxBlocking, $blockingCell, $rankLetter, $header, ($row - 1))
        }
    }
    foreach ($column in $rankColumn, $scopeColumn, $blockerColumn, $closedColumn) { $source.Column($column).Hidden = $true }
    $columns['Rank'] = $rankColumn
    $columns['Scope'] = $scopeColumn
    $columns['Open blocker'] = $blockerColumn
    $columns['Closed'] = $closedColumn

    $rank = Get-TcWorkbookRange $actionPlan 'Rank'
    $scopeRange = Get-TcWorkbookRange $actionPlan 'Scope'
    $openBlockers = Get-TcWorkbookRange $actionPlan 'Open blocker'
    $closed = Get-TcWorkbookRange $actionPlan 'Closed'
    $progress = Get-TcWorkbookRange $actionPlan 'Progress'
    $moment = Get-TcWorkbookRange $actionPlan 'Moment'

    # Figures.
    $figures = @(
        , @('Items shown', "COUNT($rank)", '0', 'with the choices above')
        , @('Open blockers', "SUMIFS($openBlockers,$scopeRange,1)", '0', 'of this tenant and owner')
        , @('Progress', "IFERROR(SUMIFS($progress,$scopeRange,1)/COUNTIF($scopeRange,1),0)", '0%', 'mean of this tenant and owner')
    )
    for ($i = 0; $i -lt $figures.Count; $i++) {
        $column = 3 + $i
        Write-TcWorkbookValue -Sheet $sheet -Row 8 -Column $column -Value $figures[$i][0]
        Write-TcWorkbookFormula -Sheet $sheet -Row 9 -Column $column -Formula $figures[$i][1] -Format $figures[$i][2]
        Write-TcWorkbookValue -Sheet $sheet -Row 10 -Column $column -Value $figures[$i][3]
        $sheet.Cells[8, $column].Style.Font.Bold = $true
        $sheet.Cells[8, $column].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Muted']))
        $sheet.Cells[9, $column].Style.Font.Size = 18
        $sheet.Cells[9, $column].Style.Font.Bold = $true
        $sheet.Cells[9, $column].Style.HorizontalAlignment = 'Left'
        $sheet.Cells[9, $column].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $(if ($i -eq 1) { $theme['Bad'][1] } else { $theme['Accent'] })))
        $sheet.Cells[10, $column].Style.Font.Size = 9
        $sheet.Cells[10, $column].Style.Font.Italic = $true
        $sheet.Cells[10, $column].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Muted']))
    }

    # By moment.
    & $title 12 'By moment'
    $headers = 'Moment', 'Items', 'Closed', 'Open', 'Blockers'
    for ($i = 0; $i -lt $headers.Count; $i++) { Write-TcWorkbookValue -Sheet $sheet -Row 13 -Column (3 + $i) -Value $headers[$i] }
    Add-TcWorkbookHeaderStyle -Book $Book -Sheet $sheet -Row 13 -FirstColumn 3 -LastColumn 7
    $row = 13
    foreach ($name in @(Get-TcProperty $meta 'moments' @('Now', 'Preparation', 'Before cutover', 'Cutover', 'After cutover', 'Closure'))) {
        $row++
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 3 -Value $name
        $base = "$scopeRange,1,$moment,`$C$row"
        Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column 4 -Formula "COUNTIFS($base)"
        Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column 5 -Formula "SUMIFS($closed,$base)"
        Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column 6 -Formula "D$row-E$row"
        Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column 7 -Formula "SUMIFS($openBlockers,$base)"
        $sheet.Cells[$row, 4, $row, 7].Style.HorizontalAlignment = 'Center'
    }
    if ($actionPlan['Count']) { Add-TcWorkbookChart -Book $Book -Sheet $sheet -Kind 'View' -Top 4 -Left 7 -Header 13 -FirstRow 14 -LastRow $row }

    # The list.
    & $title ($listHeader - 1) 'Matching items'
    $headers = 'Open', 'What to do', 'Tenant', 'Moment', 'Severity', 'Blocking', 'Owner', 'Status', 'Progress', 'ID'
    for ($i = 0; $i -lt $headers.Count; $i++) { Write-TcWorkbookValue -Sheet $sheet -Row $listHeader -Column (2 + $i) -Value $headers[$i] }
    Add-TcWorkbookHeaderStyle -Book $Book -Sheet $sheet -Row $listHeader -FirstColumn 2 -LastColumn 11
    # T() and not &"": EPPlus raises an error on an empty cell joined to a text. The test on the row keeps
    # the rows past the last match from MATCH, whose error EPPlus does not hand to IFERROR through T().
    $shown = "ROW()-$listHeader>`$C`$9"
    $pick = { param([string]$Column) "INDEX($(Get-TcWorkbookRange $actionPlan $Column),MATCH(ROW()-$listHeader,$rank,0))" }
    foreach ($row in ($listHeader + 1)..($listHeader + $visible)) {
        Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column 2 -Formula "IF($shown,`"`",HYPERLINK(`"#'Action plan'!A`"&($($actionPlan['HeaderRow'])+MATCH(ROW()-$listHeader,$rank,0)),`"Open`"))"
        $column = 3
        foreach ($name in 'What to do', 'Tenant', 'Moment', 'Severity', 'Blocking', 'Owner', 'Status') {
            Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column $column -Formula "IF($shown,`"`",T($(& $pick $name)))"
            $column++
        }
        Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column 10 -Formula "IF($shown,`"`",$(& $pick 'Progress'))" -Format '0%'
        Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column 11 -Formula "IF($shown,`"`",T($(& $pick 'ID')))"
    }
    $listArea = $sheet.Cells[($listHeader + 1), 2, ($listHeader + $visible), 11]
    $listArea.Style.Font.Size = 10
    $listArea.Style.VerticalAlignment = 'Top'
    $sheet.Cells[($listHeader + 1), 3, ($listHeader + $visible), 3].Style.WrapText = $true
    $sheet.Cells[($listHeader + 1), 2, ($listHeader + $visible), 2].Style.HorizontalAlignment = 'Center'
    $sheet.Cells[($listHeader + 1), 4, ($listHeader + $visible), 10].Style.HorizontalAlignment = 'Center'
    $sheet.Cells[($listHeader + 1), 11, ($listHeader + $visible), 11].Style.Font.Size = 9
    Add-TcWorkbookValueFormat -Book $Book -Sheet $sheet -Address $sheet.Cells[($listHeader + 1), 9, ($listHeader + $visible), 9].Address -Rule ([ordered]@{ 'Done' = 'Good'; 'In progress' = 'Info'; 'Blocked' = 'Bad'; 'To do' = 'Plain'; 'Not applicable' = 'Plain' })
    Add-TcWorkbookValueFormat -Book $Book -Sheet $sheet -Address $sheet.Cells[($listHeader + 1), 6, ($listHeader + $visible), 6].Address -Rule ([ordered]@{ Critical = 'Bad'; High = 'Warn'; Medium = 'Info'; Low = 'Plain'; Info = 'Plain' })
    Add-TcWorkbookValueFormat -Book $Book -Sheet $sheet -Address $sheet.Cells[($listHeader + 1), 7, ($listHeader + $visible), 7].Address -Rule ([ordered]@{ Yes = 'Bad' })
    $row = $listHeader + $visible + 1
    Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column 3 -Formula "IF(COUNT($rank)>$visible,`"Only the first $visible are shown: narrow the choices, or open the Action plan tab.`",`"`")"
    $sheet.Cells[$row, 3].Style.Font.Italic = $true

    # Measures, one column per tenant.
    $row += 2
    & $title $row 'Measures by tenant'
    $row++
    $names = @('Workload', 'Measure') + @($tenants | ForEach-Object { $_['role'] }) + @('Sources total', 'After consolidation', 'Not read')
    for ($i = 0; $i -lt $names.Count; $i++) { Write-TcWorkbookValue -Sheet $sheet -Row $row -Column (2 + $i) -Value $names[$i] }
    Add-TcWorkbookHeaderStyle -Book $Book -Sheet $sheet -Row $row -FirstColumn 2 -LastColumn (1 + $names.Count)
    Add-TcWorkbookRoleFormat -Book $Book -Sheet $sheet -Address $sheet.Cells[$row, 4, $row, (3 + $tenants.Count)].Address
    $row++
    for ($i = 0; $i -lt $tenants.Count; $i++) {
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column (4 + $i) -Value $tenants[$i]['displayName']
        $sheet.Cells[$row, (4 + $i)].Style.WrapText = $true
        $sheet.Cells[$row, (4 + $i)].Style.HorizontalAlignment = 'Center'
        $sheet.Cells[$row, (4 + $i)].Style.Font.Size = 9
        $sheet.Cells[$row, (4 + $i)].Style.Font.Bold = $true
    }
    foreach ($measure in @(Get-TcProperty $Book['RuleSet'] 'measures' @())) {
        $row++
        $unread = @(Get-TcProperty $measure 'unreadSources' @())
        $values = Get-TcProperty $measure 'values' @{}
        $table = Get-TcProperty $measure 'table'
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 2 -Value $measure['workload']
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 3 -Value $measure['label']
        $column = 4
        foreach ($tenant in $tenants) {
            $value = Get-TcProperty $values $tenant['role']
            if ($null -eq $value) {
                $value = 'Not read'
                if ($table) {
                    $state = (Get-TcTableState -Snapshot $Book['Snapshot'] -Role $tenant['role'] -Table $table).State
                    if ($state -eq 'NotFullyRead') { $value = 'Not fully read' } elseif ($state -eq 'NotCollected') { $value = 'Not collected' }
                }
            }
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column $column -Value $value
            $sheet.Cells[$row, $column].Style.HorizontalAlignment = 'Center'
            $column++
        }
        foreach ($total in 'sources', 'after') {
            $value = Get-TcProperty $measure $total
            $text = if (-not (Get-TcProperty $measure 'additive')) { $null } elseif ($null -eq $value) { 'Not read' } elseif ($unread.Count) { 'at least {0}' -f $value } else { $value }
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column $column -Value $text
            $sheet.Cells[$row, $column].Style.HorizontalAlignment = 'Center'
            $column++
        }
        $missing = @($tenants | Where-Object { $_['role'] -in $unread } | ForEach-Object { $_['displayName'] })
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column $column -Value ($missing -join ', ')
        $sheet.Cells[$row, 2].Style.Font.Size = 9
    }

    # What could not be read.
    $row += 2
    & $title $row 'What could not be read'
    $lines = @(Get-TcProperty $Book['Snapshot'] 'coverage' @() | Where-Object { (Get-TcProperty $_ 'status') -ne 'OK' })
    $row++
    if (-not $lines.Count) {
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 3 -Value 'Every collector of this snapshot reads OK.'
    }
    else {
        $headers = 'What', 'Tenant', 'Status'
        for ($i = 0; $i -lt $headers.Count; $i++) { Write-TcWorkbookValue -Sheet $sheet -Row $row -Column (3 + $i) -Value $headers[$i] }
        Add-TcWorkbookHeaderStyle -Book $Book -Sheet $sheet -Row $row -FirstColumn 3 -LastColumn 5
        $byRole = @{}
        foreach ($tenant in $tenants) { $byRole[$tenant['role']] = $tenant['displayName'] }
        foreach ($line in $lines) {
            $row++
            $role = Get-TcProperty $line 'role'
            $parts = @((Get-TcProperty $line 'workload'), (Get-TcProperty $line 'title'), (Get-TcProperty $line 'message'), (Get-TcProperty $line 'remedy')) | Where-Object { $_ }
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 3 -Value ($parts -join '. ')
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 4 -Value $(if ($byRole.ContainsKey($role)) { $byRole[$role] } else { $role })
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 5 -Value (Get-TcProperty $line 'status')
            $sheet.Cells[$row, 3].Style.WrapText = $true
            $sheet.Cells[$row, 3].Style.Font.Size = 10
            $sheet.Cells[$row, 3, $row, 5].Style.VerticalAlignment = 'Top'
        }
    }
    $sheet.View.FreezePanes(8, 1)
}

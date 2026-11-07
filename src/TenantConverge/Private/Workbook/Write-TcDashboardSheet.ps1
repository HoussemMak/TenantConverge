function Write-TcDashboardSheet {
    <#
    .SYNOPSIS
    Writes the Dashboard tab: where the project stands, tenant by tenant, and what could not be read.

    .DESCRIPTION
    Each tenant of the project has its row and its column, and a tenant that does not exist has none.
    Formulas count by role, which is a value of this module, and read everything else from cells.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $theme = $Book['Theme']
    $plan = $Book['Plan']
    $tables = $Book['Tables']
    $tenants = @(Get-TcProperty $plan 'tenants' @())
    $readiness = @($Book['Readiness'])
    $meta = Get-TcProperty $plan 'meta'
    $sourceCount = @($tenants | Where-Object { $_['role'] -ne 'Target' }).Count

    $sheet = Add-TcWorkbookSheet -Book $Book -Name 'Dashboard' -Title 'Dashboard' -Color $theme['Band'] -Width 15 `
        -Subtitle ('{0} source(s) into 1 target. Snapshot of {1}.' -f $sourceCount, (Get-TcProperty $meta 'snapshotStarted'))

    $sheet.Column(1).Width = 2
    $sheet.Column(2).Width = 13
    $sheet.Column(3).Width = 26
    foreach ($c in 4..14) { $sheet.Column($c).Width = 12 }
    $sheet.Column(15).Width = 70

    $section = {
        param([int]$Row, [string]$Text)
        Write-TcWorkbookValue -Sheet $sheet -Row $Row -Column 2 -Value $Text
        $sheet.Cells[$Row, 2].Style.Font.Bold = $true
        $sheet.Cells[$Row, 2].Style.Font.Size = 12
        $sheet.Cells[$Row, 2].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Accent']))
    }
    $headers = {
        param([int]$Row, [string[]]$Text)
        for ($i = 0; $i -lt $Text.Count; $i++) { Write-TcWorkbookValue -Sheet $sheet -Row $Row -Column (2 + $i) -Value $Text[$i] }
        Add-TcWorkbookHeaderStyle -Book $Book -Sheet $sheet -Row $Row -FirstColumn 2 -LastColumn (1 + $Text.Count)
        $sheet.Row($Row).Height = 30
    }

    # Where to go. Only the tabs that exist.
    Write-TcWorkbookValue -Sheet $sheet -Row 3 -Column 2 -Value 'Go to:'
    $sheet.Cells[3, 2].Style.Font.Bold = $true
    $column = 3
    foreach ($name in 'Tenant view', 'Action plan', 'Detailed steps', 'Target configurations', 'Remediations', 'Identity matrix', 'Decisions', 'Settings') {
        if (-not $Book['Sheets'].ContainsKey($name)) { continue }
        Write-TcWorkbookLink -Sheet $sheet -Row 3 -Column $column -Text $name -Target "'$name'!A1" -Book $Book
        $column += $(if ($column -eq 3) { 1 } else { 2 })
    }

    # Tiles.
    $actionPlan = $tables['ActionPlan']
    $steps = $tables['DetailedSteps']
    $settings = $tables['TargetConfigurations']
    $matrix = $tables['IdentityMatrix']
    $decisions = $tables['Decisions']
    $status = Get-TcWorkbookRange $actionPlan 'Status'
    $openBlockers = Get-TcWorkbookRange $actionPlan 'Open blocker'
    $openReviews = Get-TcWorkbookRange $matrix 'Open review'
    $unread = @($readiness | ForEach-Object { @($_.Workloads | Where-Object { $_.Applicable -and -not $_.Complete }).Count } | Measure-Object -Sum).Sum
    $tiles = @(
        , @('Open blockers', "SUM($openBlockers)", 'actions that block a cutover', 'Bad')
        , @('Items done', "COUNTIF($status,`"Done`")&`" / `"&COUNTA($(Get-TcWorkbookRange $actionPlan 'ID'))", 'actions and tasks', 'Accent')
        , @('Steps done', "SUM($(Get-TcWorkbookRange $steps 'Ticked'))&`" / `"&(COUNTA($(Get-TcWorkbookRange $steps 'Item'))-COUNTIF($(Get-TcWorkbookRange $steps 'Type'),`"Watch point`"))", 'lines ticked in Detailed steps', 'Accent')
        , @('Settings applied', "(COUNTIF($(Get-TcWorkbookRange $settings 'Applied'),`"Yes`")-COUNTIFS($(Get-TcWorkbookRange $settings 'Role'),`"Orphan`",$(Get-TcWorkbookRange $settings 'Applied'),`"Yes`"))&`" / `"&(COUNTA($(Get-TcWorkbookRange $settings 'Setting'))-COUNTIF($(Get-TcWorkbookRange $settings 'Role'),`"Orphan`"))", 'in Target configurations', 'Accent')
        , @('Open decisions', "COUNTIF($(Get-TcWorkbookRange $decisions 'Status'),`"Open`")", 'to settle with the customer', 'Accent')
        , @('Accounts to validate', "SUM($openReviews)", 'rows to review in the matrix', 'Accent')
        , @('Unconfirmed tasks', "COUNTIF($(Get-TcWorkbookRange $actionPlan 'Confirmation'),`"Unconfirmed`")", 'waiting for data that was not read', 'Bad')
        , @('Workloads not fully read', $null, 'all tenants together: see below', 'Bad')
    )
    for ($i = 0; $i -lt $tiles.Count; $i++) {
        $tile = $tiles[$i]
        $left = 2 + ($i % 4) * 3
        $top = 5 + [math]::Floor($i / 4) * 5
        $area = $sheet.Cells[$top, $left, ($top + 3), ($left + 2)]
        $area.Style.Fill.PatternType = 'Solid'
        $area.Style.Fill.BackgroundColor.SetColor((ConvertTo-TcWorkbookColor $theme['Surface']))
        Write-TcWorkbookValue -Sheet $sheet -Row $top -Column $left -Value $tile[0]
        $sheet.Cells[$top, $left].Style.Font.Bold = $true
        $sheet.Cells[$top, $left].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Muted']))
        $value = $sheet.Cells[($top + 1), $left, ($top + 2), ($left + 2)]
        $value.Merge = $true
        if ($tile[1]) { Write-TcWorkbookFormula -Sheet $sheet -Row ($top + 1) -Column $left -Formula $tile[1] } else { Write-TcWorkbookValue -Sheet $sheet -Row ($top + 1) -Column $left -Value ([int]$unread) }
        $value.Style.Font.Size = 22
        $value.Style.Font.Bold = $true
        $value.Style.HorizontalAlignment = 'Left'
        $value.Style.VerticalAlignment = 'Center'
        $value.Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $(if ($tile[3] -eq 'Bad') { $theme['Bad'][1] } else { $theme['Accent'] })))
        Write-TcWorkbookValue -Sheet $sheet -Row ($top + 3) -Column $left -Value $tile[2]
        $sheet.Cells[($top + 3), $left].Style.Font.Size = 9
        $sheet.Cells[($top + 3), $left].Style.Font.Italic = $true
        $sheet.Cells[($top + 3), $left].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Muted']))
    }

    # Readiness: both scores, and what the difference means.
    $row = 16
    & $section $row 'Readiness by tenant'
    $row++
    & $headers $row @('Role', 'Tenant', 'Wave', 'Score', 'Collected score', 'Difference', 'Workloads read', 'Blocking', 'To address', 'Secondary', 'Passed', 'Not collected')
    Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 15 -Value 'What the difference means'
    Add-TcWorkbookHeaderStyle -Book $Book -Sheet $sheet -Row $row -FirstColumn 15 -LastColumn 15
    Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 16 -Value 'Score'
    Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 17 -Value 'Collected score'
    Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 18 -Value 'Tenant'
    foreach ($column in 16..18) { $sheet.Column($column).Hidden = $true }
    $firstReadiness = $row + 1
    foreach ($tenant in $tenants) {
        $row++
        $role = $tenant['role']
        $line = @($readiness | Where-Object { $_.Role -eq $role }) | Select-Object -First 1
        $wave = Get-TcProperty $tenant 'wave'
        $read = @()
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 2 -Value $role
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 3 -Value $tenant['displayName']
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 4 -Value $wave
        if ($line) {
            $workloads = @($line.Workloads)
            $applicable = @($workloads | Where-Object { $_.Applicable })
            $read = @($workloads | Where-Object { $_.Coverage -notin 'Failed', 'None' })
            $counted = @($applicable | Where-Object { $_.Complete })
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 5 -Value ([int]$line.Score)
            if ($read.Count) {
                Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 6 -Value ([int]$line.CollectedScore)
                Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 7 -Value ([int]$line.CollectedScore - [int]$line.Score)
            }
            else {
                Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 6 -Value 'Not read'
                Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 7 -Value 'Not read'
            }
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 8 -Value ('{0} of {1}' -f $counted.Count, $applicable.Count)
            $column = 9
            foreach ($state in 'Blocking', 'To address', 'Secondary', 'Passed', 'Not collected') {
                Write-TcWorkbookValue -Sheet $sheet -Row $row -Column $column -Value ([int]$line.States[$state])
                $column++
            }
        }
        else {
            foreach ($column in 5..7) { Write-TcWorkbookValue -Sheet $sheet -Row $row -Column $column -Value 'Not read' }
        }

        # What the chart reads. A tenant that was not read has empty cells, which leave a gap, and says so in
        # its label: a text or a 0 draws as a bar at zero, the same as a tenant that scores 0.
        if ($read.Count) {
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 16 -Value ([int]$line.Score)
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 17 -Value ([int]$line.CollectedScore)
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 18 -Value $tenant['displayName']
        }
        else { Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 18 -Value "$($tenant['displayName']) (not read)" }

        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 15 -Value (Get-TcWorkbookScoreNote -Readiness $line)
        $sheet.Cells[$row, 15].Style.WrapText = $true
        $sheet.Cells[$row, 4, $row, 14].Style.HorizontalAlignment = 'Center'
        $sheet.Cells[$row, 2, $row, 15].Style.VerticalAlignment = 'Top'
    }
    $lastReadiness = $row
    $row++
    Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 2 -Value 'Score is the one to report: it counts every workload the tenant has, and gives no credit for what was not read. Collected score averages only what was read. When they differ, the difference is what could not be seen.'
    $sheet.Cells[$row, 2].Style.Font.Italic = $true
    $sheet.Cells[$row, 2].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Muted']))

    # Workloads, one column per tenant.
    $row += 2
    & $section $row 'Workloads by tenant'
    $workloadTitle = $row
    $row++
    & $headers $row (@('Workload', '') + @($tenants | ForEach-Object { $_['role'] }))
    $sheet.Cells[$row, 2, $row, 3].Merge = $true
    $sheet.Row($row).Height = 18
    Add-TcWorkbookRoleFormat -Book $Book -Sheet $sheet -Address $sheet.Cells[$row, 4, $row, (3 + $tenants.Count)].Address
    $row++
    for ($i = 0; $i -lt $tenants.Count; $i++) {
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column (4 + $i) -Value $tenants[$i]['displayName']
        $sheet.Cells[$row, (4 + $i)].Style.WrapText = $true
        $sheet.Cells[$row, (4 + $i)].Style.HorizontalAlignment = 'Center'
        $sheet.Cells[$row, (4 + $i)].Style.Font.Size = 9
        $sheet.Cells[$row, (4 + $i)].Style.Font.Bold = $true
    }
    $firstWorkload = $row + 1
    foreach ($workload in $script:TcWorkloads) {
        $row++
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 2 -Value $workload
        $sheet.Cells[$row, 2, $row, 3].Merge = $true
        $column = 4
        foreach ($tenant in $tenants) {
            $line = @($readiness | Where-Object { $_.Role -eq $tenant['role'] }) | Select-Object -First 1
            $state = 'Not collected'
            if ($line) {
                $detail = @($line.Workloads | Where-Object { $_.Workload -eq $workload }) | Select-Object -First 1
                $state = Get-TcWorkbookWorkloadState -Line $detail -Snapshot $Book['Snapshot'] -Role $tenant['role']
            }
            Write-TcWorkbookValue -Sheet $sheet -Row $row -Column $column -Value $state
            $sheet.Cells[$row, $column].Style.WrapText = $true
            $sheet.Cells[$row, $column].Style.HorizontalAlignment = 'Center'
            $sheet.Cells[$row, $column].Style.Font.Size = 9
            $column++
        }
    }
    $stateArea = $sheet.Cells[$firstWorkload, 4, $row, (3 + $tenants.Count)].Address
    Add-TcWorkbookStateFormat -Book $Book -Sheet $sheet -Address $stateArea
    $row++
    Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 2 -Value 'Not collected: nothing could be read. Not used: everything was read and the service holds nothing. No service: the tenant does not have it. Partly read: the state rests on part of the data.'
    $sheet.Cells[$row, 2].Style.Font.Italic = $true
    $sheet.Cells[$row, 2].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Muted']))

    # Progress of each tenant.
    $row += 2
    & $section $row 'Progress by tenant'
    $row++
    & $headers $row @('Role', 'Tenant', 'Items', 'Done', 'Open blockers', 'Steps done', 'Steps', 'Settings applied', 'Settings', 'Accounts to validate', 'Open decisions', 'Progress')
    $firstProgress = $row + 1
    $role = Get-TcWorkbookRange $actionPlan 'Role'
    $progress = Get-TcWorkbookRange $actionPlan 'Progress'
    $stepRole = Get-TcWorkbookRange $steps 'Role'
    $ticked = Get-TcWorkbookRange $steps 'Ticked'
    $stepType = Get-TcWorkbookRange $steps 'Type'
    $settingRole = Get-TcWorkbookRange $settings 'Role'
    $matrixRole = Get-TcWorkbookRange $matrix 'Role'
    $decisionRole = Get-TcWorkbookRange $decisions 'Role'
    foreach ($tenant in @($tenants) + @{ role = 'All'; displayName = 'All tenants' }) {
        $row++
        $cell = "`$B$row"
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 2 -Value $tenant['role']
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 3 -Value $tenant['displayName']
        $formulas = @(
            "COUNTIF($role,$cell)"
            "COUNTIFS($role,$cell,$status,`"Done`")"
            "SUMIFS($openBlockers,$role,$cell)"
            "SUMIFS($ticked,$stepRole,$cell)"
            "COUNTIF($stepRole,$cell)-COUNTIFS($stepRole,$cell,$stepType,`"Watch point`")"
            "COUNTIFS($settingRole,$cell,$(Get-TcWorkbookRange $settings 'Applied'),`"Yes`")"
            "COUNTIF($settingRole,$cell)"
            "SUMIFS($openReviews,$matrixRole,$cell)"
            "COUNTIFS($decisionRole,$cell,$(Get-TcWorkbookRange $decisions 'Status'),`"Open`")"
        )
        for ($i = 0; $i -lt $formulas.Count; $i++) { Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column (4 + $i) -Formula $formulas[$i] }
        Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column 13 -Formula "IFERROR(SUMIFS($progress,$role,$cell)/`$D$row,0)" -Format '0%'
        $sheet.Cells[$row, 4, $row, 13].Style.HorizontalAlignment = 'Center'
    }
    $bar = $sheet.ConditionalFormatting.AddDatabar($sheet.Cells[$firstProgress, 13, $row, 13], (ConvertTo-TcWorkbookColor $theme['Roles']['S1']))
    $bar.LowValue.Type = 'Num'
    $bar.LowValue.Value = 0
    $bar.HighValue.Type = 'Num'
    $bar.HighValue.Value = 1
    Add-TcWorkbookRoleFormat -Book $Book -Sheet $sheet -Address $sheet.Cells[$firstProgress, 2, $row, 2].Address
    Add-TcWorkbookRoleFormat -Book $Book -Sheet $sheet -Address $sheet.Cells[$firstReadiness, 2, $lastReadiness, 2].Address

    # Items by moment and by severity, which feed the charts.
    $row += 2
    & $section $row 'Items by moment'
    $row++
    & $headers $row @('Moment', '', 'Done', 'In progress', 'Blocked', 'To do', 'Not applicable')
    $sheet.Cells[$row, 2, $row, 3].Merge = $true
    $momentHeader = $row
    $moment = Get-TcWorkbookRange $actionPlan 'Moment'
    foreach ($name in @(Get-TcProperty $meta 'moments' @('Now', 'Preparation', 'Before cutover', 'Cutover', 'After cutover', 'Closure'))) {
        $row++
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 2 -Value $name
        $sheet.Cells[$row, 2, $row, 3].Merge = $true
        for ($i = 0; $i -lt 5; $i++) {
            $letter = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter(4 + $i)
            Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column (4 + $i) -Formula "COUNTIFS($moment,`$B$row,$status,$letter`$$momentHeader)"
        }
        $sheet.Cells[$row, 4, $row, 8].Style.HorizontalAlignment = 'Center'
    }
    $lastMoment = $row

    $row += 2
    & $section $row 'Actions by severity'
    $row++
    & $headers $row @('Severity', '', 'Actions')
    $sheet.Cells[$row, 2, $row, 3].Merge = $true
    $severityHeader = $row
    $kind = Get-TcWorkbookRange $actionPlan 'Kind'
    $severity = Get-TcWorkbookRange $actionPlan 'Severity'
    foreach ($name in 'Critical', 'High', 'Medium', 'Low', 'Info') {
        $row++
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 2 -Value $name
        $sheet.Cells[$row, 2, $row, 3].Merge = $true
        Write-TcWorkbookFormula -Sheet $sheet -Row $row -Column 4 -Formula "COUNTIFS($kind,`"Action`",$severity,`$B$row)"
        $sheet.Cells[$row, 4].Style.HorizontalAlignment = 'Center'
    }
    $lastSeverity = $row

    $hasItems = $actionPlan['Count'] -gt 0
    if ($tenants.Count) { Add-TcWorkbookChart -Book $Book -Sheet $sheet -Kind 'Readiness' -Top ($workloadTitle - 1) -Left 8 -Header ($firstReadiness - 1) -FirstRow $firstReadiness -LastRow $lastReadiness }
    if ($hasItems) {
        Add-TcWorkbookChart -Book $Book -Sheet $sheet -Kind 'Moments' -Top ($momentHeader - 1) -Left 9 -Header $momentHeader -FirstRow ($momentHeader + 1) -LastRow $lastMoment
        Add-TcWorkbookChart -Book $Book -Sheet $sheet -Kind 'Severity' -Top ($severityHeader - 1) -Left 5 -Header $severityHeader -FirstRow ($severityHeader + 1) -LastRow $lastSeverity
    }

    $row += 12
    & $section $row 'How to read this dashboard'
    foreach ($text in @(
            'The tiles and the progress tables read the other tabs: change a status there and they follow when Excel recalculates.'
            'A step marked Done moves its item in the Action plan, and an item moves its tenant here.'
            'Use the Tenant view to filter by tenant, moment, owner or state with its yellow boxes.'
            'This file holds names and addresses of real people: keep it with the project team.')) {
        $row++
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 2 -Value $text
    }
    $sheet.View.FreezePanes(4, 1)
}

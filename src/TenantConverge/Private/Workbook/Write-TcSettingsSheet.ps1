function Write-TcSettingsSheet {
    <#
    .SYNOPSIS
    Writes the Settings tab: the project, its tenants, and the named lists behind the drop-down menus.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $theme = $Book['Theme']
    $plan = $Book['Plan']
    $meta = Get-TcProperty $plan 'meta'
    $tenants = @(Get-TcProperty $plan 'tenants' @())
    $sheet = Add-TcWorkbookSheet -Book $Book -Name 'Settings' -Title 'Settings' -Color $theme['Muted'] -Width 11 `
        -Subtitle 'The project, its tenants, and the lists behind the drop-down menus'

    $heading = {
        param([int]$Row, [string]$Text)
        Write-TcWorkbookValue -Sheet $sheet -Row $Row -Column 1 -Value $Text
        $sheet.Cells[$Row, 1].Style.Font.Bold = $true
        $sheet.Cells[$Row, 1].Style.Font.Size = 12
        $sheet.Cells[$Row, 1].Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Accent']))
    }

    & $heading 5 'Project'
    $row = 6
    foreach ($line in @(
            , @('Project', (Get-TcProperty $Book['Project'] 'name'))
            , @('Target state', (Get-TcProperty $meta 'targetState'))
            , @('Sources', [int](Get-TcProperty $meta 'sourceCount' 0))
            , @('Snapshot started', (Get-TcProperty $meta 'snapshotStarted'))
            , @('Snapshot finished', (Get-TcProperty $meta 'snapshotFinished'))
            , @('Module version', (Get-TcProperty $meta 'moduleVersion')))) {
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 1 -Value $line[0]
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 2 -Value $line[1]
        $sheet.Cells[$row, 2].Style.HorizontalAlignment = 'Left'
        $row++
    }

    $row++
    & $heading $row 'Tenants'
    $row++
    $headers = 'Role', 'Tenant', 'Primary domain', 'Wave'
    for ($c = 0; $c -lt $headers.Count; $c++) { Write-TcWorkbookValue -Sheet $sheet -Row $row -Column ($c + 1) -Value $headers[$c] }
    Add-TcWorkbookHeaderStyle -Book $Book -Sheet $sheet -Row $row -LastColumn $headers.Count
    foreach ($tenant in $tenants) {
        $row++
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 1 -Value $tenant['role']
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 2 -Value $tenant['displayName']
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 3 -Value (Get-TcProperty $tenant 'primaryDomain')
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column 4 -Value (Get-TcProperty $tenant 'wave')
        $swatch = $sheet.Cells[$row, 1]
        $swatch.Style.Fill.PatternType = 'Solid'
        $swatch.Style.Fill.BackgroundColor.SetColor((ConvertTo-TcWorkbookColor $theme['Roles'][$tenant['role']]))
        $swatch.Style.Font.Color.SetColor([System.Drawing.Color]::White)
        $swatch.Style.Font.Bold = $true
    }

    $moments = @(Get-TcProperty $meta 'moments' @('Now', 'Preparation', 'Before cutover', 'Cutover', 'After cutover', 'Closure'))
    $statuses = 'To do', 'In progress', 'Blocked', 'Done', 'Not applicable'
    $lists = [ordered]@{
        TcStatus         = $statuses
        TcStepStatus     = @($statuses) + 'To read'
        TcYesNo          = 'Yes', 'No'
        TcDecisionStatus = 'Open', 'Decided', 'Postponed'
        TcMatrixDecision = 'Create', 'Duplicate', 'Exclude', 'To review'
        TcViewTenant     = @('All') + @($tenants | ForEach-Object { $_['displayName'] }) + 'All tenants'
        TcViewMoment     = @('All') + $moments
        TcViewOwner      = 'All', 'Migration team', 'Customer', 'Migration team and Customer'
        TcViewState      = @('All', 'Open') + $statuses
        TcViewBlocking   = 'All', 'Blocking'
    }
    $team = @(Get-TcProperty $Book['Project'] 'team' @() | Where-Object { $_ })
    if ($team.Count) { $lists['TcTeam'] = $team }

    $row += 2
    & $heading $row 'Lists'
    $row++
    $column = 0
    foreach ($name in $lists.Keys) {
        $column++
        Write-TcWorkbookValue -Sheet $sheet -Row $row -Column $column -Value $name
        $values = @($lists[$name])
        for ($i = 0; $i -lt $values.Count; $i++) { Write-TcWorkbookValue -Sheet $sheet -Row ($row + 1 + $i) -Column $column -Value $values[$i] }
        [void]$Book['Package'].Workbook.Names.Add($name, $sheet.Cells[($row + 1), $column, ($row + $values.Count), $column])
    }
    Add-TcWorkbookHeaderStyle -Book $Book -Sheet $sheet -Row $row -LastColumn $column

    $Book['Lists'] = $lists
    for ($c = 1; $c -le [math]::Max($column, 4); $c++) { $sheet.Column($c).Width = if ($c -eq 2) { 32 } else { 20 } }
}

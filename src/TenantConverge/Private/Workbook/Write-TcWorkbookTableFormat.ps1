function Write-TcWorkbookTableFormat {
    <#
    .SYNOPSIS
    Adds the drop-down menus and the colors of the tables.

    .DESCRIPTION
    The color of a tenant follows its role, and a role is a value of this module. A rule built on a tenant
    name would put text of a tenant in a formula. A role that is not in the project gets no rule.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $theme = $Book['Theme']
    $tables = $Book['Tables']
    $address = {
        param($Table, [string]$Column)
        $letter = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($Table['Columns'][$Column])
        "$letter$($Table['First']):$letter$($Table['Last'])"
    }
    $status = [ordered]@{ 'Done' = 'Good'; 'In progress' = 'Info'; 'Blocked' = 'Bad'; 'To do' = 'Plain'; 'Not applicable' = 'Plain'; 'To read' = 'Warn' }
    $severity = [ordered]@{ Critical = 'Bad'; High = 'Warn'; Medium = 'Info'; Low = 'Plain'; Info = 'Plain' }
    $roles = @(@(Get-TcProperty $Book['Plan'] 'tenants' @() | ForEach-Object { $_['role'] }) + 'All')

    $colorTenant = {
        param($Table)
        $roleLetter = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($Table['Columns']['Role'])
        foreach ($role in $roles) {
            $format = $Table['Sheet'].ConditionalFormatting.AddExpression($Table['Sheet'].Cells[(& $address $Table 'Tenant')])
            $format.Formula = "`$$roleLetter$($Table['First'])=`"$role`""
            $format.Style.Fill.BackgroundColor.Color = ConvertTo-TcWorkbookColor $theme['Roles'][$role]
            $format.Style.Font.Color.Color = [System.Drawing.Color]::White
        }
    }

    $actionPlan = $tables['ActionPlan']
    if ($actionPlan['Count']) {
        $sheet = $actionPlan['Sheet']
        & $colorTenant $actionPlan
        Add-TcWorkbookList -Sheet $sheet -Address (& $address $actionPlan 'Status') -List 'TcStatus'
        if ($Book['Lists'].Contains('TcTeam')) { Add-TcWorkbookList -Sheet $sheet -Address (& $address $actionPlan 'Assigned to') -List 'TcTeam' -Free }
        Add-TcWorkbookValueFormat -Book $Book -Sheet $sheet -Address (& $address $actionPlan 'Status') -Rule $status
        Add-TcWorkbookValueFormat -Book $Book -Sheet $sheet -Address (& $address $actionPlan 'Severity') -Rule $severity
        Add-TcWorkbookValueFormat -Book $Book -Sheet $sheet -Address (& $address $actionPlan 'Blocking') -Rule ([ordered]@{ Yes = 'Bad' })
        Add-TcWorkbookValueFormat -Book $Book -Sheet $sheet -Address (& $address $actionPlan 'Confirmation') -Rule ([ordered]@{ Unconfirmed = 'Warn' })
        Add-TcWorkbookValueFormat -Book $Book -Sheet $sheet -Address (& $address $actionPlan 'Kind') -Rule ([ordered]@{ 'Orphan' = 'Warn' })

        $bar = $sheet.ConditionalFormatting.AddDatabar($sheet.Cells[(& $address $actionPlan 'Progress')], (ConvertTo-TcWorkbookColor $theme['Roles']['S1']))
        $bar.LowValue.Type = 'Num'
        $bar.LowValue.Value = 0
        $bar.HighValue.Type = 'Num'
        $bar.HighValue.Value = 1

        $statusLetter = [OfficeOpenXml.ExcelCellAddress]::GetColumnLetter($actionPlan['Columns']['Status'])
        $strike = $sheet.ConditionalFormatting.AddExpression($sheet.Cells[(& $address $actionPlan 'What to do')])
        $strike.Formula = "`$$statusLetter$($actionPlan['First'])=`"Done`""
        $strike.Style.Font.Strike = $true
        $strike.Style.Font.Color.Color = ConvertTo-TcWorkbookColor $theme['Muted']
    }

    $steps = $tables['DetailedSteps']
    if ($steps['Count']) {
        & $colorTenant $steps
        Add-TcWorkbookList -Sheet $steps['Sheet'] -Address (& $address $steps 'Status') -List 'TcStepStatus'
        Add-TcWorkbookValueFormat -Book $Book -Sheet $steps['Sheet'] -Address (& $address $steps 'Status') -Rule $status
        Add-TcWorkbookValueFormat -Book $Book -Sheet $steps['Sheet'] -Address (& $address $steps 'Type') -Rule ([ordered]@{ 'Watch point' = 'Warn' })
    }

    $settings = $tables['TargetConfigurations']
    if ($settings['Count']) {
        & $colorTenant $settings
        Add-TcWorkbookList -Sheet $settings['Sheet'] -Address (& $address $settings 'Applied') -List 'TcYesNo'
        Add-TcWorkbookValueFormat -Book $Book -Sheet $settings['Sheet'] -Address (& $address $settings 'Applied') -Rule ([ordered]@{ Yes = 'Good' })
        Add-TcWorkbookValueFormat -Book $Book -Sheet $settings['Sheet'] -Address (& $address $settings 'Origin') -Rule ([ordered]@{ 'Important gap' = 'Warn'; 'Orphan' = 'Warn' })
        Add-TcWorkbookValueFormat -Book $Book -Sheet $settings['Sheet'] -Address (& $address $settings 'Current') -Rule ([ordered]@{ 'Not measured' = 'Plain' })
    }

    $matrix = $tables['IdentityMatrix']
    if ($matrix['Count']) {
        & $colorTenant $matrix
        Add-TcWorkbookList -Sheet $matrix['Sheet'] -Address (& $address $matrix 'Validated decision') -List 'TcMatrixDecision'
        Add-TcWorkbookValueFormat -Book $Book -Sheet $matrix['Sheet'] -Address (& $address $matrix 'Proposed decision') -Rule ([ordered]@{ 'To review' = 'Warn'; 'Create' = 'Good'; 'Duplicate' = 'Info'; 'No draft' = 'Bad'; 'No account' = 'Plain' })
    }

    $decisions = $tables['Decisions']
    if ($decisions['Count']) {
        & $colorTenant $decisions
        Add-TcWorkbookList -Sheet $decisions['Sheet'] -Address (& $address $decisions 'Status') -List 'TcDecisionStatus'
        Add-TcWorkbookValueFormat -Book $Book -Sheet $decisions['Sheet'] -Address (& $address $decisions 'Status') -Rule ([ordered]@{ Open = 'Warn'; Decided = 'Good'; Postponed = 'Plain' })
    }

    if ($tables.ContainsKey('Remediations')) {
        $remediations = $tables['Remediations']
        Add-TcWorkbookValueFormat -Book $Book -Sheet $remediations['Sheet'] -Address (& $address $remediations 'Test status') -Rule ([ordered]@{ Untested = 'Bad'; Tested = 'Good' })
        Add-TcWorkbookValueFormat -Book $Book -Sheet $remediations['Sheet'] -Address (& $address $remediations 'Nature') -Rule ([ordered]@{ Automated = 'Good'; Decision = 'Warn'; Partial = 'Info'; Report = 'Plain' })
    }
}

function Write-TcActionPlanSheet {
    <#
    .SYNOPSIS
    Writes the Action plan tab: one row per action of the assessment and per task of the plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $rows = @(Get-TcWorkbookWorkItem -Plan $Book['Plan'])
    $actions = @($rows | Where-Object { $_['Kind'] -eq 'Action' }).Count
    $tasks = $rows.Count - $actions
    $recorded = @($Book['Tracking'] | Where-Object { $_['Type'] -in 'action', 'task', '' })
    $rows = @(Merge-TcWorkbookTracking -Row $rows -Tracking $recorded -Orphan @{
            Kind = 'Orphan'; Role = 'All'; Tenant = 'All tenants'; Status = 'To do'; LabelColumn = 'What to do'
            Finding = 'This row of the tracking file matches nothing in this plan. It stays here so that nothing is lost.'
        })
    $sheet = Add-TcWorkbookSheet -Book $Book -Name 'Action plan' -Title 'Action plan' -Width 28 -Filters `
        -Subtitle "$actions action(s) from the assessment and $tasks task(s) of the plan" `
        -Legend 'Fill in the yellow columns. Use the filter buttons of the header row. Task confirmation says whether the assessment could read what the task depends on.'

    $columns = @(
        @{ Name = 'ID'; Width = 22; Small = $true; Keep = $true }
        @{ Name = 'Kind'; Width = 8; Center = $true; Keep = $true }
        @{ Name = 'Role'; Width = 7; Center = $true; Keep = $true }
        @{ Name = 'Tenant'; Width = 18; Center = $true; Bold = $true; Wrap = $true; Keep = $true }
        @{ Name = 'Wave'; Width = 6; Center = $true }
        @{ Name = 'Moment'; Width = 13; Center = $true; Keep = $true }
        @{ Name = 'Workload'; Width = 16; Wrap = $true }
        @{ Name = 'What to do'; Width = 52; Wrap = $true; Bold = $true; Keep = $true }
        @{ Name = 'Severity'; Width = 9; Center = $true; Bold = $true; Keep = $true }
        @{ Name = 'Blocking'; Width = 9; Center = $true; Bold = $true; Keep = $true }
        @{ Name = 'Owner'; Width = 26; Center = $true; Keep = $true }
        @{ Name = 'Duration'; Width = 13; Small = $true; Wrap = $true }
        @{ Name = 'Status'; Width = 12; Center = $true; Bold = $true; Input = $true }
        @{ Name = 'Progress'; Width = 9; Center = $true; Keep = $true }
        @{ Name = 'Steps done'; Width = 7; Center = $true; Keep = $true }
        @{ Name = 'Steps'; Width = 7; Center = $true; Keep = $true }
        @{ Name = 'Open'; Width = 7; Center = $true; Keep = $true }
        @{ Name = 'Finding'; Width = 56; Wrap = $true }
        @{ Name = 'Recommended action'; Width = 50; Wrap = $true }
        @{ Name = 'Why'; Width = 50; Wrap = $true }
        @{ Name = 'Goal'; Width = 46; Wrap = $true }
        @{ Name = 'Confirmation'; Width = 12; Center = $true; Keep = $true }
        @{ Name = 'Reason'; Width = 40; Wrap = $true }
        @{ Name = 'Item count'; Width = 7; Center = $true }
        @{ Name = 'Items'; Width = 50; Small = $true; Clip = $true }
        @{ Name = 'Question'; Width = 44; Wrap = $true }
        @{ Name = 'Remediations'; Width = 26; Small = $true; Wrap = $true }
        @{ Name = 'Assigned to'; Width = 16; Input = $true }
        @{ Name = 'Note'; Width = 30; Input = $true; Wrap = $true }
        @{ Name = 'Done on'; Width = 11; Input = $true }
    )

    $table = Add-TcWorkbookTable -Book $Book -Sheet $sheet -Name 'ActionPlan' -Column $columns -Row $rows -Empty 'No action and no task: the plan has nothing to do. Check the Dashboard to see what could be read.'
    if ($rows.Count) { $sheet.View.FreezePanes($table['First'], 4) }
}

function Write-TcDetailedStepSheet {
    <#
    .SYNOPSIS
    Writes the Detailed steps tab: what to check, read, do and verify for each item of the action plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $rows = @(Get-TcWorkbookStep -Item $Book['Tables']['ActionPlan']['Rows'] -Plan $Book['Plan'])
    $toTick = @($rows | Where-Object { $_['Type'] -ne 'Watch point' }).Count
    $sheet = Add-TcWorkbookSheet -Book $Book -Name 'Detailed steps' -Title 'Detailed steps' -Filters `
        -Subtitle "$toTick line(s) to tick and $($rows.Count - $toTick) watch point(s), with where to act and the command to copy" `
        -Legend 'Fill in the yellow columns: a step marked Done moves its item in the Action plan. A command that changes something acts on the tenant for real: read it before you run it.'

    $columns = @(
        @{ Name = 'Item'; Width = 22; Small = $true; Keep = $true }
        @{ Name = 'Role'; Width = 7; Center = $true; Keep = $true }
        @{ Name = 'Tenant'; Width = 18; Center = $true; Bold = $true; Wrap = $true; Keep = $true }
        @{ Name = 'Moment'; Width = 13; Center = $true }
        @{ Name = 'Item title'; Width = 38; Small = $true; Wrap = $true }
        @{ Name = 'Type'; Width = 12; Center = $true; Keep = $true }
        @{ Name = 'No.'; Width = 5; Center = $true; Keep = $true }
        @{ Name = 'What to do'; Width = 62; Wrap = $true }
        @{ Name = 'Where'; Width = 38; Small = $true; Wrap = $true }
        @{ Name = 'Command'; Width = 56; Small = $true; Wrap = $true }
        @{ Name = 'Owner'; Width = 26; Center = $true }
        @{ Name = 'Status'; Width = 12; Center = $true; Bold = $true; Input = $true }
        @{ Name = 'Done on'; Width = 11; Input = $true }
        @{ Name = 'Note'; Width = 28; Input = $true; Wrap = $true }
    )

    $table = Add-TcWorkbookTable -Book $Book -Sheet $sheet -Name 'DetailedSteps' -Column $columns -Row $rows -Empty 'No step: no item of the plan has a procedure.'
    if ($rows.Count) { $sheet.View.FreezePanes($table['First'], 3) }
}

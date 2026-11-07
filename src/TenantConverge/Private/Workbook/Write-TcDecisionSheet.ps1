function Write-TcDecisionSheet {
    <#
    .SYNOPSIS
    Writes the Decisions tab: the questions to settle, each with the action or the task it comes from.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $names = @{ All = 'All tenants' }
    foreach ($tenant in @(Get-TcProperty $Book['Plan'] 'tenants' @())) { $names[$tenant['role']] = $tenant['displayName'] }

    $rows = @(foreach ($line in @(Get-TcProperty $Book['Plan'] 'decisions' @())) {
            [ordered]@{
                ID = $line['id']; Role = $line['role']; Tenant = $names[$line['role']]; Question = $line['question']; Owner = Get-TcProperty $line 'owner'; Moment = Get-TcProperty $line 'moment'
                Origin = Get-TcProperty $line 'origin'; Reference = Get-TcProperty $line 'reference'; Status = 'Open'
            }
        })

    $recorded = @($Book['Tracking'] | Where-Object { $_['Type'] -eq 'decision' })
    $rows = @(Merge-TcWorkbookTracking -Row $rows -Tracking $recorded -Prefix 'D-' -Orphan @{ Role = 'All'; Tenant = 'All tenants'; Origin = 'Orphan'; Status = 'Open'; LabelColumn = 'Question' })

    $sheet = Add-TcWorkbookSheet -Book $Book -Name 'Decisions' -Title 'Decisions' -Width 13 -Filters `
        -Subtitle "$($rows.Count) question(s) to settle with the customer" `
        -Legend 'Fill in the yellow columns: status, answer, who decided and when.'

    $columns = @(
        @{ Name = 'ID'; Width = 24; Small = $true; Keep = $true }
        @{ Name = 'Role'; Width = 7; Center = $true; Keep = $true }
        @{ Name = 'Tenant'; Width = 18; Center = $true; Bold = $true; Wrap = $true; Keep = $true }
        @{ Name = 'Question'; Width = 64; Wrap = $true; Bold = $true }
        @{ Name = 'Owner'; Width = 26; Center = $true }
        @{ Name = 'Moment'; Width = 13; Center = $true }
        @{ Name = 'Origin'; Width = 8; Center = $true }
        @{ Name = 'Reference'; Width = 22; Small = $true }
        @{ Name = 'Open'; Width = 7; Center = $true; Keep = $true }
        @{ Name = 'Status'; Width = 10; Center = $true; Bold = $true; Input = $true }
        @{ Name = 'Answer'; Width = 44; Input = $true; Wrap = $true }
        @{ Name = 'Decided by'; Width = 18; Input = $true }
        @{ Name = 'Date'; Width = 11; Input = $true }
    )

    $table = Add-TcWorkbookTable -Book $Book -Sheet $sheet -Name 'Decisions' -Column $columns -Row $rows -Empty 'No question to settle in this plan.'
    if ($rows.Count) { $sheet.View.FreezePanes($table['First'], 4) }
}

function Write-TcRemediationSheet {
    <#
    .SYNOPSIS
    Writes the Remediations tab, for a plan that has some. An empty list writes nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $plan = $Book['Plan']
    $items = @(Get-TcProperty $plan 'remediations' @())
    if (-not $items.Count) { return }

    $badges = Get-TcWorkbookRemediationBadge -Plan $plan
    $actions = @(Get-TcProperty $plan 'actions' @())
    $rows = @(foreach ($item in $items) {
            $id = [string](Get-TcProperty $item 'id')
            [ordered]@{
                ID = $id; Title = Get-TcProperty $item 'title'; Workload = Get-TcProperty $item 'workload'; Rules = @(Get-TcProperty $item 'ruleIds' @()) -join ', '
                Nature = Get-TcProperty $item 'nature'; Risk = Get-TcProperty $item 'risk'; Reversible = [bool](Get-TcProperty $item 'reversible')
                Permissions = @(Get-TcProperty $item 'permissions' @()) -join ', '; 'Test status' = $badges[$id]; 'Test evidence' = Get-TcProperty $item 'testedEvidence'
                Actions = @($actions | Where-Object { $id -in @(Get-TcProperty $_ 'remediations' @()) } | ForEach-Object { $_['id'] }) -join ', '
            }
        })

    $sheet = Add-TcWorkbookSheet -Book $Book -Name 'Remediations' -Title 'Remediations' -Width 11 -Filters `
        -Subtitle "$($rows.Count) script(s) that can correct a finding. The assessment never runs them." `
        -Legend 'UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.'

    $columns = @(
        @{ Name = 'ID'; Width = 24; Small = $true }
        @{ Name = 'Title'; Width = 56; Wrap = $true; Bold = $true }
        @{ Name = 'Workload'; Width = 18; Wrap = $true }
        @{ Name = 'Rules'; Width = 24; Small = $true; Wrap = $true }
        @{ Name = 'Nature'; Width = 11; Center = $true }
        @{ Name = 'Risk'; Width = 9; Center = $true }
        @{ Name = 'Reversible'; Width = 10; Center = $true }
        @{ Name = 'Permissions'; Width = 36; Small = $true; Wrap = $true }
        @{ Name = 'Test status'; Width = 10; Center = $true; Bold = $true; Keep = $true }
        @{ Name = 'Test evidence'; Width = 30; Small = $true; Wrap = $true }
        @{ Name = 'Actions'; Width = 30; Small = $true; Wrap = $true }
    )

    $table = Add-TcWorkbookTable -Book $Book -Sheet $sheet -Name 'Remediations' -Column $columns -Row $rows -Empty 'No remediation.'
    $sheet.View.FreezePanes($table['First'], 3)
}

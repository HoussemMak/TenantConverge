function Write-TcTargetConfigurationSheet {
    <#
    .SYNOPSIS
    Writes the Target configurations tab: the settings to put in place, with their current and target values.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Book
    )

    $rows = @(foreach ($line in @(Get-TcProperty $Book['Plan'] 'targetConfigurations' @())) {
            $current = [string](Get-TcProperty $line 'current')
            [ordered]@{
                Role = $line['role']; Tenant = $line['tenant']; Group = Get-TcProperty $line 'group'; Setting = $line['setting']; Current = $(if ($current) { $current } else { 'Not measured' })
                Target = Get-TcProperty $line 'target'; Where = Get-TcProperty $line 'where'; Origin = Get-TcProperty $line 'origin'; Action = Get-TcProperty $line 'action'; Applied = 'No'
            }
        })
    $settings = $rows.Count
    $rows = @(Merge-TcWorkbookSetting -Row $rows -Tracking @($Book['Tracking'] | Where-Object { $_['Type'] -eq 'configuration' }))

    $sheet = Add-TcWorkbookSheet -Book $Book -Name 'Target configurations' -Title 'Target configurations' -Width 13 -Filters `
        -Subtitle "$settings setting(s) to put in place: those of the procedures, the gaps with the target and the identity matrices" `
        -Legend 'Fill in the yellow columns. Not measured means the assessment has no value for this setting. It is not a value.'

    $columns = @(
        @{ Name = 'Role'; Width = 7; Center = $true }
        @{ Name = 'Tenant'; Width = 18; Center = $true; Bold = $true; Wrap = $true }
        @{ Name = 'Group'; Width = 22; Wrap = $true }
        @{ Name = 'Setting'; Width = 50; Wrap = $true }
        @{ Name = 'Current'; Width = 28; Small = $true; Wrap = $true }
        @{ Name = 'Target'; Width = 42; Wrap = $true; Bold = $true }
        @{ Name = 'Where'; Width = 40; Small = $true; Wrap = $true }
        @{ Name = 'Origin'; Width = 14; Center = $true; Small = $true }
        @{ Name = 'Action'; Width = 22; Small = $true }
        @{ Name = 'Open'; Width = 7; Center = $true; Keep = $true }
        @{ Name = 'Applied'; Width = 9; Center = $true; Bold = $true; Input = $true }
        @{ Name = 'Done on'; Width = 11; Input = $true }
        @{ Name = 'Note'; Width = 28; Input = $true; Wrap = $true }
    )

    $table = Add-TcWorkbookTable -Book $Book -Sheet $sheet -Name 'TargetConfigurations' -Column $columns -Row $rows -Empty 'No setting to put in place in this plan.'
    if ($rows.Count) { $sheet.View.FreezePanes($table['First'], 4) }
}

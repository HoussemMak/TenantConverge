function Get-TcRuleSetting {
    <#
    .SYNOPSIS
    Returns the value of a setting from a Setting and Value table, or nothing when it is not there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Role,
        [Parameter(Mandatory, Position = 1)][string]$Table,
        [Parameter(Mandatory, Position = 2)][string]$Setting
    )

    $row = Get-TcRuleRow $Role $Table | Where-Object { (Get-TcProperty $_ 'Setting') -eq $Setting } | Select-Object -First 1
    if ($row) { return Get-TcProperty $row 'Value' }
    $null
}

function Get-TcRuleRow {
    <#
    .SYNOPSIS
    Returns the rows of a table for the running rule set. A table that was not collected gives nothing.

    .DESCRIPTION
    The read goes through Test-TcRuleTable, which notes the rule that had to do without the table.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Role,
        [Parameter(Mandatory, Position = 1)][string]$Table
    )

    if (-not (Test-TcRuleTable $Role $Table)) { return }
    @($script:TcRuleRun['Tenants'][$Role]['tables'][$Table])
}

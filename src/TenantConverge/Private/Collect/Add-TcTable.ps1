function Add-TcTable {
    <#
    .SYNOPSIS
    Sets or extends a table of the current tenant, and ties it to the running collector.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Position = 1)][AllowNull()]$Rows,
        [switch]$Append
    )

    $tables = $script:TcCurrentTenant['tables']
    if (-not $tables.Contains($Name) -or -not $Append) { $tables[$Name] = [System.Collections.Generic.List[object]]::new() }
    foreach ($row in @($Rows)) {
        if ($null -ne $row) { $tables[$Name].Add($row) }
    }

    $collector = $script:TcCurrentCollector
    if ($collector -and $collector['tables'] -notcontains $Name) { $collector['tables'].Add($Name) }
}

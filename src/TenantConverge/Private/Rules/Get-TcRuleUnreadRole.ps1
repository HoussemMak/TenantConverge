function Get-TcRuleUnreadRole {
    <#
    .SYNOPSIS
    Returns the roles for which one of the tables could not be read, so a total across tenants misses them.

    .DESCRIPTION
    A tenant that simply does not have the service adds nothing to a total: it is not returned.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$Role,
        [Parameter(Mandatory, Position = 1)][string[]]$Table
    )

    foreach ($tenant in $Role) {
        $missing = @($Table | Where-Object {
                -not (Test-TcRuleTable $tenant $_) -and (Get-TcTableState -Snapshot $script:TcRuleRun['Snapshot'] -Role $tenant -Table $_).Status -ne 'License or service missing'
            })
        if ($missing.Count) { $tenant }
    }
}

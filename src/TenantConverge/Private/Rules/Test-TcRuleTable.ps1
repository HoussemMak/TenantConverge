function Test-TcRuleTable {
    <#
    .SYNOPSIS
    Tells whether a table was collected, and notes it when a rule had to do without it.

    .DESCRIPTION
    Every read of the rules comes through here, so the run knows which workload of which tenant judged
    something it could not see. Get-TcReadiness gives such a workload no credit. An empty table of a
    Partial collector counts as not read: what it would hold may be in the part that was missed. A table
    whose service the tenant simply does not have is not noted: there was nothing to read.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Role,
        [Parameter(Mandatory, Position = 1)][string]$Table
    )

    $run = $script:TcRuleRun
    $tables = Get-TcProperty (Get-TcProperty $run['Tenants'] $Role) 'tables'
    if ($null -ne $tables -and $tables.Contains($Table) -and @($tables[$Table]).Count) { return $true }

    $state = Get-TcTableState -Snapshot $run['Snapshot'] -Role $Role -Table $Table
    if ($state.State -eq 'NotUsed') { return $true }

    if ($run['Workload']) {
        $key = '{0}|{1}|{2}|{3}' -f $run['Role'], $run['Workload'], $Role, $Table
        if (-not $run['UnreadKeys'].Contains($key)) {
            [void]$run['UnreadKeys'].Add($key)
            if ($state.Status -ne 'License or service missing') {
                $run['Unread'].Add([ordered]@{ role = $run['Role']; workload = $run['Workload']; tenantRole = $Role; table = $Table; status = $state.Status })
            }
        }
    }
    $false
}

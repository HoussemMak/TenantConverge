function Get-TcWorkbookWorkloadState {
    <#
    .SYNOPSIS
    Says in a few words what is known of a workload of a tenant.

    .DESCRIPTION
    The state comes from Get-TcReadiness, and three cases must never read as a result. No service: the
    tenant does not have it. Not used: every table of the workload was read, and all are empty. Not
    collected: nothing could be read, even if a rule found something on the side of another tenant. A
    state that rests on part of the data says so: a Passed drawn from a part only is not a pass.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Line,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][string]$Role
    )

    if (-not $Line.Applicable) { return 'No service' }
    if ($Line.State -eq 'Not collected' -or $Line.Coverage -in 'Failed', 'None') { return 'Not collected' }
    if (-not $Line.Complete) { return "$($Line.State), partly read" }

    if ($Line.State -eq 'Passed') {
        $dictionary = Get-TcTableDictionary
        $tables = @($dictionary.Keys | Where-Object { $dictionary[$_]['workload'] -eq $Line.Workload })
        $states = @($tables | ForEach-Object { (Get-TcTableState -Snapshot $Snapshot -Role $Role -Table $_).State })
        if ($states.Count -and @($states | Where-Object { $_ -ne 'NotUsed' }).Count -eq 0) { return 'Not used' }
    }
    $Line.State
}

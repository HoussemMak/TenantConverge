function Get-TcTableState {
    <#
    .SYNOPSIS
    Tells apart a table with rows, a service that is not used, and a table that was not collected.

    .DESCRIPTION
    State is Collected when the table has rows, NotUsed when it was collected and is empty, NotFullyRead
    when it is empty and a collector of the table was Partial, so its rows may be in what was missed, and
    NotCollected when it is missing from the snapshot. In those last two cases, Status and Remedy come from
    the collector of the table. Reports must show both as a gap, never as zero. A Partial collector that
    returned rows still counts as collected.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string]$Table
    )

    $producers = @(Get-TcProperty (Get-TcTableDictionary)[$Table] 'collectors' @())

    $tables = Get-TcProperty (Get-TcProperty $Snapshot['tenants'] $Role) 'tables'
    if ($tables -and $tables.Contains($Table)) {
        $rows = @($tables[$Table]).Count
        if ($rows) { return [pscustomobject]@{ State = 'Collected'; Status = 'OK'; Rows = $rows; Message = ''; Remedy = '' } }

        $partial = @($Snapshot['coverage']) |
            Where-Object { (Get-TcProperty $_ 'role') -eq $Role -and (Get-TcProperty $_ 'id') -in $producers -and (Get-TcProperty $_ 'status') -eq 'Partial' } |
            Select-Object -First 1
        if ($partial) { return [pscustomobject]@{ State = 'NotFullyRead'; Status = 'Partial'; Rows = 0; Message = Get-TcProperty $partial 'message'; Remedy = Get-TcProperty $partial 'remedy' } }
        return [pscustomobject]@{ State = 'NotUsed'; Status = 'OK'; Rows = 0; Message = ''; Remedy = '' }
    }

    $line = @($Snapshot['coverage']) |
        Where-Object { (Get-TcProperty $_ 'role') -eq $Role -and (Get-TcProperty $_ 'id') -in $producers -and (Get-TcProperty $_ 'status') -ne 'OK' } |
        Select-Object -First 1
    if (-not $line) {
        $line = @($Snapshot['coverage']) |
            Where-Object { (Get-TcProperty $_ 'role') -eq $Role -and (Get-TcProperty $_ 'id') -in $producers } |
            Select-Object -First 1
    }
    if (-not $line) {
        return [pscustomobject]@{ State = 'NotCollected'; Status = 'Not run'; Rows = 0; Message = 'The collector of this table did not run.'; Remedy = 'Run the assessment again.' }
    }

    [pscustomobject]@{
        State   = 'NotCollected'
        Status  = Get-TcProperty $line 'status'
        Rows    = 0
        Message = Get-TcProperty $line 'message'
        Remedy  = Get-TcProperty $line 'remedy'
    }
}

function Get-TcBlockedRequirement {
    <#
    .SYNOPSIS
    Finds a table a collector needs and that this run did not collect, and says why.

    .DESCRIPTION
    Without this, a collector that reads another table would see no rows and report an empty result,
    which would read as a service that is not used. The collector takes the status of the one it
    depends on instead. An empty table from a Partial collector counts as not collected here, because
    its rows may be in what was missed. A table with rows is enough to run on, even from a Partial one.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Collector
    )

    foreach ($table in @(Get-TcProperty $Collector 'Requires' @())) {
        $producers = @(Get-TcProperty (Get-TcTableDictionary)[$table] 'collectors')
        $lines = @($script:TcCurrentTenant['coverage']) | Where-Object { (Get-TcProperty $_ 'id') -in $producers }
        $names = $producers -join ', '

        if ($script:TcCurrentTenant['tables'].Contains($table)) {
            $partial = $lines | Where-Object { (Get-TcProperty $_ 'status') -eq 'Partial' } | Select-Object -First 1
            if (@(Get-TcTable $table).Count -or -not $partial) { continue }
            return @{
                status  = 'Failed'
                message = "Not collected, because $names read the table $table only in part and found no rows."
                remedy  = Get-TcProperty $partial 'remedy'
            }
        }

        $line = $lines | Select-Object -First 1
        if (-not $line) {
            return @{
                status  = 'Failed'
                message = "This needs the table $table from $names, which this run did not collect."
                remedy  = "Collect the workload of $names in the same run."
            }
        }

        $status = Get-TcProperty $line 'status'
        if ($status -in 'OK', 'Partial') { $status = 'Failed' }
        return @{
            status  = $status
            message = "Not collected, because $names could not read the table $table."
            remedy  = Get-TcProperty $line 'remedy'
        }
    }
}

function Test-TcSnapshot {
    <#
    .SYNOPSIS
    Checks a snapshot against the format and returns one record per problem.

    .DESCRIPTION
    Returns records with Code, Path and Message, and nothing when the snapshot is valid. The snapshot is
    the contract between collection and everything that reads it, so a table or a column that is not in
    the dictionary is a problem.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Snapshot
    )

    function Add-Problem {
        param([string]$Code, [string]$Path, [string]$Message)
        [pscustomobject]@{ Code = $Code; Path = $Path; Message = $Message }
    }

    $version = Get-TcProperty $Snapshot 'schemaVersion'
    if ($version -ne $script:TcSchemaVersion) {
        Add-Problem 'TC2001' 'schemaVersion' "This snapshot uses schema version $version. This module reads version $script:TcSchemaVersion."
    }

    $meta = Get-TcProperty $Snapshot 'meta'
    foreach ($key in 'project', 'started', 'finished', 'moduleVersion', 'depth') {
        if ($null -eq $meta -or -not $meta.Contains($key)) { Add-Problem 'TC2002' "meta.$key" "The key '$key' is missing." }
    }

    $statuses = 'OK', 'Partial', 'Insufficient access', 'Module missing', 'License or service missing', 'Failed'
    $coverageKeys = 'role', 'tenant', 'id', 'workload', 'title', 'service', 'status', 'message', 'remedy', 'duration', 'rows', 'tables'
    $coverage = @(Get-TcProperty $Snapshot 'coverage' @())
    for ($i = 0; $i -lt $coverage.Count; $i++) {
        $line = $coverage[$i]
        foreach ($key in $coverageKeys) {
            if (-not $line.Contains($key)) { Add-Problem 'TC2006' "coverage[$i].$key" "The key '$key' is missing." }
        }
        if ((Get-TcProperty $line 'status') -cnotin $statuses) {
            Add-Problem 'TC2006' "coverage[$i].status" "'$(Get-TcProperty $line 'status')' is not a coverage status."
        }
    }

    $tenants = Get-TcProperty $Snapshot 'tenants'
    if ($null -eq $tenants -or -not $tenants.Contains('Target')) { Add-Problem 'TC2003' 'tenants.Target' 'A snapshot needs the target tenant.' }
    if ($null -eq $tenants) { return }

    $dictionary = Get-TcTableDictionary
    foreach ($role in @($tenants.Keys)) {
        if ($role -cnotin 'Target', 'S1', 'S2', 'S3') {
            Add-Problem 'TC2003' "tenants.$role" "'$role' is not a role."
            continue
        }

        $tables = Get-TcProperty $tenants[$role] 'tables'
        if ($null -eq $tables) {
            Add-Problem 'TC2003' "tenants.$role.tables" 'The tables are missing.'
            continue
        }

        foreach ($key in @($tables.Keys)) {
            if (-not $dictionary.Contains($key)) {
                Add-Problem 'TC2004' "tenants.$role.tables.$key" "'$key' is not in the table dictionary."
                continue
            }
            $columns = $dictionary[$key]['columns']
            $seen = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($row in @($tables[$key])) {
                foreach ($column in @($row.Keys)) {
                    if ($seen.Add([string]$column) -and $column -cnotin $columns) {
                        Add-Problem 'TC2005' "tenants.$role.tables.$key" "'$column' is not a column of $key."
                    }
                }
            }
        }
    }
}

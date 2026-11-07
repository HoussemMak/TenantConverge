function Restore-TcResumedTenant {
    <#
    .SYNOPSIS
    Brings back what an interrupted run collected for a tenant.

    .DESCRIPTION
    A tenant that runs again keeps the collectors that ended OK or Partial, and the others run again. With
    -KeepFailed, for a tenant this run leaves out, every coverage line stays: nothing will run again, and
    a failed line is what says that its tables were not collected.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Role,
        [switch]$KeepFailed
    )

    $resumed = Get-TcProperty $script:TcResume $Role
    if (-not $resumed) { return }

    Select-TcCollectionTenant -Role $Role
    $current = $script:TcCurrentTenant
    $current['tenantId'] = [string](Get-TcProperty $resumed 'tenantId' '')
    foreach ($line in @(Get-TcProperty $resumed 'coverage' @())) {
        if ($KeepFailed -or (Get-TcProperty $line 'status') -in 'OK', 'Partial') { $current['coverage'].Add($line) }
    }
    $tables = Get-TcProperty $resumed 'tables'
    foreach ($key in @($tables.Keys)) {
        $rows = [System.Collections.Generic.List[object]]::new()
        foreach ($row in @($tables[$key])) { $rows.Add($row) }
        $current['tables'][$key] = $rows
    }
}

function Get-TcCollectionSnapshot {
    <#
    .SYNOPSIS
    Builds a snapshot from what has been collected so far.

    .DESCRIPTION
    Every tenant of the project appears, so a run limited to some tenants still gives a valid snapshot.
    A tenant that was not collected has no table and no coverage line.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [string]$ProjectName = '',
        [string]$Started = '',
        [string]$Finished = '',
        [switch]$Partial
    )

    $tenants = [ordered]@{}
    $coverage = [System.Collections.Generic.List[object]]::new()

    foreach ($role in @($script:TcTenants.Keys)) {
        $tenant = $script:TcTenants[$role]
        $collected = Get-TcProperty $script:TcCollection $role
        $tables = if ($collected) { $collected['tables'] } else { [ordered]@{} }
        $tenantId = Get-TcProperty $tenant 'tenantId'
        if (-not $tenantId -and $collected) { $tenantId = $collected['tenantId'] }

        $tenants[$role] = [ordered]@{
            displayName   = $tenant['displayName']
            primaryDomain = $tenant['primaryDomain']
            tenantId      = [string]$tenantId
            tables        = $tables
        }
        if ($collected) {
            foreach ($line in $collected['coverage']) { $coverage.Add($line) }
        }
    }

    $meta = [ordered]@{
        project       = $ProjectName
        started       = $Started
        finished      = $Finished
        moduleVersion = [string]$MyInvocation.MyCommand.Module.Version
        depth         = $script:TcDepth
    }
    if ($Partial) { $meta['partial'] = $true }

    [ordered]@{ schemaVersion = $script:TcSchemaVersion; meta = $meta; coverage = @($coverage); tenants = $tenants }
}

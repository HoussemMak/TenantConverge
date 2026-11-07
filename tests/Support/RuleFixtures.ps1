# Small snapshots for the rule tests. A fixture holds only the tables a test names, so a table that a
# test leaves out reads as not collected, and every value is fictional.

function New-TcRuleSnapshot {
    <#
    .SYNOPSIS
    Builds a snapshot from tables given by role, for example @{ S1 = @{ users = @(@{ UPN = 'a' }) } }.
    #>
    param(
        [hashtable]$Given = @{},
        [string[]]$Sources = @('S1'),
        [object[]]$Coverage = @()
    )

    $names = @{ Target = 'Summit'; S1 = 'Alpine'; S2 = 'Birch'; S3 = 'Cedar' }
    $tenants = [ordered]@{}
    foreach ($role in @('Target') + $Sources) {
        $tables = [ordered]@{}
        foreach ($table in @(($Given[$role] ?? @{}).Keys)) {
            $tables[$table] = @(foreach ($row in @($Given[$role][$table])) {
                    $copy = [ordered]@{}
                    foreach ($key in $row.Keys) { $copy[$key] = $row[$key] }
                    $copy
                })
        }
        $tenants[$role] = [ordered]@{
            displayName = $names[$role]; primaryDomain = "$($names[$role].ToLowerInvariant()).example"
            tenantId = "id-$role"; tables = $tables
        }
    }

    [ordered]@{
        schemaVersion = 1
        meta          = [ordered]@{ project = 'Fixture'; started = '2026-01-15T08:00:00'; finished = '2026-01-15T09:00:00'; moduleVersion = '0'; depth = 'Complete' }
        coverage      = @($Coverage)
        tenants       = $tenants
    }
}

function New-TcCoverageLine {
    <#
    .SYNOPSIS
    Builds one coverage line of a snapshot.
    #>
    param(
        [string]$Role,
        [string]$Workload,
        [string]$Status = 'OK',
        [string]$Id = 'TEST-01',
        [string[]]$Tables = @()
    )

    [ordered]@{
        role = $Role; tenant = $Role; id = $Id; workload = $Workload; title = "Collector $Id"; service = 'Fictional'; status = $Status
        message = ''; remedy = 'Do something.'; duration = 1; rows = 0; tables = $Tables
    }
}

function Get-TcFakeSnapshot {
    <#
    .SYNOPSIS
    Reads a fictional snapshot, built once per source count in the folder given.
    #>
    param([int]$SourceCount, [string]$Folder, [int]$Seed = 5)

    $path = Join-Path $Folder "fake-$SourceCount-$Seed.json"
    if (-not (Test-Path $path)) {
        & (Join-Path $PSScriptRoot '..' '..' 'tools' 'New-TcFakeSnapshot.ps1') -SourceCount $SourceCount -Seed $Seed -Path $path | Out-Null
    }
    InModuleScope TenantConverge -Parameters @{ Path = $path } {
        param($Path)
        , (Read-TcSnapshot -Path $Path)
    }
}

function Remove-TcPlanRemediation {
    <#
    .SYNOPSIS
    Takes the remediations out of a plan, for a test about a plan that has none.
    #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Plan)

    $Plan['remediations'] = @()
    foreach ($item in @($Plan['actions']) + @($Plan['tasks'])) { if ($item.Contains('remediations')) { $item.Remove('remediations') } }
    $Plan
}

# Fictional projects and plans for the report tests. Everything here is invented, on reserved .example domains.

function New-TcReportProject {
    <#
    .SYNOPSIS
    Builds a valid project object for 1, 2 or 3 sources.
    #>
    param([int]$SourceCount = 3, [string[]]$Team = @('Pat Example', 'Sam Example'))

    $names = @(@('S1', 'Alpine Group', 'alpine.example'), @('S2', 'Birch Partners', 'birch.example'), @('S3', 'Cedar Services', 'cedar.example'))
    [pscustomobject]@{
        schemaVersion = 1
        name          = 'Summit consolidation'
        target        = [pscustomobject]@{ displayName = 'Summit Holdings'; primaryDomain = 'summit.example'; tenantId = $null; state = 'Production' }
        sources       = @(for ($i = 0; $i -lt $SourceCount; $i++) {
                [pscustomobject]@{ role = $names[$i][0]; displayName = $names[$i][1]; primaryDomain = $names[$i][2]; tenantId = $null; wave = $i + 1 }
            })
        access        = [pscustomobject]@{ mode = 'Browser' }
        output        = [pscustomobject]@{ path = './output' }
        team          = @($Team)
    }
}

function Get-TcReportFixture {
    <#
    .SYNOPSIS
    Returns a project, a fresh snapshot, its rule set and its plan, for one source count.
    #>
    param([int]$SourceCount = 3, [string]$Folder, [string[]]$Team = @('Pat Example', 'Sam Example'))

    $snapshot = Get-TcFakeSnapshot -SourceCount $SourceCount -Folder $Folder
    $project = New-TcReportProject -SourceCount $SourceCount -Team $Team
    $ruleSet = Invoke-TcRuleSet -Snapshot $snapshot
    $plan = New-TcPlan -Project $project -Snapshot $snapshot -RuleSet $ruleSet
    @{ Project = $project; Snapshot = $snapshot; RuleSet = $ruleSet; Plan = $plan }
}

function Get-TcReportFixtureData {
    <#
    .SYNOPSIS
    Runs the data step of the report on a fixture.
    #>
    param([hashtable]$Fixture, [string]$TrackingText = '', [string[]]$Log = @())

    $readiness = @(Get-TcReadiness -Snapshot $Fixture['Snapshot'] -RuleSet $Fixture['RuleSet'])
    InModuleScope TenantConverge -Parameters @{ Fixture = $Fixture; Readiness = $readiness; TrackingText = $TrackingText; Log = $Log } {
        param($Fixture, $Readiness, $TrackingText, $Log)
        Get-TcReportData -Project $Fixture['Project'] -Snapshot $Fixture['Snapshot'] -Plan $Fixture['Plan'] -RuleSet $Fixture['RuleSet'] -Readiness $Readiness -TrackingText $TrackingText -Log $Log
    }
}

function Remove-TcReportTable {
    <#
    .SYNOPSIS
    Makes a table look as if its collector failed in one tenant.
    #>
    param($Snapshot, [string]$Role, [string]$Table, [string]$Status = 'Insufficient access')

    $producers = @((InModuleScope TenantConverge { Get-TcTableDictionary })[$Table]['collectors'])
    foreach ($line in @($Snapshot['coverage'])) {
        if ($line['role'] -eq $Role -and $line['id'] -in $producers) { $line['status'] = $Status; $line['message'] = 'Access denied.' }
    }
    $Snapshot['tenants'][$Role]['tables'].Remove($Table)
}

function Clear-TcReportTable {
    <#
    .SYNOPSIS
    Leaves a table empty, with its collector Partial: its rows may be in what was missed.
    #>
    param($Snapshot, [string]$Role, [string]$Table)

    $producers = @((InModuleScope TenantConverge { Get-TcTableDictionary })[$Table]['collectors'])
    foreach ($line in @($Snapshot['coverage'])) {
        if ($line['role'] -eq $Role -and $line['id'] -in $producers) { $line['status'] = 'Partial'; $line['message'] = 'Part of it was refused.' }
    }
    $Snapshot['tenants'][$Role]['tables'][$Table] = @()
}

function Clear-TcReportTenant {
    <#
    .SYNOPSIS
    Makes one tenant look as if nothing could be collected.
    #>
    param($Snapshot, [string]$Role)

    foreach ($line in @($Snapshot['coverage'])) {
        if ($line['role'] -eq $Role) { $line['status'] = 'Insufficient access'; $line['message'] = 'Access denied.'; $line['rows'] = 0 }
    }
    $Snapshot['tenants'][$Role]['tables'] = [ordered]@{}
}

function New-TcEmptyPlan {
    <#
    .SYNOPSIS
    A plan with nothing in it.
    #>
    [ordered]@{
        schemaVersion = 1
        meta          = [ordered]@{ moments = @('Now', 'Preparation', 'Before cutover', 'Cutover', 'After cutover', 'Closure') }
        tenants       = @(); waves = @(); actions = @(); targetConfigurations = @(); tasks = @(); decisions = @(); procedures = [ordered]@{}; remediations = @()
    }
}

function Get-TcSyntheticRemediation {
    <#
    .SYNOPSIS
    A short remediation list that follows the contract of the plan, with one script marked as tested.
    #>
    @(
        [ordered]@{ id = 'REM-001'; title = 'Close the anonymous links'; workload = 'SharePoint and OneDrive'; ruleIds = @('SPO-SHARING'); nature = 'Decision'; risk = 'High'; reversible = $false; permissions = @('Sites.FullControl.All'); testedOnRealTenant = $false; testedEvidence = $null }
        [ordered]@{ id = 'REM-002'; title = 'Report the inactive accounts'; workload = 'Entra ID'; ruleIds = @('ENT-INACTIVE'); nature = 'Report'; risk = 'Low'; reversible = $true; permissions = @('User.Read.All'); testedOnRealTenant = $true; testedEvidence = '2026-10-01, test tenant T1' }
    )
}

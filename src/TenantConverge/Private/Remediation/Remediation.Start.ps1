function Get-TcRemediationSnapshot {
    <#
    .SYNOPSIS
    The snapshot of a run: the one given, or the latest of the output folder.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [AllowNull()][object]$Snapshot,
        [Parameter(Mandatory)][string]$Output
    )

    if ($Snapshot -is [System.Collections.IDictionary]) { return $Snapshot }
    if ($Snapshot) { return (Read-TcSnapshot -Path (Resolve-TcPath -Path ([string]$Snapshot))) }
    $folder = @(Get-ChildItem -LiteralPath $Output -Directory -Filter '*-assessment' -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'snapshot.json') } | Sort-Object Name)
    if (-not $folder.Count) { throw "No snapshot in $Output. Run Invoke-TcAssessment first." }
    Read-TcSnapshot -Path (Join-Path $folder[-1].FullName 'snapshot.json')
}

function Assert-TcSnapshotAge {
    <#
    .SYNOPSIS
    A write rests on the snapshot: refuses one older than the limit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][int]$Limit
    )

    $meta = Get-TcProperty $Snapshot 'meta'
    $text = [string](Get-TcProperty $meta 'finished' (Get-TcProperty $meta 'started'))
    $date = [datetime]::MinValue
    if (-not [datetime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) { throw 'This snapshot has no date, so its age cannot be checked. Run Invoke-TcAssessment again.' }
    $age = ((Get-Date) - $date).TotalDays
    if ($age -gt $Limit) { throw ('This snapshot is older than the limit: {0:N0} days, limit {1}. Run Invoke-TcAssessment again.' -f $age, $Limit) }
}

function Assert-TcModuleFamily {
    <#
    .SYNOPSIS
    Stops before a script loads a module family that crashes PowerShell next to one already loaded.
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Service
    )

    $families = @{ Exo = @('ExchangeOnlineManagement'); Scc = @('ExchangeOnlineManagement'); Teams = @('MicrosoftTeams'); Pnp = @('PnP.PowerShell') }
    if (-not $families.ContainsKey($Service)) { return }
    $others = @($families.Keys | Where-Object { $families[$_][0] -ne $families[$Service][0] } | ForEach-Object { $families[$_][0] } | Select-Object -Unique)
    $loaded = @(Get-Module -Name $others -ErrorAction SilentlyContinue | ForEach-Object Name)
    if ($loaded.Count) { throw "This script uses $($families[$Service][0]), and $($loaded -join ', ') is loaded in this process. Together they stop PowerShell: run it in a new window." }
}

function Invoke-TcRemediationScript {
    <#
    .SYNOPSIS
    Runs a remediation in this function's scope.

    .DESCRIPTION
    The script is dot-sourced so it runs in the module, under its strict mode, and sees the private
    functions. Its variables and its functions end with this call. Calling it with & would create a new
    script scope, and $script: in the engine would stop reaching the module.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) { throw "Script not found: $Path." }
    . $Path
}

function Get-TcRemediationOutcome {
    <#
    .SYNOPSIS
    The result of a run, for the person or the script that started it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyString()][string]$Failure = ''
    )

    $run = $script:TcRemediationRun
    $tally = Get-TcRemediationTally
    [pscustomobject]@{
        Id = $run['Id']; Mode = $(if ($run['Apply']) { 'Apply' } else { 'Preview' }); Code = $run['Code']; Tenants = @($run['Tenants']); Folder = $run['Folder']; Actions = $tally['Total']; Applied = $tally['Applied']
        AlreadyInPlace = $tally['AlreadyInPlace']; Failed = $tally['Failed']; ForAPerson = $tally['ForAPerson']; Waiting = $tally['Waiting']; PendingDecisions = $run['Pending']; Alerts = $run['Alerts']; Error = $Failure; Notice = $script:TcUntestedNotice
    }
}

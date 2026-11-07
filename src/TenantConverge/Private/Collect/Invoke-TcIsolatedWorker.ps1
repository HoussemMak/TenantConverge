function Invoke-TcIsolatedWorker {
    <#
    .SYNOPSIS
    The body of the separate process: runs the collectors it is given and saves after each one.

    .DESCRIPTION
    Saving after each collector means a hard stop only loses the collector that was running. It shares
    the log files of the main run, which waits for this process.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][string[]]$CollectorId,
        [int[]]$Rank = @(),
        [int]$Total = 0,
        [string]$Depth = 'Complete',
        [string]$Folder = '',
        [string]$InitialDomain = '',
        [switch]$Unattended,
        [Parameter(Mandatory)][string]$OutFile
    )

    if ($Folder) {
        $script:TcLogFile = Join-Path $Folder 'journal.log'
        $script:TcEventFile = Join-Path $Folder 'events.jsonl'
    }

    $project = Read-TcProjectFile -Path $ProjectPath
    Initialize-TcSession -Project $project -Access (Read-TcAccessFile -ProjectPath $ProjectPath) -Unattended:$Unattended
    Initialize-TcCollection -Depth $Depth
    if ($InitialDomain) { $script:TcTenants[$Role]['initialDomain'] = $InitialDomain }
    Select-TcCollectionTenant -Role $Role

    $collectors = @(Get-TcCollector)
    for ($i = 0; $i -lt $CollectorId.Count; $i++) {
        $collector = $collectors | Where-Object { $_['Id'] -eq $CollectorId[$i] } | Select-Object -First 1
        if (-not $collector) { continue }
        $position = if ($i -lt $Rank.Count) { $Rank[$i] } else { $i + 1 }
        $count = if ($Total) { $Total } else { $CollectorId.Count }
        Invoke-TcCollector -Collector $collector -Role $Role -Rank $position -Total $count | Out-Null
        Write-TcIsolatedResult -Path $OutFile
    }

    Write-TcIsolatedResult -Path $OutFile
    if ($script:TcPnpConnection) {
        try { Disconnect-PnPOnline -ErrorAction SilentlyContinue }
        catch { Write-Verbose 'No PnP session to close.' }
    }
}

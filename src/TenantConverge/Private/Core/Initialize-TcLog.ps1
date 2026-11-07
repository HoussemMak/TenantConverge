function Initialize-TcLog {
    <#
    .SYNOPSIS
    Prepares a run folder: its exports folder, the text log and the JSONL events.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Path 'exports') | Out-Null
    $script:TcLogFile = Join-Path $Path 'journal.log'
    $script:TcEventFile = Join-Path $Path 'events.jsonl'
}

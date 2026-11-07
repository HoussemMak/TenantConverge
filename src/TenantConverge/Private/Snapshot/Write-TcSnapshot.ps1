function Write-TcSnapshot {
    <#
    .SYNOPSIS
    Writes a snapshot, after checking it against the format.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Snapshot
    )

    $problems = @(Test-TcSnapshot -Snapshot $Snapshot)
    if ($problems.Count -gt 0) {
        throw (($problems | ForEach-Object { "$($_.Code) $($_.Path): $($_.Message)" }) -join [Environment]::NewLine)
    }
    Write-TcJsonFile -Path $Path -InputObject $Snapshot
}

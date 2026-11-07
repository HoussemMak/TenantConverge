function Invoke-TcCollectorPart {
    <#
    .SYNOPSIS
    Runs one part of a collector. A failure is noted and the other parts still run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Label,
        [Parameter(Mandatory, Position = 1)][scriptblock]$ScriptBlock
    )

    try { & $ScriptBlock }
    catch { Add-TcCollectorWarning $Label $_ }
}

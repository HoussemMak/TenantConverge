function Add-TcCollectorLimit {
    <#
    .SYNOPSIS
    Notes that a limit cut what the running collector read. The collector ends up Partial, and the coverage says so.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Text
    )

    $collector = $script:TcCurrentCollector
    $step = ''
    if ($collector) {
        $collector['limits'].Add("Limit reached: $Text")
        $step = $collector['id']
    }
    Write-TcLog -Message "Limit reached: $Text" -Level WARN -Step $step
}

function Add-TcCollectorWarning {
    <#
    .SYNOPSIS
    Notes that part of a collector failed. The collector carries on and ends up partial.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Label,
        [Parameter(Position = 1)][AllowNull()]$ErrorInput
    )

    $text = Get-TcErrorText -ErrorInput $ErrorInput
    $class = Get-TcErrorClass -Text $text
    $collector = $script:TcCurrentCollector
    $step = ''
    if ($collector) {
        $collector['warnings'].Add("${Label}: $class")
        $collector['classes'].Add($class)
        $step = $collector['id']
    }
    Write-TcLog -Message "Part not collected: $Label - $class - $text" -Level WARN -Step $step
}

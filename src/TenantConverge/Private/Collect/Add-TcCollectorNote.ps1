function Add-TcCollectorNote {
    <#
    .SYNOPSIS
    Adds a remark to the coverage of the running collector.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Text
    )

    if ($script:TcCurrentCollector) { $script:TcCurrentCollector['notes'].Add($Text) }
}

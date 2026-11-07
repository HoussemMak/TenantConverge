function Limit-TcCollectorRow {
    <#
    .SYNOPSIS
    Keeps the first rows up to a limit. A cut is never silent: the coverage of the collector reports it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Label,
        [Parameter(Position = 1)][AllowNull()][object[]]$Row,
        [Parameter(Mandatory, Position = 2)][int]$Limit
    )

    $rows = @($Row)
    if ($rows.Count -gt $Limit) { Add-TcCollectorLimit ('{0} of {1} {2} were read.' -f $Limit, $rows.Count, $Label) }
    $rows | Select-Object -First $Limit
}

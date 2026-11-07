function Format-TcNumber {
    <#
    .SYNOPSIS
    Writes a number for a finding, with thousands separators.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()]$Value,
        [Parameter(Position = 1)][int]$Decimals = 0
    )

    ([double]$Value).ToString("N$Decimals", [Globalization.CultureInfo]::InvariantCulture)
}

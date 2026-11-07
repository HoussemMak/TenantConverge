function Get-TcDaysSince {
    <#
    .SYNOPSIS
    Returns the whole days since a date, negative for a future date, or nothing for a missing or meaningless date.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Date
    )

    if (-not $Date) { return $null }
    try {
        $value = if ($Date -is [datetime]) { $Date }
        elseif ($Date -is [datetimeoffset]) { $Date.UtcDateTime }
        else {
            [datetime]::Parse([string]$Date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
        }
        if ($value.Year -lt 1990) { return $null }
        [int][math]::Floor(((Get-Date).ToUniversalTime() - $value.ToUniversalTime()).TotalDays)
    }
    catch { $null }
}

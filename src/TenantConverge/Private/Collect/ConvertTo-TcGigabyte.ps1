function ConvertTo-TcGigabyte {
    <#
    .SYNOPSIS
    Converts bytes to gigabytes, rounded to two decimals.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Bytes
    )

    if ($null -eq $Bytes -or "$Bytes" -eq '') { return $null }
    [math]::Round(([double]$Bytes) / 1GB, 2)
}

function Get-TcByteSize {
    <#
    .SYNOPSIS
    Reads the bytes out of a size such as "1.234 GB (1,325,000,000 bytes)".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Size
    )

    if ([string]$Size -match '\(([\d,\. ]+) bytes\)') { return [double]($Matches[1] -replace '[,\. ]', '') }
    $null
}

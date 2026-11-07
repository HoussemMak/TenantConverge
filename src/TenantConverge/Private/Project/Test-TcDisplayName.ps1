function Test-TcDisplayName {
    <#
    .SYNOPSIS
    Tells whether a value can be used as a tenant display name.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]$Value
    )

    if ($Value -isnot [string]) { return $false }
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    ($Value.Length -le 64) -and ($Value -notmatch '\p{Cc}')
}

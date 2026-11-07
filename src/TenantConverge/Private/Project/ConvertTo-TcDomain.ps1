function ConvertTo-TcDomain {
    <#
    .SYNOPSIS
    Normalizes a domain name so that two spellings of one domain compare equal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $Value.Trim().TrimEnd('.').ToLowerInvariant()
}

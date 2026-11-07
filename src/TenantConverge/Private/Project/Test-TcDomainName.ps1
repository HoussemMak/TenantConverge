function Test-TcDomainName {
    <#
    .SYNOPSIS
    Tells whether a normalized value is a valid domain name.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    $Value -cmatch '^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$'
}

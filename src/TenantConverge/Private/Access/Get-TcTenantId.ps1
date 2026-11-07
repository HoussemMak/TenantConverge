function Get-TcTenantId {
    <#
    .SYNOPSIS
    Resolves a tenant ID from a domain, using the public sign-in metadata.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Domain
    )

    $metadata = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$Domain/v2.0/.well-known/openid-configuration" -TimeoutSec 20
    if ([string](Get-TcProperty $metadata 'issuer') -match '/([0-9a-f\-]{36})/') { return $Matches[1] }
    throw "No tenant was found for $Domain."
}

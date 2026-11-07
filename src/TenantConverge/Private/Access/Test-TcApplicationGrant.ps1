function Test-TcApplicationGrant {
    <#
    .SYNOPSIS
    Tells whether the read-only application of a tenant received an access: Graph, Exchange, Purview, Teams, SharePoint, PowerPlatform or Azure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]$Tenant,
        [Parameter(Mandatory)][string]$Grant
    )

    $auth = Get-TcApplicationAuth -Tenant $Tenant
    [bool]($auth -and @(Get-TcProperty $auth 'grants') -contains $Grant)
}

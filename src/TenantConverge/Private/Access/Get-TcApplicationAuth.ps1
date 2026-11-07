function Get-TcApplicationAuth {
    <#
    .SYNOPSIS
    Returns the read-only application of a tenant, or nothing when the tenant signs in through a browser.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [AllowNull()]$Tenant
    )

    if ((Get-TcProperty $Tenant 'mode') -ne 'Application') { return }
    $access = Get-TcProperty $Tenant 'access'
    if (-not (Get-TcProperty $access 'clientId') -or -not (Get-TcProperty $access 'thumbprint')) { return }
    $access
}

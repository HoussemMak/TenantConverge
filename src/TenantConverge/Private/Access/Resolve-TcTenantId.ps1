function Resolve-TcTenantId {
    <#
    .SYNOPSIS
    Resolves the tenant ID of a role from its domain, and refuses a project ID that says otherwise.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tenant
    )

    $resolved = Get-TcTenantId -Domain $Tenant['primaryDomain']
    $declared = Get-TcProperty $Tenant 'tenantId'
    if ($declared -and [string]$declared -ne $resolved) {
        throw "The tenant ID in the project ($declared) does not match $($Tenant['primaryDomain']), which resolves to $resolved."
    }
    $Tenant['tenantId'] = $resolved
    $resolved
}

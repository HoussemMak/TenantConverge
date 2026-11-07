function Resolve-TcProjectTenant {
    <#
    .SYNOPSIS
    Resolves every tenant of the project and refuses a tenant listed twice under two domains.
    #>
    [CmdletBinding()]
    param()

    $seen = @{}
    foreach ($role in @($script:TcTenants.Keys)) {
        $tenant = $script:TcTenants[$role]
        $tenantId = Resolve-TcTenantId -Tenant $tenant
        if ($seen.ContainsKey($tenantId)) {
            throw "TC1006: $($seen[$tenantId]) and $($tenant['primaryDomain']) are the same tenant. Each tenant can only appear once in a project."
        }
        $seen[$tenantId] = $tenant['primaryDomain']
    }
}

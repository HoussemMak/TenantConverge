function Select-TcCollectionTenant {
    <#
    .SYNOPSIS
    Makes a tenant the one that collectors write to, and creates its record the first time.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Role
    )

    if (-not $script:TcCollection.Contains($Role)) {
        $tenant = $script:TcTenants[$Role]
        $script:TcCollection[$Role] = [ordered]@{
            role     = $Role
            tenant   = $tenant['displayName']
            domain   = $tenant['primaryDomain']
            tenantId = ''
            coverage = [System.Collections.Generic.List[object]]::new()
            tables   = [ordered]@{}
        }
    }
    $script:TcCurrentTenant = $script:TcCollection[$Role]
}

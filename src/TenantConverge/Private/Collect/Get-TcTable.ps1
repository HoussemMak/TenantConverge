function Get-TcTable {
    <#
    .SYNOPSIS
    Returns the rows of a table of the current tenant, or of the tenant of a role.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Position = 1)][string]$Role
    )

    $tenant = if ($Role) { Get-TcProperty $script:TcCollection $Role } else { $script:TcCurrentTenant }
    if ($null -eq $tenant) { return }
    Get-TcProperty $tenant['tables'] $Name @()
}

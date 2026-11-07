function Initialize-TcSession {
    <#
    .SYNOPSIS
    Prepares the tenants of a project for this run and forgets any earlier connection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Project,
        [AllowNull()][System.Collections.IDictionary]$Access,
        [switch]$Unattended
    )

    $mode = Get-TcProperty (Get-TcProperty $Project 'access') 'mode' 'Browser'

    $tenants = [ordered]@{ Target = Get-TcProperty $Project 'target' }
    foreach ($source in @(Get-TcProperty $Project 'sources')) { $tenants[[string](Get-TcProperty $source 'role')] = $source }

    $script:TcTenants = [ordered]@{}
    foreach ($role in @($tenants.Keys)) {
        $tenant = $tenants[$role]
        $entry = Get-TcProperty $Access $role
        $script:TcTenants[$role] = [ordered]@{
            role          = $role
            displayName   = Get-TcProperty $tenant 'displayName' $role
            primaryDomain = Get-TcProperty $tenant 'primaryDomain'
            tenantId      = Get-TcProperty $tenant 'tenantId'
            initialDomain = Get-TcProperty $entry 'initialDomain'
            mode          = $mode
            access        = $entry
        }
    }

    $script:TcUnattended = [bool]$Unattended
    Clear-TcConnectionState
}

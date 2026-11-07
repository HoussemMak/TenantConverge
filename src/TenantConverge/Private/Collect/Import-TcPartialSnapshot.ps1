function Import-TcPartialSnapshot {
    <#
    .SYNOPSIS
    Loads the partial snapshot of an interrupted run, so the collection only redoes what is missing. Returns the number of tenants found.

    .DESCRIPTION
    Refuses a tenant that no longer matches the project: its rows would carry the name of another tenant.
    The domain and the tenant ID must match. A new display name is fine, it is the same tenant.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$Folder
    )

    $file = Join-Path $Folder 'snapshot.partial.json'
    if (-not (Test-Path -LiteralPath $file)) { return 0 }

    $snapshot = Read-TcSnapshot -Path $file
    $coverage = @(Get-TcProperty $snapshot 'coverage' @())
    $tenants = Get-TcProperty $snapshot 'tenants'
    $resume = @{}
    foreach ($role in @($tenants.Keys)) {
        $lines = @($coverage | Where-Object { (Get-TcProperty $_ 'role') -eq $role })
        if ($lines.Count -eq 0) { continue }

        $current = Get-TcProperty $script:TcTenants $role
        $domain = [string](Get-TcProperty $tenants[$role] 'primaryDomain')
        $tenantId = [string](Get-TcProperty $tenants[$role] 'tenantId')
        if (-not $current) { throw "The interrupted run in $Folder holds $role ($domain), which is no longer in the project. Add -Fresh to start a new run." }

        $currentDomain = [string](Get-TcProperty $current 'primaryDomain')
        $currentId = [string](Get-TcProperty $current 'tenantId')
        if ($domain -and $domain -ne $currentDomain) {
            throw "The interrupted run in $Folder read $role as $domain, and the project now says $currentDomain. Its rows would carry the wrong tenant. Add -Fresh to start a new run."
        }
        if ($tenantId -and $currentId -and $tenantId -ne $currentId) {
            throw "The interrupted run in $Folder read $role as tenant $tenantId, and the project now says $currentId. Its rows would carry the wrong tenant. Add -Fresh to start a new run."
        }

        $resume[$role] = [ordered]@{
            tenantId = Get-TcProperty $tenants[$role] 'tenantId'
            coverage = $lines
            tables   = Get-TcProperty $tenants[$role] 'tables'
        }
    }
    $script:TcResume = $resume
    $script:TcResume.Count
}

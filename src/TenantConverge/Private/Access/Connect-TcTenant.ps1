function Connect-TcTenant {
    <#
    .SYNOPSIS
    Moves the Graph context, and Exchange Online when asked, to the tenant of a role.

    .DESCRIPTION
    Uses the read-only application when the project has one, otherwise a browser sign-in. Every
    connection is checked: a session on another tenant, or a tenant that does not own the domain of the
    project, is refused.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Role,
        [switch]$Exchange
    )

    $tenant = $script:TcTenants[$Role]

    if ($script:TcActive['Graph'] -ne $Role) {
        $tenantId = Resolve-TcTenantId -Tenant $tenant
        $auth = Get-TcApplicationAuth -Tenant $tenant

        if ($auth) {
            Connect-MgGraph -ClientId $auth['clientId'] -TenantId $tenantId -CertificateThumbprint $auth['thumbprint'] -NoWelcome -ErrorAction Stop
        }
        else {
            Assert-TcInteractiveAllowed -Service 'Microsoft Graph' -Domain $tenant['primaryDomain']
            try {
                Connect-MgGraph -TenantId $tenantId -Scopes (Get-TcGraphScope -Kind Assessment) -NoWelcome -ErrorAction Stop
            }
            catch {
                Write-TcLog -Message "Consent to the assessment scopes was refused ($(Get-TcErrorText $_)). Trying again with the base read scopes." -Level WARN
                Connect-MgGraph -TenantId $tenantId -Scopes (Get-TcGraphScope -Kind Base) -NoWelcome -ErrorAction Stop
            }
        }

        $organization = @(Get-TcProperty (Invoke-TcGraphRead -Uri 'v1.0/organization') 'value') | Select-Object -First 1
        $connectedId = [string](Get-TcProperty $organization 'id')
        $domains = @(Get-TcProperty $organization 'verifiedDomains')

        if ($connectedId -ne $tenantId) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            throw "Connected to the wrong tenant: $connectedId instead of $tenantId ($Role)."
        }
        if ($tenant['primaryDomain'] -notin @($domains | ForEach-Object { Get-TcProperty $_ 'name' })) {
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            throw "$($tenant['primaryDomain']) is not a verified domain of the connected tenant ($Role)."
        }

        $initial = $domains | Where-Object { Get-TcProperty $_ 'isInitial' $false } | Select-Object -First 1
        if ($initial) { $tenant['initialDomain'] = Get-TcProperty $initial 'name' }
        $script:TcActive['Graph'] = $Role
    }

    if ($Exchange -and $script:TcActive['Exo'] -ne $Role) {
        if ($script:TcActive['Exo']) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue }
        $script:TcActive['Exo'] = $null

        $auth = Get-TcApplicationAuth -Tenant $tenant
        $organizationName = $tenant['initialDomain']
        if ($auth) {
            Connect-ExchangeOnline -AppId $auth['clientId'] -CertificateThumbprint $auth['thumbprint'] -Organization $organizationName -ShowBanner:$false -ErrorAction Stop
        }
        else {
            Assert-TcInteractiveAllowed -Service 'Exchange Online' -Domain $organizationName
            Connect-ExchangeOnline -Organization $organizationName -ShowBanner:$false -ErrorAction Stop
        }

        $accepted = @(Get-AcceptedDomain -ErrorAction Stop | Where-Object { [string](Get-TcProperty $_ 'DomainName') -eq $organizationName })
        if ($accepted.Count -eq 0) {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
            throw "Exchange Online connected to the wrong tenant: $organizationName is not an accepted domain ($Role)."
        }
        $script:TcActive['Exo'] = $Role
    }
}

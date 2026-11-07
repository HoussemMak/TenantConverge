function Connect-TcService {
    <#
    .SYNOPSIS
    Connects the service a collector needs on the tenant of a role. Each session is opened once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][string]$Role
    )

    $tenant = $script:TcTenants[$Role]
    $auth = Get-TcApplicationAuth -Tenant $tenant
    $domain = Get-TcProperty $tenant 'initialDomain'

    switch ($Service) {
        'None' { return }
        'Graph' { Connect-TcTenant -Role $Role }
        'Exo' { Connect-TcTenant -Role $Role -Exchange }
        'PowerPlatform' { Connect-TcTenant -Role $Role }
        'Ipps' {
            Connect-TcTenant -Role $Role -Exchange
            if ($script:TcServiceConnections['Ipps'] -eq $Role) { return }
            $domain = Get-TcProperty $tenant 'initialDomain'
            if ($auth) {
                Connect-IPPSSession -AppId $auth['clientId'] -CertificateThumbprint $auth['thumbprint'] -Organization $domain -ShowBanner:$false -ErrorAction Stop
            }
            else {
                Assert-TcInteractiveAllowed -Service 'Purview' -Domain $domain
                Connect-IPPSSession -ShowBanner:$false -ErrorAction Stop

                # This sign-in names no tenant, so a cached account of another one would mix its data in.
                $session = @(Get-ConnectionInformation -ErrorAction Stop) | Where-Object { [string](Get-TcProperty $_ 'ConnectionUri') -match 'compliance' } | Select-Object -Last 1
                $connected = [string](Get-TcProperty $session 'TenantID')
                if ($connected -ne [string]$tenant['tenantId']) {
                    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
                    $script:TcActive['Exo'] = $null
                    throw "Purview connected to the wrong tenant: $(if ($connected) { $connected } else { 'none could be read' }) instead of $($tenant['tenantId']) ($Role)."
                }
            }
            $script:TcServiceConnections['Ipps'] = $Role
        }
        'Teams' {
            if ($script:TcServiceConnections['Teams'] -eq $Role) { return }
            if ($script:TcServiceConnections['Teams']) { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null }
            Connect-TcTenant -Role $Role
            $tenantId = $tenant['tenantId']
            if ($auth) {
                Connect-MicrosoftTeams -TenantId $tenantId -ApplicationId $auth['clientId'] -CertificateThumbprint $auth['thumbprint'] -ErrorAction Stop | Out-Null
            }
            else {
                Assert-TcInteractiveAllowed -Service 'Microsoft Teams' -Domain $tenant['primaryDomain']
                # -AccountId goes through WAM and fails without a window, so the classic window is used.
                $parameters = @{ TenantId = $tenantId; ErrorAction = 'Stop' }
                if ((Get-Command Connect-MicrosoftTeams).Parameters.ContainsKey('DisableWAM')) { $parameters['DisableWAM'] = $true }
                Connect-MicrosoftTeams @parameters | Out-Null
            }
            $connected = [string](Get-TcProperty (Get-CsTenant -ErrorAction Stop) 'TenantId')
            if ($connected -ne [string]$tenantId) { throw "Teams connected to the wrong tenant: $connected instead of $tenantId ($Role)." }
            $script:TcServiceConnections['Teams'] = $Role
        }
        'Pnp' {
            if ($script:TcServiceConnections['Pnp'] -eq $Role) { return }
            # Graph must stay out of this process, so the main run finds the initial domain first.
            if (-not $domain) { throw "NOTCONFIGURED: the initial domain of $Role is unknown, so SharePoint cannot be reached." }
            $access = Get-TcProperty $tenant 'access'
            $adminUrl = Get-TcProperty $access 'sharePointAdminUrl'
            if (-not $adminUrl) { $adminUrl = 'https://{0}-admin.sharepoint.com' -f ($domain -split '\.')[0] }
            $clientId = Get-TcProperty $access 'pnpClientId'

            if (Test-TcApplicationGrant -Tenant $tenant -Grant 'SharePoint') {
                $script:TcPnpConnection = Connect-PnPOnline -Url $adminUrl -ClientId $auth['clientId'] -Thumbprint $auth['thumbprint'] -Tenant $domain -ReturnConnection -ErrorAction Stop
            }
            elseif ($clientId) {
                Assert-TcInteractiveAllowed -Service 'SharePoint' -Domain $domain
                $script:TcPnpConnection = Connect-PnPOnline -Url $adminUrl -ClientId $clientId -Interactive -ReturnConnection -ErrorAction Stop
            }
            else {
                throw "NOTCONFIGURED: this tenant has no PnP application for SharePoint ($Role, $domain)."
            }
            $script:TcServiceConnections['Pnp'] = $Role
        }
        'Azure' {
            if ($script:TcServiceConnections['Azure'] -eq $Role) { return }
            # The Azure sign-in itself runs in the separate process of AZR-01, because Az.Accounts and
            # Microsoft.Graph load different versions of MSAL.
            Connect-TcTenant -Role $Role
            $script:TcServiceConnections['Azure'] = $Role
        }
    }
}

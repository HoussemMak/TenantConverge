function Get-TcServiceInfo {
    <#
    .SYNOPSIS
    Describes a service: its label, its module, how to install it and the access it needs.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Service
    )

    $services = @{
        Graph         = @{
            Label = 'Microsoft Graph'; Module = 'Microsoft.Graph.Authentication'; Install = 'Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
            Access = 'Global Administrator or Global Reader role, and consent to the Graph permissions of the assessment, once per tenant.'
        }
        Exo           = @{
            Label = 'Exchange Online'; Module = 'ExchangeOnlineManagement'; Install = 'Install-Module ExchangeOnlineManagement -Scope CurrentUser'
            Access = 'Exchange Administrator, Global Reader or Global Administrator role.'
        }
        Ipps          = @{
            Label = 'Purview (Security & Compliance)'; Module = 'ExchangeOnlineManagement'; Install = 'Install-Module ExchangeOnlineManagement -Scope CurrentUser'
            Access = 'Compliance Administrator, Global Reader or Global Administrator role.'
        }
        Teams         = @{
            Label = 'Microsoft Teams'; Module = 'MicrosoftTeams'; Install = 'Install-Module MicrosoftTeams -Scope CurrentUser'
            Access = 'Teams Administrator or Teams Communications Administrator, Global Reader or Global Administrator role.'
        }
        Pnp           = @{
            Label = 'SharePoint (PnP.PowerShell)'; Module = 'PnP.PowerShell'; Install = 'Install-Module PnP.PowerShell -Scope CurrentUser (PowerShell 7.4.6 or later)'
            Access = 'SharePoint Administrator or Global Administrator role, and a PnP application registered in the tenant.'
        }
        Azure         = @{
            Label = 'Azure Resource Manager'; Module = 'Az.Resources'; Install = 'Install-Module Az.Accounts, Az.Resources -Scope CurrentUser'
            Access = "Reader role on the subscriptions. A Global Administrator must first turn on 'Access management for Azure resources' in Entra ID."
        }
        PowerPlatform = @{
            Label = 'Power Platform'; Module = 'Microsoft.PowerApps.Administration.PowerShell'
            Install = 'In Windows PowerShell 5.1: Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser'
            Access = 'Power Platform Administrator or Global Administrator role.'
        }
        None          = @{ Label = 'No connection'; Module = ''; Install = ''; Access = '' }
    }
    $services[$Service]
}

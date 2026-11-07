function Get-TcRequiredModule {
    <#
    .SYNOPSIS
    Lists the modules the assessment and the workbook use, for all services or only for the ones given.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [string[]]$Service
    )

    $modules = @(
        [ordered]@{
            Name = 'Microsoft.Graph.Authentication'; Minimum = '2.10.0'
            Services = @('Graph', 'Exo', 'Ipps', 'Teams', 'Pnp', 'Azure', 'PowerPlatform', 'None')
            Purpose = 'Microsoft Graph: identities, domains, Intune, reports'
        }
        [ordered]@{ Name = 'ExchangeOnlineManagement'; Minimum = '3.7.0'; Services = @('Exo', 'Ipps'); Purpose = 'Exchange Online and Purview' }
        [ordered]@{ Name = 'MicrosoftTeams'; Minimum = '6.0.0'; Services = @('Teams'); Purpose = 'Teams and Teams Phone' }
        [ordered]@{ Name = 'PnP.PowerShell'; Minimum = '2.12.0'; Services = @('Pnp'); Purpose = 'SharePoint and OneDrive' }
        [ordered]@{ Name = 'Az.Accounts'; Minimum = '3.0.0'; Services = @('Azure'); Purpose = 'Azure sign-in' }
        [ordered]@{ Name = 'Az.Resources'; Minimum = '7.0.0'; Services = @('Azure'); Purpose = 'Azure subscriptions, resources and RBAC' }
        [ordered]@{
            Name = 'Microsoft.PowerApps.Administration.PowerShell'; Minimum = '2.0.0'; Services = @('PowerPlatform')
            Purpose = 'Power Platform (Windows PowerShell 5.1)'; WindowsPowerShell = $true
        }
        [ordered]@{ Name = 'ImportExcel'; Minimum = '7.8.10'; Services = @('Workbook'); Purpose = 'The Excel workbook, written without Excel' }
    )

    if (-not $PSBoundParameters.ContainsKey('Service')) { return $modules }
    $modules | Where-Object { $module = $_; @($module['Services'] | Where-Object { $_ -in $Service }).Count -gt 0 }
}

function Install-TcRequiredModule {
    <#
    .SYNOPSIS
    Installs or updates a module for the current user, and stops with a clear error when it cannot.

    .DESCRIPTION
    Uses PSResourceGet when it is present, otherwise PowerShellGet. The Power Platform module installs
    into Windows PowerShell 5.1, the only environment it supports. Only -Install on Test-TcPrerequisite
    reaches this function.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Module
    )

    $name = $Module['Name']
    $minimum = $Module['Minimum']

    if (Get-TcProperty $Module 'WindowsPowerShell' $false) {
        $command = '[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; ' +
            "if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { `$_.Version -ge [version]'2.8.5.201' })) { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null }; " +
            "Install-Module -Name '$name' -MinimumVersion '$minimum' -Scope CurrentUser -Force -AllowClobber -Repository PSGallery -ErrorAction Stop"
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $command 2>&1
        if ($LASTEXITCODE) { throw ('Windows PowerShell: {0}' -f ((@($output) | Select-Object -Last 3) -join ' ')) }
        return
    }

    # PnP.PowerShell 3 needs PowerShell 7.4.6. Below that, the last version 2 stays usable.
    $oldPnP = $name -eq 'PnP.PowerShell' -and $PSVersionTable.PSVersion -lt [version]'7.4.6'

    if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
        $range = if ($oldPnP) { '[2.12.0,3.0.0)' } else { "[$minimum,)" }
        Install-PSResource -Name $name -Version $range -Scope CurrentUser -Repository PSGallery -TrustRepository -AcceptLicense -Quiet -ErrorAction Stop -WarningAction SilentlyContinue
        return
    }

    $parameters = @{ Name = $name; Scope = 'CurrentUser'; Force = $true; AllowClobber = $true; Repository = 'PSGallery'; ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
    if ($oldPnP) { $parameters['RequiredVersion'] = '2.12.0' } else { $parameters['MinimumVersion'] = $minimum }
    if ((Get-Command Install-Module).Parameters.ContainsKey('AcceptLicense')) { $parameters['AcceptLicense'] = $true }
    Install-Module @parameters
}

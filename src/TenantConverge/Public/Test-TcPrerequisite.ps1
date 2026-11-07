function Test-TcPrerequisite {
    <#
    .SYNOPSIS
    Checks PowerShell, the required modules and Windows PowerShell for Power Platform.

    .DESCRIPTION
    Reports what is present and what is missing, with the command that installs each missing module.
    It installs nothing unless you add -Install.

    .PARAMETER Service
    The services to check. The default is all of them. Workbook is ImportExcel, which New-TcWorkbook needs.

    .PARAMETER Install
    Installs or updates the missing modules for the current user.

    .EXAMPLE
    Test-TcPrerequisite

    Shows what is missing and how to install it.

    .EXAMPLE
    Test-TcPrerequisite -Install

    Installs what is missing for the current user.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Graph', 'Exo', 'Ipps', 'Teams', 'Pnp', 'Azure', 'PowerPlatform', 'Workbook')]
        [string[]]$Service = @('Graph', 'Exo', 'Ipps', 'Teams', 'Pnp', 'Azure', 'PowerPlatform', 'Workbook'),
        [switch]$Install
    )

    $powerShell = $PSVersionTable.PSVersion
    $powerShellReady = $powerShell -ge [version]'7.4'
    if ($powerShellReady) {
        $note = if ($powerShell -lt [version]'7.4.6') { ' (PnP.PowerShell 3 needs 7.4.6 or later: version 2 will be used)' } else { '' }
        Write-TcMessage -Message "PowerShell $powerShell$note" -Level Success
    }
    else {
        Write-TcMessage -Message "PowerShell $powerShell is too old. Version 7.4 or later is required: winget install Microsoft.PowerShell" -Level Warning
    }

    $needsWindowsPowerShell = 'PowerPlatform' -in $Service
    $windowsPowerShell = Test-TcWindowsPowerShell
    $missing = [System.Collections.Generic.List[string]]::new()
    if ($needsWindowsPowerShell -and -not $windowsPowerShell) {
        $missing.Add('Windows PowerShell 5.1')
        Write-TcMessage -Message 'Windows PowerShell 5.1 was not found. Power Platform cannot be read without it.' -Level Warning
    }

    $modules = foreach ($module in @(Get-TcRequiredModule -Service $Service)) {
        $name = $module['Name']
        $minimum = [version]$module['Minimum']
        $inWindowsPowerShell = [bool](Get-TcProperty $module 'WindowsPowerShell' $false)
        $skipped = $inWindowsPowerShell -and -not $windowsPowerShell

        $version = if ($skipped) { $null } else { Get-TcModuleVersion -Name $name -WindowsPowerShell:$inWindowsPowerShell }
        $status = if ($version -and $version -ge $minimum) { 'Present' } elseif ($version) { 'Outdated' } else { 'Missing' }
        $installCommand = Get-TcInstallCommand -Module $module

        if ($status -eq 'Present') {
            Write-TcMessage -Message "$name $version - $($module['Purpose'])" -Level Success
        }
        elseif (-not $Install) {
            Write-TcMessage -Message "$name $status, $minimum or later is required. $installCommand" -Level Warning
        }
        elseif (-not $skipped -and $PSCmdlet.ShouldProcess($name, "Install version $minimum or later for the current user")) {
            try {
                Install-TcRequiredModule -Module $module
                $version = Get-TcModuleVersion -Name $name -WindowsPowerShell:$inWindowsPowerShell -Refresh
                if (-not $version -or $version -lt $minimum) { throw 'The installed version could not be found after the installation.' }
                $status = if ($status -eq 'Outdated') { 'Updated' } else { 'Installed' }
                Write-TcMessage -Message "$name $version $($status.ToLowerInvariant())" -Level Success
            }
            catch {
                $status = 'Failed'
                Write-TcMessage -Message "$name could not be installed: $(Get-TcErrorText $_). Check access to www.powershellgallery.com, or run: $installCommand" -Level Warning
            }
        }

        if ($status -notin 'Present', 'Installed', 'Updated') { $missing.Add($name) }

        [pscustomobject][ordered]@{
            Name           = $name
            Version        = [string]$version
            Minimum        = [string]$minimum
            Status         = $status
            Services       = @($module['Services'])
            Purpose        = $module['Purpose']
            InstallCommand = $installCommand
        }
    }

    [pscustomobject][ordered]@{
        Ready             = $powerShellReady -and $missing.Count -eq 0
        PowerShell        = [string]$powerShell
        WindowsPowerShell = $windowsPowerShell
        Modules           = @($modules)
        Missing           = @($missing)
    }
}

function Import-TcWorkbookModule {
    <#
    .SYNOPSIS
    Loads ImportExcel, or stops with what to do when it is missing or too old.
    #>
    [CmdletBinding()]
    param()

    $module = Get-TcRequiredModule -Service 'Workbook' | Select-Object -First 1
    $minimum = [version]$module['Minimum']
    $version = Get-TcModuleVersion -Name $module['Name']

    # The session remembers what it found, and the message below sends people to install the module in this
    # same window: look again before saying it is missing.
    if (-not $version -or $version -lt $minimum) { $version = Get-TcModuleVersion -Name $module['Name'] -Refresh }
    if (-not $version -or $version -lt $minimum) {
        throw "The workbook needs $($module['Name']) $($module['Minimum']) or later. Run Test-TcPrerequisite -Service Workbook -Install, or: $(Get-TcInstallCommand -Module $module)"
    }
    Import-Module -Name $module['Name'] -MinimumVersion $module['Minimum'] -ErrorAction Stop -Verbose:$false
}

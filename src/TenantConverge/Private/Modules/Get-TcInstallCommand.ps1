function Get-TcInstallCommand {
    <#
    .SYNOPSIS
    Returns the command a person can run to install a required module.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Module
    )

    $command = "Install-Module $($Module['Name']) -Scope CurrentUser"
    if (Get-TcProperty $Module 'WindowsPowerShell' $false) { return "In Windows PowerShell 5.1: $command" }
    if ($Module['Name'] -eq 'PnP.PowerShell') { return "$command (PowerShell 7.4.6 or later for version 3)" }
    $command
}

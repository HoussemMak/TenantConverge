<#
.SYNOPSIS
Runs read-only collectors in a separate PowerShell process.

.DESCRIPTION
PnP.PowerShell and the Graph and Exchange modules stop PowerShell when they share a process. The
assessment starts this script for the PnP collectors of a tenant and reads their tables back from a JSON
file. If this process stops, only those collectors are missing. It is not meant to be run by hand.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProjectPath,
    [Parameter(Mandatory)][string]$Role,
    [Parameter(Mandatory)][string]$CollectorId,
    [string]$Rank = '',
    [int]$Total = 0,
    [string]$Depth = 'Complete',
    [string]$Folder = '',
    [string]$InitialDomain = '',
    [switch]$Unattended,
    [Parameter(Mandatory)][string]$OutFile
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Import-Module (Join-Path $PSScriptRoot '..' 'TenantConverge.psd1') -Force

$parameters = @{
    ProjectPath   = $ProjectPath
    Role          = $Role
    CollectorId   = @($CollectorId -split ',' | Where-Object { $_ })
    Rank          = @($Rank -split ',' | Where-Object { $_ } | ForEach-Object { [int]$_ })
    Total         = $Total
    Depth         = $Depth
    Folder        = $Folder
    InitialDomain = $InitialDomain
    Unattended    = [bool]$Unattended
    OutFile       = $OutFile
}

& (Get-Module TenantConverge) { param($Parameters) Invoke-TcIsolatedWorker @Parameters } $parameters
exit 0

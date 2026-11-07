function New-TcProject {
    <#
    .SYNOPSIS
    Creates and validates a TenantConverge project file without asking any question.

    .DESCRIPTION
    Use this command in scripts. For a guided setup, use Start-TenantConverge. A project has 1 target
    and 1, 2 or 3 sources. Nothing is written when the project is not valid.

    .PARAMETER Name
    The project name.

    .PARAMETER TargetDomain
    The primary domain of the target tenant.

    .PARAMETER TargetDisplayName
    The name to show for the target tenant.

    .PARAMETER TargetState
    Production for a target already in use, New for a new tenant.

    .PARAMETER Source
    One hashtable per source tenant, with DisplayName and PrimaryDomain, and optionally TenantId and Wave.

    .PARAMETER AccessMode
    Browser for a browser sign-in, Application for a read-only application with a certificate.

    .PARAMETER OutputPath
    The folder for reports. Reports contain personal data.

    .PARAMETER Team
    The names of the people who follow the project.

    .PARAMETER Path
    The project file to create.

    .PARAMETER Force
    Replaces an existing project file.

    .EXAMPLE
    New-TcProject -Name 'Summit consolidation' -TargetDomain summit.example -TargetDisplayName 'Summit Holdings' -TargetState Production -Source @{ DisplayName = 'Alpine Group'; PrimaryDomain = 'alpine.example' } -Path ./project.json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$TargetDomain,
        [Parameter(Mandatory)][string]$TargetDisplayName,
        [Parameter(Mandatory)][ValidateSet('Production', 'New')][string]$TargetState,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable[]]$Source,
        [ValidateSet('Browser', 'Application')][string]$AccessMode = 'Browser',
        [string]$OutputPath = './output',
        [AllowEmptyCollection()][string[]]$Team = @(),
        [Parameter(Mandatory)][string]$Path,
        [switch]$Force
    )

    $objectArguments = @{
        Name              = $Name
        TargetDomain      = $TargetDomain
        TargetDisplayName = $TargetDisplayName
        TargetState       = $TargetState
        Source            = $Source
        AccessMode        = $AccessMode
        OutputPath        = $OutputPath
        Team              = $Team
    }
    $project = ConvertTo-TcProjectObject @objectArguments

    Assert-TcNoProjectProblem -Problem @(Test-TcProjectDefinition -Project $project)

    if ((Test-Path -LiteralPath (Resolve-TcPath -Path $Path)) -and -not $Force) {
        throw "The file '$Path' already exists. Use -Force to replace it."
    }

    if ($PSCmdlet.ShouldProcess($Path, 'Write project file')) {
        Write-TcProjectFile -Project $project -Path $Path
    }
    $project
}

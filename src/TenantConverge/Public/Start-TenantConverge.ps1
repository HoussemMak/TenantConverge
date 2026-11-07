function Start-TenantConverge {
    <#
    .SYNOPSIS
    Starts TenantConverge: sets up a consolidation of 1, 2 or 3 source tenants into 1 target tenant and assesses them.

    .DESCRIPTION
    Without parameters, it asks for the scenario and saves the answers to a project file. With -Project,
    it reads an existing project file and asks nothing. Then it checks the prerequisites, connects and
    collects the tenants, read-only, computes the migration plan, writes consolidation-report.html and
    consolidation-workbook.xlsx in the output folder, and opens the report. It never writes to a tenant.

    A module that only one workload needs does not stop the run: the coverage of the snapshot says what
    was not collected. Without ImportExcel, there is no workbook. Use -Install to install what is missing
    first.

    .PARAMETER Project
    An existing project file to read instead of asking the setup questions.

    .PARAMETER Path
    The project file to create. The default is ./project.json.

    .PARAMETER Force
    Replaces an existing project file.

    .PARAMETER Install
    Installs or updates the missing modules for the current user before the assessment.

    .PARAMETER NoOpen
    Leaves the report closed at the end.

    .EXAMPLE
    Start-TenantConverge

    Asks the setup questions, saves ./project.json, then assesses the tenants.

    .EXAMPLE
    Start-TenantConverge -Project ./project.json

    Reads an existing project and assesses the tenants, without any question.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [string]$Project,
        [string]$Path = './project.json',
        [switch]$Force,
        [switch]$Install,
        [switch]$NoOpen
    )

    if ($Project) {
        $projectPath = $Project
        $loaded = Read-TcProjectFile -Path $Project
        Write-TcMessage -Message "Project loaded: $(Get-TcProperty $loaded 'name')" -Level Success
    }
    else {
        if ((Test-Path -LiteralPath (Resolve-TcPath -Path $Path)) -and -not $Force) {
            throw "The file '$Path' already exists. Use -Force to replace it, or -Project to read it."
        }

        $loaded = Invoke-TcWizard
        if ($null -eq $loaded) {
            Write-TcMessage -Message 'Nothing was saved.'
            return
        }

        Assert-TcNoProjectProblem -Problem @(Test-TcProjectDefinition -Project $loaded)

        if (-not $PSCmdlet.ShouldProcess($Path, 'Write project file')) { return $loaded }
        Write-TcProjectFile -Project $loaded -Path $Path
        Write-TcMessage -Message 'Project saved.' -Level Success
        $projectPath = $Path
    }

    $prerequisites = if ($Install) { Test-TcPrerequisite -Install } else { Test-TcPrerequisite }
    if ($prerequisites.PowerShell -and [version]($prerequisites.PowerShell -replace '-.*$', '') -lt [version]'7.4') {
        throw "PowerShell $($prerequisites.PowerShell) is too old. Version 7.4 or later is required."
    }
    if (@($prerequisites.Missing) -contains 'Microsoft.Graph.Authentication') {
        throw 'Microsoft Graph is required for every workload. Run Test-TcPrerequisite -Install, then start again.'
    }
    $noWorkbook = @($prerequisites.Missing) -contains 'ImportExcel'
    $notCollected = @(@($prerequisites.Missing) | Where-Object { $_ -ne 'ImportExcel' })
    if ($notCollected.Count -gt 0) {
        Write-TcMessage -Message "Missing, so not collected: $($notCollected -join ', '). Run Test-TcPrerequisite -Install to add them." -Level Warning
    }
    if ($noWorkbook) {
        Write-TcMessage -Message 'ImportExcel is missing, so there will be no workbook. Run Test-TcPrerequisite -Install to add it.' -Level Warning
    }

    $assessment = Invoke-TcAssessment -Project $projectPath
    Write-TcMessage -Message "Snapshot: $($assessment.Snapshot)"
    $plan = Get-TcProperty $assessment 'Plan'
    if ($plan) { Write-TcMessage -Message "Plan: $plan" }

    $output = Write-TcProjectOutput -Project $projectPath -Assessment $assessment -SkipWorkbook:$noWorkbook
    if ($output.Report -and -not $NoOpen) { Open-TcReport -Path $output.Report }

    if ((Get-TcProperty (Get-TcProperty $loaded 'access') 'mode') -eq 'Application') {
        Write-TcMessage -Message "The read-only application stays in each tenant. At the end of the project, remove it with Remove-TcAccess -Project '$projectPath'." -Level Warning
    }

    $loaded
}

function Invoke-TcRemediation {
    <#
    .SYNOPSIS
    Runs one remediation script: a preview by default, a write only with -Apply.

    .DESCRIPTION
    UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.

    A preview connects to nothing and writes nothing to a tenant. It reads the snapshot and the plan, and
    keeps <output>\decisions\<id>.csv up to date with what a person has to settle. A script acts only on the
    rows of that file that carry a decision. With no file, or an empty one, it changes nothing and says so.

    With -Apply, the script first asks for the word UNTESTED, which -AcknowledgeUntested replaces. It then
    shows its plan: some scripts sign a person in at this step, to read what the plan needs, and write
    nothing. Before its first write, it asks for the primary domain of each tenant it touches, which
    nothing replaces, and, when it removes objects, for the word REMOVE, which nothing replaces either.
    Any other answer stops it, with nothing changed. Every sign-in carries only the permissions of the
    script. The read-only application of the assessment is never used. Each action is tested on the
    tenant just before it runs and written to operations.jsonl, so Undo-TcRemediation can go back.

    Each run has its own folder, <output>\remediations\<date>-<id>-<mode>.

    Start-TenantConverge never runs a remediation.

    .PARAMETER Id
    The identifier, from Get-TcRemediation.

    .PARAMETER Project
    The project file, or a project as read from it.

    .PARAMETER Snapshot
    The snapshot, as a path or as read from snapshot.json. Without it, the latest of the output folder.

    .PARAMETER Plan
    The result of New-TcPlan on this snapshot. Without it, the plan is computed.

    .PARAMETER Tenant
    Limits the run to these roles: Target, S1, S2 or S3.

    .PARAMETER Apply
    Writes to the tenants, after the confirmations. Without it, nothing is written.

    .PARAMETER AcknowledgeUntested
    Replaces the word UNTESTED, for a run from a script. It replaces nothing else.

    .PARAMETER Setting
    Replaces remediation settings for this run, such as @{ ObjectPrefix = 'Contoso' }. A file
    <output>\decisions\settings.json holds the settings that stay from one run to the next.

    .PARAMETER OutputPath
    The output folder. Without it, the one of the project.

    .EXAMPLE
    Invoke-TcRemediation -Id ENT-MFA -Project ./project.json

    Shows what ENT-MFA would do, and writes the proposals to the decisions file.

    .EXAMPLE
    Invoke-TcRemediation -Id ENT-MFA -Project ./project.json -Tenant Target -Apply

    Applies what was decided in the decisions file, after the confirmations.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory)][object]$Project,
        [object]$Snapshot,
        [System.Collections.IDictionary]$Plan,
        [string[]]$Tenant,
        [switch]$Apply,
        [switch]$AcknowledgeUntested,
        [hashtable]$Setting = @{},
        [string]$OutputPath
    )

    $entry = Get-TcRemediationEntry -Id $Id
    $projectData = if ($Project -is [string]) { Read-TcProjectFile -Path (Resolve-TcPath -Path $Project) } else { $Project }
    $output = if ($OutputPath) { Resolve-TcPath -Path $OutputPath } else { Resolve-TcPath -Path ([string](Get-TcProperty (Get-TcProperty $projectData 'output') 'path')) }
    $snapshotData = Get-TcRemediationSnapshot -Snapshot $Snapshot -Output $output
    if (-not $Plan) { $Plan = New-TcPlan -Project $projectData -Snapshot $snapshotData }

    $script:TcRemediationRun = New-TcRemediationRun -Entry $entry -Project $projectData -Snapshot $snapshotData -Plan $Plan -Tenant $Tenant -Apply $Apply.IsPresent -Acknowledged $AcknowledgeUntested.IsPresent -Setting $Setting -Output $output
    if ($Apply) { Assert-TcSnapshotAge -Snapshot $snapshotData -Limit (Get-TcRemediationOption 'MaxSnapshotAgeDays') }
    Assert-TcModuleFamily -Service ([string]$entry['service'])

    $failure = ''
    try { Invoke-TcRemediationScript -Path (Join-Path $script:TcRemediationRoot $entry['path']) }
    catch {
        if (-not $script:TcRemediationRun['Refused']) {
            $failure = Get-TcErrorText -ErrorInput $_
            $script:TcRemediationRun['Blocking']++
            Write-TcLog -Message ('Stopped: {0}. {1}' -f $failure, ((($_.ScriptStackTrace -split "`n") | Select-Object -First 1) -replace '\s+', ' ')) -Level ERROR
            Write-TcMessage -Message "Stopped: $failure" -Level Warning
        }
        Close-TcRemediation
    }

    Get-TcRemediationOutcome -Failure $failure
}

function Invoke-TcAssessment {
    <#
    .SYNOPSIS
    Collects the tenants of a project, read-only, and writes a snapshot.

    .DESCRIPTION
    Reads the target and each source, workload by workload, and writes a run folder in the output folder
    of the project: snapshot.json, findings.json with what the rules found, plan.json with the migration
    plan, journal.log, events.jsonl, exports\*.csv and a draft identity matrix for each source. It changes
    nothing in any tenant.

    A missing module or a refused access does not stop the run: the coverage of the snapshot says what
    was not collected, why, and what to do about it. An empty table means the service is not used, unless
    its collector was partial. A missing table means it was not collected.

    A stopped run leaves snapshot.partial.json. The next run picks it up and only redoes what is missing,
    unless you add -Fresh. Every tenant of that file is kept, even with -Tenant. The run stops if a tenant
    of that file no longer matches the project: add -Fresh to start over.

    .PARAMETER Project
    The project file.

    .PARAMETER Tenant
    The roles to collect. The default is the target and every source.

    .PARAMETER Depth
    Complete reads everything. Standard skips the collectors that read each site, team or mailbox.

    .PARAMETER Workload
    The workloads to collect. The default is all of them.

    .PARAMETER Fresh
    Starts a new run, even if a run was interrupted.

    .PARAMETER Unattended
    Never opens a sign-in window. A service that would need one is not collected.

    .EXAMPLE
    Invoke-TcAssessment -Project ./project.json

    Collects every tenant of the project.

    .EXAMPLE
    Invoke-TcAssessment -Project ./project.json -Tenant S2 -Workload Intune -Depth Standard

    Collects Intune for the second source only.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Project,
        [ValidateSet('Target', 'S1', 'S2', 'S3')][string[]]$Tenant,
        [ValidateSet('Complete', 'Standard')][string]$Depth = 'Complete',
        [ValidateSet('Entra ID', 'Exchange Online', 'Domains and DNS', 'SharePoint and OneDrive', 'Teams', 'Teams Phone', 'Intune', 'Purview', 'Power Platform', 'Azure', 'Other services')]
        [string[]]$Workload = @('Entra ID', 'Exchange Online', 'Domains and DNS', 'SharePoint and OneDrive', 'Teams', 'Teams Phone', 'Intune', 'Purview', 'Power Platform', 'Azure', 'Other services'),
        [switch]$Fresh,
        [switch]$Unattended
    )

    $projectPath = Resolve-TcPath -Path $Project
    $projectData = Read-TcProjectFile -Path $projectPath
    Initialize-TcSession -Project $projectData -Access (Read-TcAccessFile -ProjectPath $projectPath) -Unattended:$Unattended
    $script:TcProjectPath = $projectPath

    $roles = @(if ($Tenant) { $Tenant | Where-Object { $script:TcTenants.Contains($_) } } else { $script:TcTenants.Keys })
    if ($roles.Count -eq 0) { throw 'No tenant of this project matches -Tenant.' }

    if ((Get-TcProperty (Get-TcProperty $projectData 'access') 'mode') -eq 'Application') {
        $notReady = @($roles | Where-Object { -not (Test-TcApplicationReady -Tenant $script:TcTenants[$_]) })
        if ($notReady.Count) {
            throw "These tenants have no read-only application, or its certificate is not on this computer: $($notReady -join ', '). Run Initialize-TcAccess -Project '$Project', once, with a Global Administrator."
        }
    }

    Resolve-TcProjectTenant

    $outputRoot = [string](Get-TcProperty (Get-TcProperty $projectData 'output') 'path')
    if (-not [System.IO.Path]::IsPathRooted($outputRoot)) { $outputRoot = Join-Path (Split-Path -Path $projectPath -Parent) $outputRoot }
    $outputRoot = [System.IO.Path]::GetFullPath($outputRoot)

    $service = Get-TcSyncRisk -Path $outputRoot
    if ($service) {
        if ($Unattended) { throw "The output folder $outputRoot is synced by $service and the run will hold personal data. Choose a local folder." }
        Write-TcMessage -Message "The output folder $outputRoot is synced by $service. The run will hold personal data: a local folder is safer." -Level Warning
    }

    $interrupted = if ($Fresh) { $null } else { Find-TcInterruptedRun -Path $outputRoot }
    $started = (Get-Date).ToString('s')
    if ($interrupted) {
        $folder = $interrupted
        $previous = Get-TcProperty (Get-TcProperty (Read-TcSnapshot -Path (Join-Path $folder 'snapshot.partial.json')) 'meta') 'started'
        if ($previous) { $started = [string]$previous }
    }
    else {
        $folder = Join-Path $outputRoot ('{0:yyyyMMdd-HHmmss}-assessment' -f (Get-Date))
    }

    $projectName = [string](Get-TcProperty $projectData 'name')
    Initialize-TcLog -Path $folder
    Initialize-TcCollection -Depth $Depth -ProjectName $projectName -Started $started
    if ($interrupted) {
        $count = Import-TcPartialSnapshot -Folder $folder
        Write-TcMessage -Message "Resuming the run in $folder ($count tenants already started)."
        Write-TcLog -Message "Resuming an interrupted run: $count tenants."
    }

    Write-TcLog -Message "Assessment of $projectName, depth $Depth, tenants $($roles -join ', ')."

    try {
        $notCollected = Invoke-TcCollection -Folder $folder -Role $roles -Workload $Workload
    }
    catch {
        Save-TcPartialSnapshot -Folder $folder
        throw
    }

    $snapshot = Get-TcCollectionSnapshot -ProjectName $projectName -Started $started -Finished (Get-Date).ToString('s')
    $snapshotPath = Join-Path $folder 'snapshot.json'
    Write-TcSnapshot -Path $snapshotPath -Snapshot $snapshot
    Remove-Item -LiteralPath (Join-Path $folder 'snapshot.partial.json') -ErrorAction SilentlyContinue
    Export-TcTableCsv -Folder $folder
    Export-TcIdentityMatrix -Snapshot $snapshot -Folder $folder
    $ruleSet = Invoke-TcRuleSet -Snapshot $snapshot
    Write-TcJsonFile -Path (Join-Path $folder 'findings.json') -InputObject $ruleSet

    # The snapshot and the findings are saved by now: a plan that fails must not cost them.
    $planPath = Join-Path $folder 'plan.json'
    try {
        Write-TcJsonFile -Path $planPath -InputObject (New-TcPlan -Project $projectData -Snapshot $snapshot -RuleSet $ruleSet)
    }
    catch {
        $planPath = $null
        Write-TcMessage -Message "The plan could not be computed: $(Get-TcErrorText $_). The snapshot and the findings are saved. Fix the cause, then run New-TcPlan on the snapshot." -Level Warning
        Write-TcLog -Message "The plan could not be computed: $(Get-TcErrorText $_)" -Level 'WARN'
    }

    $partial = @(@($snapshot['coverage']) | Where-Object { (Get-TcProperty $_ 'status') -eq 'Partial' }).Count
    $stopped = @(Get-TcProperty $ruleSet 'errors' @()).Count
    $gaps = @(
        if ($notCollected) { "$notCollected collectors did not collect: see the coverage in the snapshot." }
        if ($partial) { "$partial collectors read only part of their data: see the coverage in the snapshot." }
        if ($stopped) { "$stopped rule block(s) stopped, so what they check is unknown: see errors in findings.json." }
    )
    $note = if ($gaps.Count) { $gaps -join ' ' } else { 'Everything was collected.' }
    Write-TcMessage -Message "Assessment finished in $folder. $note" -Level $(if ($gaps.Count) { 'Warning' } else { 'Success' })
    Write-TcLog -Message "Assessment finished. $note"

    [pscustomobject][ordered]@{ Folder = $folder; Snapshot = $snapshotPath; Plan = $planPath; NotCollected = [int]$notCollected; Partial = $partial; RulesStopped = $stopped }
}

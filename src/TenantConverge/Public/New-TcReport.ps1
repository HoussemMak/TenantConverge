function New-TcReport {
    <#
    .SYNOPSIS
    Writes consolidation-report.html, a single file that holds the assessment, the plan and the solutions.

    .DESCRIPTION
    Works from the project and the snapshot alone, with no connection. The page needs nothing else: fonts,
    data and code are inside, its policy blocks every outbound connection, and it runs only its own script.
    Open it in a browser. Edge or Chrome can also write to the tracking file.

    The report shows what was not read as a gap, never as zero: Not collected and Not fully read stay apart
    from a service that is not used, a total that leaves out a tenant reads "at least", and a task the plan
    could not confirm stays with its reason. It shows Score and the score of what was read side by side.

    team-tracking.csv lives next to the report. It holds what the team records: statuses, assignees, notes,
    ticks and answers. It is created when it does not exist, and this command never writes to it after that,
    so generating again loses nothing. A row whose item left the plan stays in the file and shows in the
    report, and so does a row the report cannot read, which counts for nothing. Its columns are Type, Id,
    Label, Field, Value, Author, Date and Replaces, with commas, as UTF-8 with a byte order mark.

    The report holds personal data and the configuration of the tenants. Keep it out of synced folders.

    .PARAMETER Project
    The project file, or a project as read from it.

    .PARAMETER Snapshot
    The snapshot file, or a snapshot as read from it. Given as a file, the collection log beside it joins
    the report.

    .PARAMETER Plan
    The result of New-TcPlan on this snapshot. Without it, the plan is computed.

    .PARAMETER RuleSet
    The result of Invoke-TcRuleSet on this snapshot. Without it, the rules run first.

    .PARAMETER OutputPath
    A folder, or a file ending in .html. The default is the output folder of the project.

    .PARAMETER TrackingPath
    The tracking file. The default is team-tracking.csv next to the report.

    .PARAMETER IgnoreNameSuffix
    Words to remove from the end of a display name when looking for duplicates, as for New-TcPlan.

    .EXAMPLE
    New-TcReport -Project ./project.json -Snapshot ./output/20260115-090000-assessment/snapshot.json

    Writes the report in the output folder of the project, and returns its path.

    .EXAMPLE
    $plan = New-TcPlan -Project $project -Snapshot $snapshot
    New-TcReport -Project $project -Snapshot $snapshot -Plan $plan -OutputPath ./reports

    Writes the report from a plan that is already computed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][object]$Snapshot,
        [System.Collections.IDictionary]$Plan,
        [System.Collections.IDictionary]$RuleSet,
        [string]$OutputPath,
        [string]$TrackingPath,
        [AllowEmptyCollection()][string[]]$IgnoreNameSuffix = @()
    )

    $projectFolder = $null
    if ($Project -is [string]) {
        $projectPath = Resolve-TcPath -Path $Project
        $projectFolder = Split-Path -Path $projectPath -Parent
        $projectData = Read-TcProjectFile -Path $projectPath
    }
    else { $projectData = $Project }

    $log = @()
    if ($Snapshot -is [string]) {
        $snapshotPath = Resolve-TcPath -Path $Snapshot
        $snapshotData = Read-TcSnapshot -Path $snapshotPath
        $logPath = Join-Path (Split-Path -Path $snapshotPath -Parent) 'journal.log'
        if (Test-Path -LiteralPath $logPath) { $log = @([System.IO.File]::ReadAllLines($logPath) | Where-Object { $_.Trim() }) }
    }
    elseif ($Snapshot -is [System.Collections.IDictionary]) { $snapshotData = $Snapshot }
    else { throw 'Give -Snapshot as a path to snapshot.json, or as a snapshot read from it.' }

    $faults = @(Test-TcReportReference -Catalog (Get-TcProductCatalog))
    if ($faults.Count) { throw "The product catalog points to what does not exist:$([Environment]::NewLine)$($faults -join [Environment]::NewLine)" }

    $roles = @(@(Get-TcProperty $projectData 'sources' @()) | ForEach-Object { Get-TcProperty $_ 'role' })
    $strangers = @(@((Get-TcProperty $snapshotData 'tenants' @{}).Keys) | Where-Object { $_ -ne 'Target' -and $_ -notin $roles })
    if ($strangers.Count) { throw "This snapshot has tenants that are not in the project: $($strangers -join ', '). Check that the snapshot belongs to this project." }

    if (-not $RuleSet) { $RuleSet = Invoke-TcRuleSet -Snapshot $snapshotData }
    if (-not $Plan) { $Plan = New-TcPlan -Project $projectData -Snapshot $snapshotData -RuleSet $RuleSet -IgnoreNameSuffix $IgnoreNameSuffix }

    if ($OutputPath) { $target = Resolve-TcPath -Path $OutputPath }
    else {
        $folder = [string](Get-TcProperty (Get-TcProperty $projectData 'output') 'path')
        if (-not [System.IO.Path]::IsPathRooted($folder)) { $folder = Join-Path $(if ($projectFolder) { $projectFolder } else { Resolve-TcPath -Path '.' }) $folder }
        $target = $folder
    }
    $reportPath = [System.IO.Path]::GetFullPath($(if ($target -match '\.html?$') { $target } else { Join-Path $target 'consolidation-report.html' }))
    $reportFolder = Split-Path -Path $reportPath -Parent
    $trackingFile = if ($TrackingPath) { [System.IO.Path]::GetFullPath((Resolve-TcPath -Path $TrackingPath)) } else { Join-Path $reportFolder 'team-tracking.csv' }

    if (-not $PSCmdlet.ShouldProcess($reportPath, 'Write the consolidation report')) { return }

    New-Item -ItemType Directory -Path $reportFolder -Force | Out-Null
    $tracking = Read-TcTrackingFile -Path $trackingFile -Create

    $readiness = @(Get-TcReadiness -Snapshot $snapshotData -RuleSet $RuleSet)
    $report = Get-TcReportData -Project $projectData -Snapshot $snapshotData -Plan $Plan -RuleSet $RuleSet -Readiness $readiness -Log $log -TrackingText $tracking.Text -TrackingName (Split-Path -Path $trackingFile -Leaf) -IgnoreNameSuffix $IgnoreNameSuffix
    $data = $report['Data']

    # The merge of the plan decides what is an orphan. The page shows the same rows, live, from the file.
    $items = @(
        foreach ($item in @($data['actions']) + @($data['tasks']) + @($data['decisions'])) { [ordered]@{ id = $item['id'] } }
        foreach ($line in @($data['configurations'])) { [ordered]@{ id = '{0}|{1}' -f $line['role'], $line['setting'] } }
    )
    $orphans = @(Merge-TcTrackingRow -Item $items -Tracking @($tracking.Rows) | Where-Object { $_['orphan'] } | ForEach-Object { $_['id'] })

    $html = ConvertTo-TcReportHtml -Data $data -Tables $report['Tables']
    $temporary = "$reportPath.tmp"
    [System.IO.File]::WriteAllText($temporary, $html, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $reportPath -Force

    if ($tracking.Locked) { Write-Warning "$trackingFile is open in another program, so the report holds no team record this time. Close it, then generate again." }
    elseif (-not $tracking.Readable) { Write-Warning "$trackingFile has lost its columns. It was left as it is: the first line must be Type,Id,Label,Field,Value,Author,Date,Replaces." }
    $service = Get-TcSyncRisk -Path $reportFolder
    if ($service) { Write-Warning "The folder $reportFolder is synced by $service. The report holds personal data: a local folder is safer." }
    Write-Warning 'This report holds personal data and the configuration of the tenants. Share it only with people who need it.'

    [pscustomobject]@{
        Path         = $reportPath
        TrackingPath = $trackingFile
        TrackingRows = @($tracking.Rows).Count
        OrphanRows   = $orphans
        Actions      = @($data['actions']).Count
        Tasks        = @($data['tasks']).Count
        Findings     = @($data['findings']).Count
        Products     = @($data['solutions']['products']).Count
        SizeMB       = [math]::Round((Get-Item -LiteralPath $reportPath).Length / 1MB, 1)
    }
}

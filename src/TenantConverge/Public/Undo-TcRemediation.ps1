function Undo-TcRemediation {
    <#
    .SYNOPSIS
    Goes back on what a remediation run changed, from its journal, when that is possible.

    .DESCRIPTION
    UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.

    Reads the operations.jsonl of one run folder and replays the undos, the most recent first. A folder
    that holds several runs is refused, and they are listed. An operation with no way back is listed with
    its reason, and stays to be handled by hand. So does an operation cut short, whose status nobody knows.
    Without -Apply it only shows what it would do, with no connection.

    With -Apply it asks what Invoke-TcRemediation asks: the word UNTESTED, which -AcknowledgeUntested
    replaces, the primary domain of each tenant an undo writes to, which nothing replaces, and the word
    REMOVE when an undo deletes an object, as undoing a creation does, which nothing replaces either.

    What was undone is marked in the journal of the run, so a second undo finds nothing to do. The undo
    keeps a journal and a summary of its own, in its own folder, shown as Run in the result.

    .PARAMETER Path
    The folder of one run, as shown at the end of Invoke-TcRemediation.

    .PARAMETER Project
    The project file, or a project as read from it.

    .PARAMETER Apply
    Writes to the tenants, after the confirmations. Without it, nothing is written.

    .PARAMETER AcknowledgeUntested
    Replaces the word UNTESTED, for a run from a script. It replaces nothing else.

    .EXAMPLE
    Undo-TcRemediation -Path ./output/remediations/20270115-091500-ENT-MFA-Apply -Project ./project.json

    Shows what would be undone.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Path,
        [Parameter(Mandatory)][object]$Project,
        [switch]$Apply,
        [switch]$AcknowledgeUntested
    )

    $folder = (Resolve-TcPath -Path $Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $projectData = if ($Project -is [string]) { Read-TcProjectFile -Path (Resolve-TcPath -Path $Project) } else { $Project }
    $journal = Join-Path $folder 'operations.jsonl'
    $nested = @(Get-ChildItem -LiteralPath $folder -Recurse -File -Filter 'operations.jsonl' -ErrorAction Stop | Where-Object { $_.FullName -ne $journal })
    if ($nested.Count) { throw ('{0} is not one run folder: it holds {1} run(s). Give one of them: {2}' -f $folder, $nested.Count, (@($nested | ForEach-Object { $_.Directory.Name } | Sort-Object) -join ', ')) }

    $recorded = @(if (Test-Path -LiteralPath $journal) { Read-TcOperation -Path $journal })

    # Cut short between two lines of the journal: the write may have gone through.
    $unknown = @($recorded | Where-Object { $_['status'] -in 'Running', 'Undoing' })

    # A block that failed may have done part of its work: what it recorded in its undo is replayed too.
    $operations = @($recorded | Where-Object { $_['status'] -eq 'Applied' -or ($_['status'] -eq 'Failed' -and $_['type'] -eq 'Block' -and $_['undo']) })
    $operations = @($operations | Sort-Object @{ Expression = { [datetimeoffset](Get-TcProperty $_ 'timestamp' '0001-01-01T00:00:00Z') }; Descending = $true }, @{ Expression = { $_['id'] }; Descending = $true })
    $undoable = @($operations | Where-Object { $_['undo'] })
    $noWayBack = @($operations | Where-Object { -not $_['undo'] })

    $summaryFile = Join-Path $folder 'summary.json'
    $id = if (Test-Path -LiteralPath $summaryFile) { (Read-TcJsonFile -Path $summaryFile)['id'] } else { '' }
    $entry = if ($id -and (Get-TcRemediationCatalog).Contains($id)) { Get-TcRemediationEntry -Id $id } else { [ordered]@{ id = 'UNDO'; title = 'Undo'; permissions = @(); removesObjects = $false; service = 'Graph'; nature = 'Partial' } }

    $output = Resolve-TcPath -Path ([string](Get-TcProperty (Get-TcProperty $projectData 'output') 'path'))
    $run = New-TcRemediationRun -Entry ([ordered]@{ id = "UNDO-$($entry['id'])"; title = "Undo of $($entry['title'])"; permissions = @($entry['permissions']); removesObjects = $false; nature = 'Partial'; scope = 'Target'; ruleIds = @() }) -Project $projectData -Snapshot ([ordered]@{ tenants = [ordered]@{} }) -Plan ([ordered]@{ actions = @() }) -Apply $Apply.IsPresent -Acknowledged $AcknowledgeUntested.IsPresent -Output $output
    $script:TcRemediationRun = $run
    $context = Open-TcRemediation
    Write-TcMessage -Message ('{0} operation(s) to undo, {1} with no way back. Source: {2}' -f $undoable.Count, ($noWayBack.Count + $unknown.Count), $folder)
    foreach ($operation in $unknown) { Write-TcRemediationLine -Status Warning -Text ('{0}: {1}: status unknown, check the tenant' -f ((@(Get-TcActionTenant -Action $operation) | Select-Object -Unique) -join ', '), $operation['description']) -Step $operation['id'] }
    foreach ($operation in $noWayBack) { Write-TcRemediationLine -Status Info -Text ('{0}: {1}: {2}' -f ((@(Get-TcProperty $operation 'written' @()) + @($operation['tenant']) | Select-Object -Unique) -join ', '), $operation['description'], $(if ($operation['reason']) { $operation['reason'] } else { 'no undo recorded' })) -Step $operation['id'] }
    foreach ($operation in $undoable) { Write-TcRemediationLine -Status Planned -Text ('{0}: undo {1}' -f ((Get-TcUndoTenant -Operation $operation) -join ', '), $operation['description']) -Step $operation['id'] }

    $failed = 0
    $done = 0
    if ($context.Apply -and $undoable.Count) {
        $tenants = @($undoable | ForEach-Object { Get-TcUndoTenant -Operation $_ } | Select-Object -Unique)
        $removal = @($undoable | Where-Object { Test-TcRemovingUndo -Operation $_ }).Count -gt 0
        if (Confirm-TcRemediationApply -Tenant $tenants -Removal $removal) {
            foreach ($operation in $undoable) {
                $shown = (Get-TcUndoTenant -Operation $operation) -join ', '
                $status = $operation['status']
                $operation['status'] = 'Undoing'
                $operation['undoRun'] = $run['Folder']
                Write-TcOperation -Action $operation -Path $journal
                try {
                    Invoke-TcUndoOperation -Undo $operation['undo'] -Tenant (Get-TcWrittenTenant -Operation $operation) -Service $operation['service']
                    $done++
                    $operation['status'] = 'Undone'
                    Write-TcOperation -Action $operation -Path $journal
                    Write-TcOperation -Action $operation
                    Write-TcRemediationLine -Status Applied -Text ('{0}: undone: {1}' -f $shown, $operation['description']) -Step $operation['id']
                }
                catch {
                    $text = Get-TcErrorText -ErrorInput $_
                    $failed++
                    $operation['undoError'] = $text
                    # The change is still in place: the journal of the run keeps it to undo, and this one says it failed.
                    $operation['status'] = $status
                    Write-TcOperation -Action $operation -Path $journal
                    $operation['status'] = 'Undo failed'
                    Write-TcOperation -Action $operation
                    Write-TcRemediationLine -Status Failed -Text ('{0}: {1}: {2}' -f $shown, $operation['description'], $text) -Step $operation['id']
                }
            }
        }
        else {
            $run['Stopped'] = $true
            Write-TcRemediationLine -Status Warning -Text 'Not confirmed. Stopped: nothing was changed.' -Step $run['Id']
        }
    }
    Disconnect-TcRemediationService

    $code = if ($failed) { 2 } elseif ($run['Stopped']) { 3 } else { 0 }
    Write-TcJsonFile -Path (Join-Path $run['Folder'] 'summary.json') -InputObject ([ordered]@{
            id = $run['Id']; title = $run['Entry']['title']; mode = $(if ($Apply) { 'Apply' } else { 'Preview' }); source = $folder; undoable = $undoable.Count; noWayBack = $noWayBack.Count + $unknown.Count
            undone = $done; failed = $failed; code = $code; folder = $run['Folder']; testedOnRealTenant = $false
        })

    [pscustomobject]@{ Folder = $folder; Run = $run['Folder']; Undoable = $undoable.Count; NoWayBack = $noWayBack.Count + $unknown.Count; Undone = $done; Failed = $failed; Code = $code; Notice = $script:TcUntestedNotice }
}

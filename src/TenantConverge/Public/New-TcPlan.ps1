function New-TcPlan {
    <#
    .SYNOPSIS
    Computes the migration plan of a project from a snapshot: actions, target configurations, tasks and decisions.

    .DESCRIPTION
    Works from the project and the snapshot alone, with no connection. The same input always gives the
    same plan: the dates come from the snapshot.

    The result has these keys:

    schemaVersion, meta: the version, the project, the snapshot dates, the moments in order, and the
    number of blocking actions and unconfirmed tasks.

    tenants, waves: the tenants by role, with their wave, and the sources of each wave.

    actions: one per finding, plus the identity matrix and the go/no-go of each source. An action has an
    id such as S1-ENT-MFA, and role is Target, S1 to S3, or All. A source whose accounts could not be read
    keeps a blocking matrix action that says why, and its go/no-go says what could not be read.

    targetConfigurations: the settings to put in place, with their current and target values.

    tasks: the task templates of Data\tasks.json, expanded by scope. The id such as ID-02.S1 stays the
    same from one run to the next, so tracking survives a rerun. A wave task takes the roles of its
    members, as in CUT-01.S1 or CUT-01.S1-S2, so it keeps its meaning when sources swap waves, and a wave
    whose members change gets a new id, with the old tracking row left as an orphan. confirmation is
    Confirmed, or Unconfirmed when the plan could not read what the task depends on: reason then says what
    is missing. A service the tenant does not have, or leaves empty, drops its task. A service that was
    not collected never does.

    decisions: the questions to settle, with the action or task they come from.

    procedures: the procedures that the actions and tasks point to, by identifier.

    remediations: the remediation scripts this plan links, with their nature, their risk and whether a
    real tenant ever ran them. An action or a task they serve lists their identifiers in remediations.

    byTenant, byWave: the identifiers of the actions, tasks and decisions of each tenant and each wave.

    .PARAMETER Project
    The project file, or a project as read from it.

    .PARAMETER Snapshot
    The snapshot, as read from snapshot.json. A source of the project that the snapshot has not reached
    yet stays in the plan, with its tasks unconfirmed.

    .PARAMETER RuleSet
    The result of Invoke-TcRuleSet on this snapshot. Without it, the rules run first.

    .PARAMETER IgnoreNameSuffix
    Words to remove from the end of a display name when looking for duplicates, for a tenant that marks
    its accounts that way.

    .EXAMPLE
    $snapshot = Get-Content ./snapshot.json -Raw | ConvertFrom-Json -AsHashtable
    $plan = New-TcPlan -Project ./project.json -Snapshot $snapshot
    $plan.tasks | Where-Object { $_.confirmation -eq 'Unconfirmed' } | ForEach-Object { "$($_.id): $($_.reason)" }

    Computes the plan and shows the tasks that wait for missing data.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a value and changes nothing: no file, no tenant.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [System.Collections.IDictionary]$RuleSet,
        [AllowEmptyCollection()][string[]]$IgnoreNameSuffix = @()
    )

    $projectData = if ($Project -is [string]) { Read-TcProjectFile -Path (Resolve-TcPath -Path $Project) } else { $Project }
    $tenants = Get-TcProperty $Snapshot 'tenants'
    if ($null -eq $tenants) { throw 'This snapshot has no tenants.' }

    $target = Get-TcProperty $projectData 'target'
    $sources = @(@(Get-TcProperty $projectData 'sources' @()) | Sort-Object { Get-TcProperty $_ 'role' })
    $roles = @($sources | ForEach-Object { Get-TcProperty $_ 'role' })

    $strangers = @($tenants.Keys | Where-Object { $_ -ne 'Target' -and $_ -notin $roles })
    if ($strangers.Count) { throw "This snapshot has tenants that are not in the project: $($strangers -join ', '). Check that the snapshot belongs to this project." }

    if (-not $RuleSet) { $RuleSet = Invoke-TcRuleSet -Snapshot $Snapshot }

    $names = @{ All = 'All tenants'; Target = [string](Get-TcProperty $target 'displayName') }
    $waveOf = @{}
    foreach ($source in $sources) {
        $role = Get-TcProperty $source 'role'
        $names[$role] = [string](Get-TcProperty $source 'displayName')
        $waveOf[$role] = [int](Get-TcProperty $source 'wave')
    }

    $joinNames = {
        param([string[]]$Name)
        if ($Name.Count -lt 2) { return $Name -join '' }
        '{0} and {1}' -f ($Name[0..($Name.Count - 2)] -join ', '), $Name[-1]
    }

    $waveNumbers = @($waveOf.Values | Sort-Object -Unique)
    $waves = @(foreach ($number in $waveNumbers) {
            $members = @($roles | Where-Object { $waveOf[$_] -eq $number })
            $together = & $joinNames @($members | ForEach-Object { $names[$_] })
            [ordered]@{ wave = $number; sources = $members; label = $(if ($waveNumbers.Count -gt 1) { "wave $number ($together)" } else { $together }) }
        })

    $fired = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($finding in @(Get-TcProperty $RuleSet 'findings' @())) { [void]$fired.Add("$($finding['id'])|$($finding['code'])") }

    $context = @{
        Snapshot = $Snapshot; RuleSet = $RuleSet; Names = $names; WaveOf = $waveOf; Waves = $waves; Sources = $roles
        TargetState = [string](Get-TcProperty $target 'state'); Fired = $fired; Unread = @(Get-TcProperty $RuleSet 'unread' @()); RuleErrors = @(Get-TcProperty $RuleSet 'errors' @())
        Moments = @('Now', 'Preparation', 'Before cutover', 'Cutover', 'After cutover', 'Closure')
    }

    $actions = @(Get-TcPlanAction -Context $context -IgnoreNameSuffix $IgnoreNameSuffix)
    $tasks = @(Get-TcPlanTask -Context $context)
    $configurations = @(Get-TcPlanConfiguration -Context $context -Action $actions)
    $decisions = @(Get-TcPlanDecision -Action $actions -Task $tasks)

    $catalog = Get-TcProcedureCatalog
    $procedures = [ordered]@{}
    foreach ($id in @(@($actions | ForEach-Object { $_['procedure'] }) + @($tasks | ForEach-Object { $_['procedure'] }) | Where-Object { $_ } | Sort-Object -Unique -Culture 'en-US')) { $procedures[$id] = $catalog[$id] }

    $tenantRows = @([ordered]@{ role = 'Target'; kind = 'Target'; displayName = $names['Target']; primaryDomain = [string](Get-TcProperty $target 'primaryDomain'); wave = $null })
    foreach ($source in $sources) {
        $role = Get-TcProperty $source 'role'
        $tenantRows += [ordered]@{ role = $role; kind = 'Source'; displayName = $names[$role]; primaryDomain = [string](Get-TcProperty $source 'primaryDomain'); wave = $waveOf[$role] }
    }

    $remediations = @(Add-TcPlanRemediation -Action $actions -Task $tasks)

    $idsOf = { param([object[]]$Row, [scriptblock]$Filter) @($Row | Where-Object $Filter | ForEach-Object { $_['id'] }) }

    $byTenant = [ordered]@{}
    foreach ($role in @('Target') + $roles + 'All') {
        $mine = [scriptblock]::Create("`$_['role'] -eq '$role'")
        $byTenant[$role] = [ordered]@{
            actions = & $idsOf $actions $mine; tasks = & $idsOf $tasks $mine; decisions = & $idsOf $decisions $mine
            targetConfigurations = @($configurations | Where-Object $mine).Count
        }
    }

    $byWave = [ordered]@{}
    foreach ($wave in $waves) {
        $members = @($wave['sources'])
        $number = $wave['wave']
        $inWave = { $_['role'] -in $members -or $_['wave'] -eq $number }.GetNewClosure()
        $byWave["$number"] = [ordered]@{ sources = $members; actions = & $idsOf $actions $inWave; tasks = & $idsOf $tasks $inWave; decisions = & $idsOf $decisions $inWave }
    }

    $meta = Get-TcProperty $Snapshot 'meta'
    [ordered]@{
        schemaVersion        = 1
        meta                 = [ordered]@{
            project = [string](Get-TcProperty $projectData 'name'); targetState = $context['TargetState']; sourceCount = $roles.Count; moduleVersion = [string](Get-TcProperty $meta 'moduleVersion')
            snapshotStarted = [string](Get-TcProperty $meta 'started'); snapshotFinished = [string](Get-TcProperty $meta 'finished'); moments = $context['Moments']
            blockingActions = @($actions | Where-Object { $_['blocking'] }).Count; unconfirmedTasks = @($tasks | Where-Object { $_['confirmation'] -eq 'Unconfirmed' }).Count
        }
        tenants              = $tenantRows
        waves                = $waves
        actions              = $actions
        targetConfigurations = $configurations
        tasks                = $tasks
        decisions            = $decisions
        procedures           = $procedures
        remediations         = $remediations
        byTenant             = $byTenant
        byWave               = $byWave
    }
}

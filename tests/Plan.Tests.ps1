BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')

    function New-TcPlanProject {
        <# A valid project object with the given waves, one per source. #>
        param([int[]]$Wave = @(1), [string]$State = 'Production')
        $names = @(@('S1', 'Alpine Group', 'alpine.example'), @('S2', 'Birch Partners', 'birch.example'), @('S3', 'Cedar Services', 'cedar.example'))
        [pscustomobject]@{
            schemaVersion = 1
            name          = 'Summit consolidation'
            target        = [pscustomobject]@{ displayName = 'Summit Holdings'; primaryDomain = 'summit.example'; tenantId = $null; state = $State }
            sources       = @(for ($i = 0; $i -lt $Wave.Count; $i++) {
                    [pscustomobject]@{ role = $names[$i][0]; displayName = $names[$i][1]; primaryDomain = $names[$i][2]; tenantId = $null; wave = $Wave[$i] }
                })
            access        = [pscustomobject]@{ mode = 'Browser' }
            output        = [pscustomobject]@{ path = './output' }
            team          = @()
        }
    }

    function Remove-TcCollectorTable {
        <# Makes a snapshot look as if one collector had failed in one tenant. #>
        param($Snapshot, [string]$Role, [string]$Table, [string]$Status = 'Insufficient access')
        $producers = @((InModuleScope TenantConverge { Get-TcTableDictionary })[$Table]['collectors'])
        foreach ($line in @($Snapshot['coverage'])) {
            if ($line['role'] -eq $Role -and $line['id'] -in $producers) { $line['status'] = $Status; $line['message'] = 'Access denied.' }
        }
        $Snapshot['tenants'][$Role]['tables'].Remove($Table)
    }

    function New-TcCopy { param($Value) $Value | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable }

    $script:Fake = @{}
    foreach ($count in 1, 2, 3) { $script:Fake[$count] = Get-TcFakeSnapshot -SourceCount $count -Folder $TestDrive }
    $script:Sets = @{}
    foreach ($count in 1, 2, 3) { $script:Sets[$count] = Invoke-TcRuleSet -Snapshot $script:Fake[$count] }
    $script:Waves = @{ 1 = @(1); 2 = @(1, 2); 3 = @(1, 2, 3) }
    $script:Plans = @{}
    foreach ($count in 1, 2, 3) {
        $script:Plans[$count] = New-TcPlan -Project (New-TcPlanProject -Wave $script:Waves[$count]) -Snapshot $script:Fake[$count] -RuleSet $script:Sets[$count]
    }
}

Describe 'The plan contract' {
    It 'returns what the report, the workbook and the remediations read' {
        foreach ($key in 'schemaVersion', 'meta', 'tenants', 'waves', 'actions', 'targetConfigurations', 'tasks', 'decisions', 'procedures', 'remediations', 'byTenant', 'byWave') {
            $script:Plans[2].Contains($key) | Should -BeTrue -Because $key
        }
    }

    It 'lists the remediations it links, with the fields of the contract and no others' {
        $entries = @($script:Plans[3]['remediations'])
        $entries.Count | Should -BeGreaterThan 50
        foreach ($entry in $entries) {
            @($entry.Keys) | Should -Be @('id', 'title', 'workload', 'ruleIds', 'nature', 'risk', 'reversible', 'permissions', 'testedOnRealTenant', 'testedEvidence')
            $entry['ruleIds'] -is [array] | Should -BeTrue
            $entry['permissions'] -is [array] | Should -BeTrue
            $entry['testedOnRealTenant'] | Should -BeFalse
            $entry['testedEvidence'] | Should -BeNullOrEmpty
        }
    }

    It 'links an action to the remediations of its rule or its procedure' {
        $plan = $script:Plans[3]
        $byId = @{}
        foreach ($entry in $plan['remediations']) { $byId[$entry['id']] = $entry }
        $linked = @($plan['actions'] | Where-Object { $_.Contains('remediations') })
        $linked.Count | Should -BeGreaterThan 20
        foreach ($action in $linked) {
            @($action['remediations']).Count | Should -BeGreaterThan 0
            foreach ($id in $action['remediations']) {
                $byId.ContainsKey($id) | Should -BeTrue -Because $id
                @($byId[$id]['ruleIds'] | Where-Object { $_ -in $action['ruleId'], $action['procedure'] }).Count | Should -BeGreaterThan 0 -Because $id
            }
        }
    }

    It 'leaves the key out of an action with no remediation' {
        $plan = $script:Plans[3]
        $ruleIds = @($plan['remediations'] | ForEach-Object { $_['ruleIds'] })
        $free = @($plan['actions'] | Where-Object { $_['ruleId'] -notin $ruleIds -and $_['procedure'] -notin $ruleIds })
        $free.Count | Should -BeGreaterThan 0
        @($free | Where-Object { $_.Contains('remediations') }) | Should -BeNullOrEmpty
    }

    It 'links a task to the remediations of its template' {
        $plan = $script:Plans[3]
        $linked = @($plan['tasks'] | Where-Object { $_.Contains('remediations') })
        $linked.Count | Should -BeGreaterThan 20
        $known = @($plan['remediations'] | ForEach-Object { $_['id'] })
        @($linked | ForEach-Object { $_['remediations'] } | Where-Object { $_ -notin $known }) | Should -BeNullOrEmpty
    }

    It 'describes the tenants and the waves from the project' {
        $plan = $script:Plans[2]
        @($plan['tenants'] | ForEach-Object { $_['role'] }) -join ',' | Should -Be 'Target,S1,S2'
        ($plan['tenants'] | Where-Object { $_['role'] -eq 'S2' })['wave'] | Should -Be 2
        ($plan['tenants'] | Where-Object { $_['role'] -eq 'Target' })['displayName'] | Should -Be 'Summit Holdings'
        @($plan['waves']).Count | Should -Be 2
    }

    It 'computes the plan when no rule set is given' {
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot $script:Fake[1]
        @($plan['actions']).Count | Should -Be @($script:Plans[1]['actions']).Count
    }

    It 'reads a project file' {
        $path = Join-Path $TestDrive 'project.json'
        Copy-Item (Join-Path $PSScriptRoot '../examples/two-to-one.project.json') $path
        $plan = New-TcPlan -Project $path -Snapshot $script:Fake[2] -RuleSet $script:Sets[2]
        @($plan['waves']).Count | Should -Be 2
    }

    It 'gives the same bytes for the same input' {
        $first = New-TcPlan -Project (New-TcPlanProject -Wave 1, 2) -Snapshot $script:Fake[2] -RuleSet $script:Sets[2]
        ($first | ConvertTo-Json -Depth 30) | Should -BeExactly ($script:Plans[2] | ConvertTo-Json -Depth 30)
    }

    It 'dates the plan from the snapshot' {
        $script:Plans[1]['meta']['snapshotFinished'] | Should -Be $script:Fake[1]['meta']['finished']
        ($script:Plans[1] | ConvertTo-Json -Depth 30) | Should -Not -Match ([datetime]::Now.ToString('yyyy-MM-ddTHH'))
    }

    It 'refuses a snapshot with a source the project does not have' {
        { New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot $script:Fake[2] -RuleSet $script:Sets[2] } | Should -Throw '*S2*'
    }
}

Describe 'Tasks by scope' {
    It 'repeats a Source task per source' -ForEach @(@{ Count = 1 }, @{ Count = 2 }, @{ Count = 3 }) {
        $ids = @($script:Plans[$Count]['tasks'] | Where-Object { $_['templateId'] -eq 'ID-02' } | ForEach-Object { $_['id'] })
        $ids.Count | Should -Be $Count
        $ids[0] | Should -Be 'ID-02.S1'
    }

    It 'repeats a Wave task per wave' {
        @($script:Plans[3]['tasks'] | Where-Object { $_['templateId'] -eq 'PREP-05' } | ForEach-Object { $_['id'] }) -join ',' | Should -Be 'PREP-05.S1,PREP-05.S2,PREP-05.S3'
    }

    It 'puts two sources of one wave in one Wave task' {
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1, 1) -Snapshot $script:Fake[2] -RuleSet $script:Sets[2]
        $task = @($plan['tasks'] | Where-Object { $_['templateId'] -eq 'PREP-05' })
        $task.Count | Should -Be 1
        @($task[0]['sources']) -join ',' | Should -Be 'S1,S2'
        $task[0]['title'] | Should -Match 'Alpine Group'
        $task[0]['title'] | Should -Match 'Birch Partners'
        $task[0]['id'] | Should -Be 'PREP-05.S1-S2'
    }

    It 'names a Wave task after its members, in role order, whatever the wave number' {
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 2, 1, 2) -Snapshot $script:Fake[3] -RuleSet $script:Sets[3]
        @($plan['tasks'] | Where-Object { $_['templateId'] -eq 'PREP-05' } | ForEach-Object { $_['id'] } | Sort-Object) -join ',' | Should -Be 'PREP-05.S1-S3,PREP-05.S2'
    }

    It 'keeps a Project task once and a Target task once' {
        @($script:Plans[3]['tasks'] | Where-Object { $_['templateId'] -eq 'KICK-01' }).Count | Should -Be 1
        @($script:Plans[3]['tasks'] | Where-Object { $_['templateId'] -eq 'SEC-02' } | ForEach-Object { $_['id'] }) | Should -Be 'SEC-02.Target'
    }

    It 'follows the moments in order' {
        $moments = 'Now', 'Preparation', 'Before cutover', 'Cutover', 'After cutover', 'Closure'
        $ranks = @($script:Plans[2]['tasks'] | ForEach-Object { $moments.IndexOf($_['moment']) })
        ($ranks -join ',') | Should -Be (@($ranks | Sort-Object) -join ',')
    }

    It 'changes with the state of the target' {
        $new = New-TcPlan -Project (New-TcPlanProject -Wave 1 -State New) -Snapshot $script:Fake[1] -RuleSet $script:Sets[1]
        $ids = @($new['tasks'] | ForEach-Object { $_['id'] })
        $ids | Should -Contain 'BUILD-05.Target'
        $ids | Should -Not -Contain 'BUILD-06.Target'
        $production = @($script:Plans[1]['tasks'] | ForEach-Object { $_['id'] })
        $production | Should -Contain 'BUILD-06.Target'
        $production | Should -Not -Contain 'BUILD-05.Target'
    }
}

Describe 'A service that is absent or not collected' {
    BeforeAll {
        $script:Base = {
            param([hashtable]$Tables = @{})
            $given = @{ Target = @{ users = @(@{ UPN = 'a@summit.example'; Name = 'A'; Type = 'Member' }) }; S1 = @{ users = @(@{ UPN = 'b@alpine.example'; Name = 'B'; Type = 'Member' }) } }
            foreach ($key in $Tables.Keys) { $given['S1'][$key] = $Tables[$key] }
            $coverage = @(New-TcCoverageLine -Role 'S1' -Workload 'Intune' -Id 'INT-01' -Status 'OK')
            New-TcRuleSnapshot -Given $given -Coverage $coverage
        }
        $script:PlanOf = {
            param($Snapshot)
            New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot $Snapshot
        }
    }

    It 'keeps the task of a service with rows' {
        $plan = & $script:PlanOf (& $script:Base @{ managedDevices = @(@{ Name = 'D1' }) })
        $task = @($plan['tasks'] | Where-Object { $_['id'] -eq 'DEV-03.S1' })
        $task.Count | Should -Be 1
        $task[0]['confirmation'] | Should -Be 'Confirmed'
    }

    It 'drops the task of a service collected empty' {
        $plan = & $script:PlanOf (& $script:Base @{ managedDevices = @() })
        @($plan['tasks'] | Where-Object { $_['id'] -eq 'DEV-03.S1' }).Count | Should -Be 0
    }

    It 'drops the task of a service the tenant does not have' {
        $snapshot = & $script:Base
        Remove-TcCollectorTable -Snapshot $snapshot -Role 'S1' -Table 'managedDevices' -Status 'License or service missing'
        $snapshot['coverage'] = @(New-TcCoverageLine -Role 'S1' -Workload 'Intune' -Id ((InModuleScope TenantConverge { Get-TcTableDictionary })['managedDevices']['collectors'][0]) -Status 'License or service missing')
        $plan = & $script:PlanOf $snapshot
        @($plan['tasks'] | Where-Object { $_['id'] -eq 'DEV-03.S1' }).Count | Should -Be 0
    }

    It 'keeps the task of an empty table from a partial collector, unconfirmed' {
        $producer = (InModuleScope TenantConverge { Get-TcTableDictionary })['managedDevices']['collectors'][0]
        $given = @{ Target = @{ users = @(@{ UPN = 'a@summit.example'; Name = 'A'; Type = 'Member' }) }; S1 = @{ users = @(@{ UPN = 'b@alpine.example'; Name = 'B'; Type = 'Member' }); managedDevices = @() } }
        $plan = & $script:PlanOf (New-TcRuleSnapshot -Given $given -Coverage @(New-TcCoverageLine -Role 'S1' -Workload 'Intune' -Id $producer -Status 'Partial'))
        $task = @($plan['tasks'] | Where-Object { $_['id'] -eq 'DEV-03.S1' })
        $task.Count | Should -Be 1
        $task[0]['confirmation'] | Should -Be 'Unconfirmed'
        $task[0]['reason'] | Should -Match 'not fully read'
    }

    It 'keeps the task of a service that was not collected, unconfirmed, with the reason' {
        $snapshot = & $script:Base
        $snapshot['coverage'] = @(New-TcCoverageLine -Role 'S1' -Workload 'Intune' -Id ((InModuleScope TenantConverge { Get-TcTableDictionary })['managedDevices']['collectors'][0]) -Status 'Insufficient access')
        $plan = & $script:PlanOf $snapshot
        $task = @($plan['tasks'] | Where-Object { $_['id'] -eq 'DEV-03.S1' })
        $task.Count | Should -Be 1
        $task[0]['confirmation'] | Should -Be 'Unconfirmed'
        $task[0]['reason'] | Should -Match 'Insufficient access'
    }

    It 'keeps the task of a collector that never ran, unconfirmed' {
        $snapshot = & $script:Base
        $snapshot['coverage'] = @()
        $plan = & $script:PlanOf $snapshot
        (@($plan['tasks'] | Where-Object { $_['id'] -eq 'DEV-03.S1' }))[0]['confirmation'] | Should -Be 'Unconfirmed'
    }

    It 'keeps a rule condition unconfirmed when the rule could not read what it needed' {
        $set = [ordered]@{ findings = @(); measures = @(); settingGaps = @(); unread = @([ordered]@{ role = 'S1'; workload = 'Intune'; tenantRole = 'S1'; table = 'intuneConnectors'; status = 'Module missing' }); errors = @() }
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot (& $script:Base) -RuleSet $set
        $task = @($plan['tasks'] | Where-Object { $_['id'] -eq 'PREP-08.S1' })
        $task.Count | Should -Be 1
        $task[0]['confirmation'] | Should -Be 'Unconfirmed'
    }

    It 'keeps a rule condition unconfirmed when the rules of its workload stopped' {
        $set = [ordered]@{ findings = @(); measures = @(); settingGaps = @(); unread = @(); errors = @([ordered]@{ role = 'S1'; workload = 'Intune'; message = 'Broken column' }) }
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot (& $script:Base) -RuleSet $set
        $task = @($plan['tasks'] | Where-Object { $_['id'] -eq 'PREP-08.S1' })
        $task.Count | Should -Be 1
        $task[0]['confirmation'] | Should -Be 'Unconfirmed'
        $task[0]['reason'] | Should -Match 'rules of Intune stopped'
    }

    It 'names the rules that stopped on the go/no-go' {
        $set = [ordered]@{ findings = @(); measures = @(); settingGaps = @(); unread = @(); errors = @([ordered]@{ role = 'S1'; workload = 'Intune'; message = 'Broken column' }) }
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot (& $script:Base) -RuleSet $set
        @($plan['actions'] | Where-Object { $_['id'] -eq 'S1-GO-NOGO' })[0]['finding'] | Should -Match 'Intune \(rules stopped\)'
    }

    It 'drops a rule condition when the rule read everything and found nothing' {
        $set = [ordered]@{ findings = @(); measures = @(); settingGaps = @(); unread = @(); errors = @() }
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot (& $script:Base) -RuleSet $set
        @($plan['tasks'] | Where-Object { $_['id'] -eq 'PREP-08.S1' }).Count | Should -Be 0
    }

    It 'never shortens the plan silently when a collector fails' -ForEach @(
        @{ Role = 'S1'; Table = 'managedDevices' }, @{ Role = 'S2'; Table = 'mailboxes' }, @{ Role = 'S1'; Table = 'sites' }, @{ Role = 'Target'; Table = 'conditionalAccess' }, @{ Role = 'S2'; Table = 'users' }
    ) {
        $before = @($script:Plans[2]['tasks'] | ForEach-Object { $_['id'] })
        $snapshot = New-TcCopy $script:Fake[2]
        Remove-TcCollectorTable -Snapshot $snapshot -Role $Role -Table $Table
        $after = @((New-TcPlan -Project (New-TcPlanProject -Wave 1, 2) -Snapshot $snapshot)['tasks'] | ForEach-Object { $_['id'] })
        @($before | Where-Object { $_ -notin $after }) | Should -BeNullOrEmpty
    }

    It 'plans a source the snapshot has not reached yet' {
        $snapshot = New-TcCopy $script:Fake[1]
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1, 2) -Snapshot $snapshot
        $task = @($plan['tasks'] | Where-Object { $_['id'] -eq 'ID-02.S2' })
        $task.Count | Should -Be 1
        $task[0]['confirmation'] | Should -Be 'Unconfirmed'
    }

    It 'counts the unconfirmed tasks' {
        $snapshot = & $script:Base
        $snapshot['coverage'] = @()
        $plan = & $script:PlanOf $snapshot
        $plan['meta']['unconfirmedTasks'] | Should -Be @($plan['tasks'] | Where-Object { $_['confirmation'] -eq 'Unconfirmed' }).Count
        $plan['meta']['unconfirmedTasks'] | Should -BeGreaterThan 0
    }
}

Describe 'Stable task identifiers' {
    It 'does not depend on the number of sources' {
        $two = @($script:Plans[2]['tasks'] | Where-Object { $_['id'] -match '\.S[12]$' } | ForEach-Object { $_['id'] })
        $three = @($script:Plans[3]['tasks'] | ForEach-Object { $_['id'] })
        @($two | Where-Object { $_ -notin $three }) | Should -BeNullOrEmpty
    }

    It 'does not change when a source moves to another wave' {
        $moved = New-TcPlan -Project (New-TcPlanProject -Wave 2, 1) -Snapshot $script:Fake[2] -RuleSet $script:Sets[2]
        $sourceTasks = { param($Plan) @($Plan['tasks'] | Where-Object { $_['scope'] -eq 'Source' } | ForEach-Object { $_['id'] } | Sort-Object) -join ',' }
        (& $sourceTasks $moved) | Should -Be (& $sourceTasks $script:Plans[2])
    }

    It 'keeps the meaning of a Wave task when two sources swap waves' {
        $swapped = New-TcPlan -Project (New-TcPlanProject -Wave 2, 1) -Snapshot $script:Fake[2] -RuleSet $script:Sets[2]
        foreach ($plan in $script:Plans[2], $swapped) {
            $task = @($plan['tasks'] | Where-Object { $_['id'] -eq 'CUT-01.S1' })
            $task.Count | Should -Be 1
            @($task[0]['sources']) | Should -Be 'S1'
        }
    }

    It 'gives a new identifier when the members of a wave change, so the old row shows as an orphan' {
        $merged = New-TcPlan -Project (New-TcPlanProject -Wave 1, 1) -Snapshot $script:Fake[2] -RuleSet $script:Sets[2]
        $tracking = @(@{ id = 'CUT-01.S1'; status = 'Done' })
        $rows = InModuleScope TenantConverge -Parameters @{ Item = @($merged['tasks']); Tracking = $tracking } {
            param($Item, $Tracking)
            @(Merge-TcTrackingRow -Item $Item -Tracking $Tracking)
        }
        ($rows | Where-Object { $_['id'] -eq 'CUT-01.S1' })['orphan'] | Should -BeTrue
        ($rows | Where-Object { $_['id'] -eq 'CUT-01.S1-S2' })['status'] | Should -BeNullOrEmpty
    }

    It 'derives the identifier from the template and the scope' {
        foreach ($task in $script:Plans[3]['tasks']) {
            $task['id'] | Should -Match ("^{0}(\.(Target|S[123](-S[123])*))?$" -f [regex]::Escape($task['templateId']))
        }
    }

    It 'is unique' {
        foreach ($plan in $script:Plans.Values) {
            foreach ($list in 'tasks', 'actions') {
                $ids = @($plan[$list] | ForEach-Object { $_['id'] })
                @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count -Because $list
            }
        }
    }
}

Describe 'Wording by scenario' {
    It 'never mentions a source that is not in the project' {
        ($script:Plans[1]['tasks'] | ConvertTo-Json -Depth 10) | Should -Not -Match '\bS[23]\b|\.S[23]"|Birch|Cedar'
        ($script:Plans[1]['actions'] | ConvertTo-Json -Depth 10) | Should -Not -Match '"role":\s*"S[23]"'
    }

    It 'names the source, not a wave number, when there is one wave' {
        $task = @($script:Plans[1]['tasks'] | Where-Object { $_['templateId'] -eq 'CUT-01' })[0]
        $task['title'] | Should -Match 'Alpine Group'
        $task['title'] | Should -Not -Match '\bwave\b'
    }

    It 'names the wave when there are several' {
        $task = @($script:Plans[2]['tasks'] | Where-Object { $_['id'] -eq 'CUT-01.S2' })[0]
        $task['title'] | Should -Match 'wave 2'
        $task['title'] | Should -Match 'Birch Partners'
    }

    It 'leaves no placeholder in a title' {
        foreach ($task in $script:Plans[3]['tasks']) { $task['title'] | Should -Not -Match '[{}]' }
    }
}

Describe 'Actions' {
    It 'gives every finding an action' {
        foreach ($count in 1, 2, 3) {
            $fromRules = @($script:Plans[$count]['actions'] | Where-Object { $_['origin'] -contains 'Assessment' })
            $fromRules.Count | Should -Be @($script:Sets[$count]['findings']).Count
        }
    }

    It 'links an action to the procedure of its rule' {
        $action = @($script:Plans[2]['actions'] | Where-Object { $_['ruleId'] -eq 'DNS-TTL' })[0]
        $action['procedure'] | Should -Be 'DNS-TTL'
        $plain = @($script:Plans[3]['actions'] | Where-Object { $_['ruleId'] -eq 'EXO-AUDIT' })
        foreach ($item in $plain) { $item['procedure'] | Should -Be '' }
    }

    It 'turns All tenants findings into actions of role All' {
        @($script:Plans[2]['actions'] | Where-Object { $_['ruleId'] -like 'CON-*' } | ForEach-Object { $_['role'] } | Sort-Object -Unique) | Should -Be 'All'
    }

    It 'marks critical findings as blocking and keeps blockers first in their moment' {
        foreach ($action in @($script:Plans[3]['actions'] | Where-Object { $_['severity'] -eq 'Critical' })) { $action['blocking'] | Should -BeTrue }
        foreach ($action in @($script:Plans[3]['actions'] | Where-Object { $_['blocking'] })) { $action['severity'] | Should -BeIn 'Critical', 'High' }
    }

    It 'orders the actions by moment, blockers first' {
        $moments = 'Now', 'Preparation', 'Before cutover', 'Cutover', 'After cutover', 'Closure'
        $keys = @($script:Plans[3]['actions'] | ForEach-Object { '{0}{1}' -f $moments.IndexOf($_['moment']), $(if ($_['blocking']) { 0 } else { 1 }) })
        ($keys -join ',') | Should -Be (@($keys | Sort-Object) -join ',')
    }

    It 'adds the go/no-go of each source, with its blockers' {
        $go = @($script:Plans[2]['actions'] | Where-Object { $_['id'] -eq 'S1-GO-NOGO' })
        $go.Count | Should -Be 1
        $go[0]['procedure'] | Should -Be 'GO-NOGO'
        $go[0]['blocking'] | Should -BeFalse
        $blockers = @($script:Plans[2]['actions'] | Where-Object { $_['role'] -eq 'S1' -and $_['blocking'] })
        @($go[0]['items']).Count | Should -Be $blockers.Count
    }

    It 'adds the identity matrix of each source, as a blocker' {
        $matrix = @($script:Plans[2]['actions'] | Where-Object { $_['id'] -eq 'S2-IDENTITY-MATRIX' })
        $matrix.Count | Should -Be 1
        $matrix[0]['blocking'] | Should -BeTrue
        $matrix[0]['moment'] | Should -Be 'Now'
        $matrix[0]['finding'] | Should -Match '^Draft: \d+ row'
    }

    It 'flags duplicates that point to a synced target account' {
        $given = @{
            Target = @{ users = @(@{ UPN = 'jane@summit.example'; Name = 'Jane Roy'; Type = 'Member'; Synced = $true }) }
            S1     = @{ users = @(@{ UPN = 'jane@alpine.example'; Name = 'Jane Roy'; Type = 'Member'; Enabled = $true; 'License count' = 1 }) }
        }
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot (New-TcRuleSnapshot -Given $given)
        $action = @($plan['actions'] | Where-Object { $_['id'] -eq 'S1-SYNCED-DUPLICATES' })
        $action.Count | Should -Be 1
        $action[0]['procedure'] | Should -Be 'SYNCED-DUPLICATES'
        $action[0]['blocking'] | Should -BeTrue
        $action[0]['itemCount'] | Should -Be 1
    }

    It 'carries no finding of the old simulation or execution tool' {
        ($script:Plans[2]['actions'] | ConvertTo-Json -Depth 10) | Should -Not -Match 'OUTIL-|"simulation"'
    }
}

Describe 'A source that was not read' {
    BeforeAll {
        $script:NoFinding = [ordered]@{ findings = @(); measures = @(); settingGaps = @(); unread = @(); errors = @() }
        $script:ActionOf = { param($Plan, [string]$Id) @($Plan['actions'] | Where-Object { $_['id'] -eq $Id })[0] }
    }

    It 'keeps a blocking matrix action when the snapshot holds no table at all' {
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot (New-TcRuleSnapshot)
        $matrix = & $script:ActionOf $plan 'S1-IDENTITY-MATRIX'
        $matrix['blocking'] | Should -BeTrue
        $matrix['procedure'] | Should -Be 'IDENTITY-MATRIX'
        $matrix['finding'] | Should -Match '^No draft'
        $plan['meta']['blockingActions'] | Should -BeGreaterThan 0
    }

    It 'says why the draft could not be made, with the status and the remedy of the collector' {
        $snapshot = New-TcCopy $script:Fake[2]
        Remove-TcCollectorTable -Snapshot $snapshot -Role 'S2' -Table 'users'
        foreach ($line in @($snapshot['coverage'] | Where-Object { $_['role'] -eq 'S2' -and $_['status'] -eq 'Insufficient access' })) { $line['remedy'] = 'Give the account a role.' }
        $matrix = & $script:ActionOf (New-TcPlan -Project (New-TcPlanProject -Wave 1, 2) -Snapshot $snapshot) 'S2-IDENTITY-MATRIX'
        $matrix['blocking'] | Should -BeTrue
        $matrix['finding'] | Should -Match 'Insufficient access'
        $matrix['finding'] | Should -Match 'Access denied'
        $matrix['action'] | Should -Match 'Give the account a role'
    }

    It 'makes no draft from an empty users table of a partial collector' {
        $producer = (InModuleScope TenantConverge { Get-TcTableDictionary })['users']['collectors'][0]
        $snapshot = New-TcRuleSnapshot -Given @{ Target = @{ users = @() }; S1 = @{ users = @() } } -Coverage @(New-TcCoverageLine -Role 'S1' -Workload 'Entra ID' -Id $producer -Status 'Partial')
        $matrix = & $script:ActionOf (New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot $snapshot) 'S1-IDENTITY-MATRIX'
        $matrix['blocking'] | Should -BeTrue
        $matrix['finding'] | Should -Match '^No draft.*Partial'
    }

    It 'keeps the action of a source the snapshot has not reached' {
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1, 2) -Snapshot (New-TcCopy $script:Fake[1])
        (& $script:ActionOf $plan 'S2-IDENTITY-MATRIX')['blocking'] | Should -BeTrue
    }

    It 'keeps the action when the target is not in the snapshot' {
        $snapshot = New-TcRuleSnapshot -Given @{ S1 = @{ users = @(@{ UPN = 'a@alpine.example'; Name = 'A'; Type = 'Member' }) } }
        $snapshot['tenants'].Remove('Target')
        (& $script:ActionOf (New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot $snapshot) 'S1-IDENTITY-MATRIX')['finding'] | Should -Match '^No draft'
    }

    It 'warns on the draft when the accounts of the target could not be read' {
        $snapshot = New-TcRuleSnapshot -Given @{ S1 = @{ users = @(@{ UPN = 'a@alpine.example'; Name = 'A'; Type = 'Member' }) } }
        $matrix = & $script:ActionOf (New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot $snapshot) 'S1-IDENTITY-MATRIX'
        $matrix['finding'] | Should -Match '^Draft'
        $matrix['finding'] | Should -Match 'target could not be read'
    }

    It 'shows that no matrix was drafted in the target configurations' {
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot (New-TcRuleSnapshot)
        $row = @($plan['targetConfigurations'] | Where-Object { $_['origin'] -eq 'Matrix' })[0]
        $row['current'] | Should -Be 'Not drafted'
        $row['action'] | Should -Be 'S1-IDENTITY-MATRIX'
    }

    It 'never says that nothing blocks a source that was not read' {
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1, 2) -Snapshot (New-TcRuleSnapshot)
        foreach ($id in 'S1-GO-NOGO', 'S2-GO-NOGO') {
            $go = & $script:ActionOf $plan $id
            $go['finding'] | Should -Not -Match 'No blocking action for this source'
            $go['finding'] | Should -Match 'Could not be read'
            $go['itemCount'] | Should -BeGreaterThan 0
        }
    }

    It 'names what could not be read on the go/no-go, even when the accounts were read' {
        $given = @{ Target = @{ users = @() }; S1 = @{ users = @() } }
        $coverage = @(New-TcCoverageLine -Role 'S1' -Workload 'Entra ID' -Id 'ENT-03' -Status 'OK'; New-TcCoverageLine -Role 'S1' -Workload 'Intune' -Id 'INT-01' -Status 'Insufficient access')
        $go = & $script:ActionOf (New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot (New-TcRuleSnapshot -Given $given -Coverage $coverage) -RuleSet $script:NoFinding) 'S1-GO-NOGO'
        $go['finding'] | Should -Not -Match 'No blocking action for this source'
        $go['finding'] | Should -Match 'Intune \(Insufficient access\)'
    }

    It 'names what the rules could not read on the go/no-go' {
        $set = [ordered]@{ findings = @(); measures = @(); settingGaps = @(); errors = @(); unread = @([ordered]@{ role = 'S1'; workload = 'Teams'; tenantRole = 'S1'; table = 'teams'; status = 'Not run' }) }
        $go = & $script:ActionOf (New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot (New-TcRuleSnapshot -Given @{ S1 = @{ users = @() } }) -RuleSet $set) 'S1-GO-NOGO'
        $go['finding'] | Should -Match 'Teams \(Not run\)'
    }

    It 'leaves out a service the tenant does not have' {
        $given = @{ Target = @{ users = @() }; S1 = @{ users = @() } }
        $coverage = @(New-TcCoverageLine -Role 'S1' -Workload 'Entra ID' -Id 'ENT-03' -Status 'OK'; New-TcCoverageLine -Role 'S1' -Workload 'Intune' -Id 'INT-01' -Status 'License or service missing')
        $go = & $script:ActionOf (New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot (New-TcRuleSnapshot -Given $given -Coverage $coverage) -RuleSet $script:NoFinding) 'S1-GO-NOGO'
        $go['finding'] | Should -Be 'No blocking action for this source.'
    }

    It 'still says that nothing blocks a source that was read' {
        $given = @{ Target = @{ users = @() }; S1 = @{ users = @() } }
        $coverage = @(New-TcCoverageLine -Role 'S1' -Workload 'Entra ID' -Id 'ENT-03' -Status 'OK')
        $go = & $script:ActionOf (New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot (New-TcRuleSnapshot -Given $given -Coverage $coverage) -RuleSet $script:NoFinding) 'S1-GO-NOGO'
        $go['finding'] | Should -Be 'No blocking action for this source.'
    }
}

Describe 'Target configurations' {
    It 'lists the settings of the procedures of the actions' {
        $line = @($script:Plans[2]['targetConfigurations'] | Where-Object { $_['origin'] -eq 'Procedure' })
        $line.Count | Should -BeGreaterThan 10
        foreach ($row in $line) { $row['action'] | Should -BeIn @($script:Plans[2]['actions'] | ForEach-Object { $_['id'] }) }
    }

    It 'lists each setting that differs from the target, for each source' {
        $set = [ordered]@{ findings = @(); measures = @(); unread = @(); errors = @()
            settingGaps = @([ordered]@{ workload = 'Teams'; table = 'teamsSettings'; setting = 'Lobby'; important = $true; values = [ordered]@{ Target = 'On'; S1 = 'Off' }; different = @('S1') })
        }
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot $script:Fake[1] -RuleSet $set
        $row = @($plan['targetConfigurations'] | Where-Object { $_['setting'] -like '*Lobby' })
        $row.Count | Should -Be 1
        $row[0]['role'] | Should -Be 'S1'
        $row[0]['current'] | Should -Be 'Off'
        $row[0]['target'] | Should -Be 'On'
        $row[0]['origin'] | Should -Be 'Important gap'
    }

    It 'puts the measured value on a procedure setting, once' {
        $finding = [ordered]@{ id = 'CMP-SETTINGS'; severity = 'Medium'; order = 2; workload = 'SharePoint and OneDrive'; role = 'Both'; code = 'S1'; tenant = 'x'; category = 'Security'; title = 't'; finding = 'f'; action = 'a'; why = 'w'; owner = 'Migration team'; moment = 'Now'; effort = 'Low'; question = ''; items = @(); itemCount = 0 }
        $set = [ordered]@{ findings = @($finding); measures = @(); unread = @(); errors = @()
            settingGaps = @([ordered]@{ workload = 'SharePoint and OneDrive'; table = 'sharePointSettings'; setting = 'SharingCapability'; important = $true; values = [ordered]@{ Target = 'A'; S1 = 'B' }; different = @('S1') })
        }
        $plan = New-TcPlan -Project (New-TcPlanProject -Wave 1) -Snapshot $script:Fake[1] -RuleSet $set
        $row = @($plan['targetConfigurations'] | Where-Object { $_['setting'] -like '*SharingCapability' })
        $row.Count | Should -Be 1
        $row[0]['current'] | Should -Be 'B'
        $row[0]['origin'] | Should -Be 'Procedure'
    }

    It 'lists the identity matrix to validate for each source' {
        @($script:Plans[3]['targetConfigurations'] | Where-Object { $_['origin'] -eq 'Matrix' } | ForEach-Object { $_['role'] }) -join ',' | Should -Be 'S1,S2,S3'
    }
}

Describe 'Decisions' {
    It 'asks the question of each finding that has one' {
        $withQuestion = @($script:Plans[2]['actions'] | Where-Object { $_['question'] })
        $withQuestion.Count | Should -BeGreaterThan 0
        foreach ($action in $withQuestion) { "D-$($action['id'])" | Should -BeIn @($script:Plans[2]['decisions'] | ForEach-Object { $_['id'] }) }
    }

    It 'asks the question of each task that has one' {
        @($script:Plans[2]['decisions'] | Where-Object { $_['id'] -eq 'D-TOOL-01' }).Count | Should -Be 1
    }

    It 'has unique identifiers' {
        $ids = @($script:Plans[3]['decisions'] | ForEach-Object { $_['id'] })
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }
}

Describe 'Integrity of the plan' {
    It 'never points to a procedure it does not carry' -ForEach @(@{ Count = 1 }, @{ Count = 2 }, @{ Count = 3 }) {
        $plan = $script:Plans[$Count]
        $used = @($plan['actions'] | ForEach-Object { $_['procedure'] }) + @($plan['tasks'] | ForEach-Object { $_['procedure'] }) | Where-Object { $_ } | Sort-Object -Unique
        foreach ($id in $used) { $plan['procedures'].Contains($id) | Should -BeTrue -Because $id }
        @($plan['procedures'].Keys).Count | Should -Be @($used).Count
    }

    It 'only names tenants of the project' -ForEach @(@{ Count = 1 }, @{ Count = 2 }, @{ Count = 3 }) {
        $plan = $script:Plans[$Count]
        $roles = @($plan['tenants'] | ForEach-Object { $_['role'] }) + 'All'
        foreach ($list in 'actions', 'tasks', 'decisions', 'targetConfigurations') {
            foreach ($row in @($plan[$list])) { $row['role'] | Should -BeIn $roles -Because $list }
        }
    }

    It 'indexes everything by tenant and by wave' {
        $plan = $script:Plans[2]
        @($plan['byTenant'].Keys) -join ',' | Should -Be 'Target,S1,S2,All'
        foreach ($id in @($plan['byTenant']['S2']['tasks'])) { $id | Should -BeIn @($plan['tasks'] | ForEach-Object { $_['id'] }) }
        @($plan['byWave'].Keys) -join ',' | Should -Be '1,2'
        @($plan['byWave']['2']['sources']) | Should -Be 'S2'
        @($plan['byWave']['2']['tasks']) | Should -Contain 'CUT-01.S2'
        @($plan['byWave']['2']['tasks']) | Should -Contain 'ID-02.S2'
        @($plan['byWave']['2']['actions']) | Should -Contain 'S2-IDENTITY-MATRIX'
    }

    It 'makes no connection' {
        (Get-Command New-TcPlan).ScriptBlock.ToString() | Should -Not -Match 'Connect-|Invoke-MgGraphRequest|Invoke-RestMethod'
    }
}

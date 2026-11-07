BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    $script:Tasks = @((InModuleScope TenantConverge { Get-TcTaskCatalog }).Values)
    $script:RuleIds = @((InModuleScope TenantConverge { Get-TcRuleCatalog }).Keys)
    $script:TableKeys = @((InModuleScope TenantConverge { Get-TcTableDictionary }).Keys)
}

Describe 'The task catalog' {
    It 'loads from Data/tasks.json, once' {
        InModuleScope TenantConverge {
            $first = Get-TcTaskCatalog
            [object]::ReferenceEquals($first, (Get-TcTaskCatalog)) | Should -BeTrue
        }
    }

    It 'has tasks with unique identifiers' {
        $script:Tasks.Count | Should -BeGreaterThan 40
        $ids = @($script:Tasks | ForEach-Object { $_['id'] })
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
        foreach ($id in $ids) { $id | Should -Match '^[A-Z]+-\d{2}$' }
    }

    It 'gives every task what the plan needs' {
        foreach ($task in $script:Tasks) {
            foreach ($key in 'title', 'workstream', 'scope', 'moment', 'owner') {
                $task[$key] | Should -Not -BeNullOrEmpty -Because "$($task['id']) needs $key"
            }
        }
    }

    It 'only uses the agreed values' {
        foreach ($task in $script:Tasks) {
            $task['scope'] | Should -BeIn @('Project', 'Target', 'Source', 'Wave')
            $task['moment'] | Should -BeIn @('Now', 'Preparation', 'Before cutover', 'Cutover', 'After cutover', 'Closure')
            $task['owner'] | Should -BeIn @('Migration team', 'Customer', 'Migration team and Customer')
        }
    }

    It 'bases every condition on a real rule or table' {
        $used = 0
        foreach ($task in $script:Tasks) {
            $condition = $task['condition']
            if (-not $condition) { continue }
            foreach ($key in $condition.Keys) { $key | Should -BeIn @('rules', 'tables') -Because $task['id'] }
            foreach ($rule in @($condition['rules'])) { if ($rule) { $used++; $rule | Should -BeIn $script:RuleIds -Because $task['id'] } }
            foreach ($table in @($condition['tables'])) { if ($table) { $used++; $table | Should -BeIn $script:TableKeys -Because $task['id'] } }
        }
        $used | Should -BeGreaterThan 20
    }

    It 'names its scope in the title with the matching placeholder' {
        foreach ($task in $script:Tasks) {
            switch ($task['scope']) {
                'Source' { $task['title'] | Should -Match '\{tenant\}' -Because $task['id'] }
                'Wave' { $task['title'] | Should -Match '\{wave\}' -Because $task['id'] }
                default { $task['title'] | Should -Not -Match '\{(tenant|wave)\}' -Because $task['id'] }
            }
        }
    }

    It 'limits a task to a target state only with a known state' {
        foreach ($task in $script:Tasks) {
            if ($task.Contains('targetState')) { $task['targetState'] | Should -BeIn @('New', 'Production') -Because $task['id'] }
        }
    }

    It 'keeps out contract terms and amounts' {
        foreach ($task in $script:Tasks) {
            $text = ($task['title'], $task['decision']) -join ' '
            $text | Should -Not -Match '\d\s?\$|\$\s?\d' -Because $task['id']
            $text | Should -Not -Match '(?i)\b(phase|offer|invoice|quote)\b' -Because $task['id']
        }
    }
}

Describe 'The procedure catalog' {
    BeforeAll {
        $script:Procedures = @((InModuleScope TenantConverge { Get-TcProcedureCatalog }).Values)
        $script:ProcedureIds = @($script:Procedures | ForEach-Object { $_['id'] })

        function Get-TcProcedureText {
            <# Every text of a procedure, commands included. #>
            param($Procedure)
            foreach ($key in 'title', 'goal', 'duration') { $Procedure[$key] }
            foreach ($key in 'prerequisites', 'verification', 'risks') { @($Procedure[$key]) }
            foreach ($step in @($Procedure['steps'])) { $step['text']; $step['where']; $step['command'] }
            foreach ($line in @($Procedure['configuration'])) { $line['setting']; $line['target']; $line['where'] }
            foreach ($link in @($Procedure['links'])) { $link['title'] }
        }
    }

    It 'loads from Data/procedures.json, once' {
        InModuleScope TenantConverge {
            $first = Get-TcProcedureCatalog
            [object]::ReferenceEquals($first, (Get-TcProcedureCatalog)) | Should -BeTrue
        }
    }

    It 'keeps all the procedures, with unique identifiers' {
        $script:Procedures.Count | Should -Be 95
        @($script:ProcedureIds | Sort-Object -Unique).Count | Should -Be 95
    }

    It 'gives every procedure what the report needs' {
        foreach ($procedure in $script:Procedures) {
            foreach ($key in 'title', 'goal', 'duration') { $procedure[$key] | Should -Not -BeNullOrEmpty -Because "$($procedure['id']) needs $key" }
            @($procedure['steps']).Count | Should -BeGreaterThan 2 -Because $procedure['id']
            @($procedure['verification']).Count | Should -BeGreaterThan 0 -Because $procedure['id']
            foreach ($step in @($procedure['steps'])) {
                $step['text'] | Should -Not -BeNullOrEmpty -Because $procedure['id']
                $step['where'] | Should -Not -BeNullOrEmpty -Because $procedure['id']
            }
        }
    }

    It 'links to Microsoft Learn in English' {
        $count = 0
        foreach ($procedure in $script:Procedures) {
            foreach ($link in @($procedure['links'])) {
                $count++
                $link['url'] | Should -Match '^https://learn\.microsoft\.com/en-us/' -Because $procedure['id']
                $link['title'] | Should -Not -BeNullOrEmpty -Because $procedure['id']
            }
        }
        $count | Should -BeGreaterThan 150
    }

    It 'keeps out the steps of the old execution tool, accents and addresses of real domains' {
        foreach ($procedure in $script:Procedures) {
            foreach ($text in @(Get-TcProcedureText $procedure)) {
                $text | Should -Not -Match '\b(BAS|PRE|PREP|POST)-\d{2}\b' -Because $procedure['id']
                $text | Should -Not -Match '[àâçéèêëîïôùûü]' -Because $procedure['id']
                $text | Should -Not -Match '\.config\.json|Invoke-MigrationTenant|-Mode Inventaire' -Because $procedure['id']
            }
        }
    }

    It 'turns on only what a use needs in EXO-PROTOCOLS, as its text says' {
        $step = @(($script:Procedures | Where-Object { $_['id'] -eq 'EXO-PROTOCOLS' })['steps'])[3]
        $step['text'] | Should -Match 'turn on only'
        $step['command'] | Should -Match '^Set-CASMailbox'
        $step['command'] | Should -Not -Match '-(Pop|Imap)Enabled \$false'
        $step['command'] | Should -Match '-PopEnabled \$true.*-ImapEnabled \$true.*-SmtpClientAuthenticationDisabled \$false'
        $step['command'] | Should -Match '<[^>]*validated[^>]*>'
    }

    It 'reads the CSV exports with their default comma' {
        $reads = @($script:Procedures | ForEach-Object { @($_['steps']) } | ForEach-Object { $_['command'] } | Where-Object { $_ -match 'Import-Csv' })
        $reads.Count | Should -BeGreaterThan 1
        foreach ($command in $reads) { $command | Should -Not -Match '-Delimiter' }
    }

    It 'gives each task a procedure that exists' {
        $used = 0
        foreach ($task in $script:Tasks) {
            if ($task.Contains('procedure')) { $used++; $task['procedure'] | Should -BeIn $script:ProcedureIds -Because $task['id'] }
        }
        $used | Should -BeGreaterThan 20
    }

    It 'reaches every procedure from a rule, a task or the plan' {
        $reached = @($script:RuleIds) + @($script:Tasks | ForEach-Object { $_['procedure'] }) + 'SYNCED-DUPLICATES', 'GO-NOGO', 'IDENTITY-MATRIX'
        foreach ($id in $script:ProcedureIds) { $id | Should -BeIn $reached }
    }
}

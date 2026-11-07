BeforeDiscovery {
    $script:Counts = @(@{ Count = 1 }, @{ Count = 2 }, @{ Count = 3 })
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')
    . (Join-Path $PSScriptRoot 'Support/ReportFixtures.ps1')

    $script:Base = @{}
    foreach ($count in 1, 2, 3) {
        $fixture = Get-TcReportFixture -SourceCount $count -Folder $TestDrive
        $script:Base[$count] = @{ Fixture = $fixture; Result = Get-TcReportFixtureData -Fixture $fixture }
    }
}

Describe 'What the report receives at <Count> source(s)' -ForEach $script:Counts {
    BeforeAll {
        $script:Data = $script:Base[$Count]['Result']['Data']
        $script:Roles = @(@('Target', 'S1', 'S2', 'S3')[0..$Count])
        $script:Absent = @('S1', 'S2', 'S3' | Where-Object { $_ -notin $script:Roles })
    }

    It 'lists the tenants of the project, the target first' {
        @($script:Data['tenants'] | ForEach-Object { $_['role'] }) | Should -Be $script:Roles
    }

    It 'has a part for each source, and none for a source that does not exist' {
        foreach ($map in $script:Data['identity'], $script:Data['dns'], $script:Data['solutions']['ewsState'], $script:Data['tableStates']) {
            foreach ($role in $script:Absent) { $map.Contains($role) | Should -BeFalse -Because $role }
        }
        foreach ($role in @($script:Roles | Where-Object { $_ -ne 'Target' })) { $script:Data['identity'].Contains($role) | Should -BeTrue }
    }

    It 'has no value for a role that does not exist' {
        foreach ($measure in $script:Data['measures']) { foreach ($role in $script:Absent) { $measure['values'].Contains($role) | Should -BeFalse } }
        foreach ($fact in $script:Data['solutions']['exposureFacts']) { foreach ($role in $script:Absent) { $fact['values'].Contains($role) | Should -BeFalse } }
    }

    It 'splits the tables from the data, by role' {
        @($script:Base[$Count]['Result']['Tables'].Keys | Sort-Object) | Should -Be @($script:Roles | Sort-Object)
    }

    It 'carries the plan as it is' {
        @($script:Data['actions']).Count | Should -Be @($script:Base[$Count]['Fixture']['Plan']['actions']).Count
        @($script:Data['tasks']).Count | Should -Be @($script:Base[$Count]['Fixture']['Plan']['tasks']).Count
    }

    It 'carries both scores of each tenant' {
        foreach ($line in $script:Data['readiness']) {
            $names = $line.PSObject.Properties.Name
            'Score' | Should -BeIn $names
            'CollectedScore' | Should -BeIn $names
        }
    }

    It 'keeps a list of one as a list in what the page reads' {
        $json = InModuleScope TenantConverge -Parameters @{ Value = $script:Data['tenants'] } { param($Value) ConvertTo-TcReportJson -InputObject $Value }
        foreach ($tenant in ($json | ConvertFrom-Json -AsHashtable)) { $tenant['domains'].GetType().IsArray -or $tenant['domains'] -is [System.Collections.IList] | Should -BeTrue -Because $tenant['role'] }
    }

    It 'says when the facts were checked' {
        $script:Data['solutions']['checkedOn'] | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }
}

Describe 'Not collected and not used' {
    BeforeAll {
        $script:Fixture = Get-TcReportFixture -SourceCount 2 -Folder $TestDrive
        Remove-TcReportTable -Snapshot $script:Fixture['Snapshot'] -Role 'S2' -Table 'mailboxUsage'
        Remove-TcReportTable -Snapshot $script:Fixture['Snapshot'] -Role 'S2' -Table 'siteUsage'
        Remove-TcReportTable -Snapshot $script:Fixture['Snapshot'] -Role 'S2' -Table 'mailboxProtocols'
        Remove-TcReportTable -Snapshot $script:Fixture['Snapshot'] -Role 'S2' -Table 'exchangeSettings'
        Remove-TcReportTable -Snapshot $script:Fixture['Snapshot'] -Role 'S2' -Table 'servicePrincipals'
        Clear-TcReportTable -Snapshot $script:Fixture['Snapshot'] -Role 'S1' -Table 'plannerPlans'
        $script:Fixture['Snapshot']['tenants']['S1']['tables']['microsoft365Groups'] = @()
        foreach ($line in @($script:Fixture['Snapshot']['coverage'])) { if ($line['role'] -eq 'S1' -and $line['id'] -eq 'EXO-04') { $line['status'] = 'OK' } }
        $script:Fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $script:Fixture['Snapshot']
        $script:Fixture['Plan'] = New-TcPlan -Project $script:Fixture['Project'] -Snapshot $script:Fixture['Snapshot'] -RuleSet $script:Fixture['RuleSet']
        $script:Data = (Get-TcReportFixtureData -Fixture $script:Fixture)['Data']
        $script:Fact = { param($Id) @($script:Data['solutions']['exposureFacts'] | Where-Object { $_['id'] -eq $Id })[0] }
    }

    It 'gives each table its state, for each tenant' {
        $script:Data['tableStates']['S2']['mailboxUsage']['state'] | Should -Be 'NotCollected'
        $script:Data['tableStates']['S2']['mailboxUsage']['status'] | Should -Be 'Insufficient access'
        $script:Data['tableStates']['S1']['plannerPlans']['state'] | Should -Be 'NotFullyRead'
        $script:Data['tableStates']['S1']['microsoft365Groups']['state'] | Should -Be 'NotUsed'
        $script:Data['tableStates']['S1']['users']['state'] | Should -Be 'Collected'
    }

    It 'names the table behind each measure, so a gap can be explained' {
        foreach ($measure in $script:Data['measures']) { $measure['table'] | Should -Not -BeNullOrEmpty -Because $measure['label'] }
    }

    It 'keeps an unread measure empty and names the source' {
        $measure = @($script:Data['measures'] | Where-Object { $_['label'] -eq 'Mailbox volume (GB)' })[0]
        $measure['values']['S2'] | Should -BeNullOrEmpty
        $measure['unreadSources'] | Should -Contain 'S2'
    }

    It 'never reads an unread table as zero in the exposure' {
        $fact = & $script:Fact 'largestMailbox'
        $fact['values']['S2'] | Should -BeNullOrEmpty
        $fact['values']['S1'] | Should -BeGreaterThan 0
        $fact['unread'] | Should -Contain 'S2'
        (& $script:Fact 'largeSites')['values']['S2'] | Should -BeNullOrEmpty
    }

    It 'never reads a partly read empty table as zero in the exposure' {
        $fact = & $script:Fact 'plannerPlans'
        $fact['values']['S1'] | Should -BeNullOrEmpty
        $fact['unread'] | Should -Contain 'S1'
    }

    It 'reads an empty table of a clean collector as a true zero' {
        (& $script:Fact 'microsoft365Groups')['values']['S1'] | Should -Be 0
    }

    It 'calls a number a minimum when a source was not read' {
        (& $script:Fact 'plannerPlans')['text'] | Should -Match 'Not read: Alpine Group, so this is a minimum'
    }

    It 'does not read the EWS setting as unset when it was not collected' {
        $line = $script:Data['solutions']['ewsState']['S2']
        $line['read'] | Should -BeFalse
        $line['enabled'] | Should -BeNullOrEmpty
        $line['mailboxes'] | Should -BeNullOrEmpty
    }

    It 'tells a read setting that is empty from an unread one' {
        $line = $script:Data['solutions']['ewsState']['S1']
        $line['read'] | Should -BeTrue
    }

    It 'does not conclude that a product is absent from a table it could not read' {
        $coverage = $script:Data['solutions']['traceCoverage']['S2']
        $coverage['unread'] | Should -Contain 'servicePrincipals'
        $coverage['unread'] | Should -Not -Contain 'users'
    }
}

Describe 'A partial tenant, and the identity matrix' {
    It 'keeps the reason when no draft could be made' {
        $fixture = Get-TcReportFixture -SourceCount 2 -Folder $TestDrive
        Remove-TcReportTable -Snapshot $fixture['Snapshot'] -Role 'S1' -Table 'users'
        $fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $fixture['Snapshot']
        $fixture['Plan'] = New-TcPlan -Project $fixture['Project'] -Snapshot $fixture['Snapshot'] -RuleSet $fixture['RuleSet']
        $identity = (Get-TcReportFixtureData -Fixture $fixture)['Data']['identity']['S1']

        $identity['drafted'] | Should -BeFalse
        $identity['reason'] | Should -Match 'could not be read'
        @($identity['rows']).Count | Should -Be 0
    }

    It 'keeps To review rows and their note when the target was not read' {
        $fixture = Get-TcReportFixture -SourceCount 1 -Folder $TestDrive
        Remove-TcReportTable -Snapshot $fixture['Snapshot'] -Role 'Target' -Table 'users'
        $fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $fixture['Snapshot']
        $fixture['Plan'] = New-TcPlan -Project $fixture['Project'] -Snapshot $fixture['Snapshot'] -RuleSet $fixture['RuleSet']
        $identity = (Get-TcReportFixtureData -Fixture $fixture)['Data']['identity']['S1']

        $identity['drafted'] | Should -BeTrue
        $identity['counts']['Create'] | Should -Be 0
        @($identity['rows'] | Where-Object { $_['Decision'] -eq 'To review' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Products found in a snapshot' {
    BeforeAll {
        $script:Fixture = Get-TcReportFixture -SourceCount 1 -Folder $TestDrive
        $tables = $script:Fixture['Snapshot']['tenants']['S1']['tables']
        $tables['servicePrincipals'] = @($tables['servicePrincipals']) + @([ordered]@{ Name = 'ShareGate Migrate'; AppId = 'x'; Publisher = 'ShareGate'; Origin = 'Third party'; Enabled = $true; Type = 'Application'; Id = 'y' })
        $tables['users'] = @($tables['users']) + @([ordered]@{ Name = 'Avepoint Person'; UPN = 'avepoint@alpine.example'; Type = 'Member' })
        $script:Data = (Get-TcReportFixtureData -Fixture $script:Fixture)['Data']
        $script:Product = { param($Id) @($script:Data['solutions']['products'] | Where-Object { $_['id'] -eq $Id })[0] }
    }

    It 'finds a product in a technical table, with an example' {
        $trace = (& $script:Product 'sharegate')['traces']['S1']
        $trace['total'] | Should -BeGreaterThan 0
        @($trace['tables'] | ForEach-Object { $_[0] }) | Should -Contain 'servicePrincipals'
        $trace['examples'] | Should -Contain 'ShareGate Migrate'
    }

    It 'does not read the name of a person as a product' {
        (& $script:Product 'avepoint')['traces'].Contains('S1') | Should -BeFalse
    }

    It 'says which products are searched, and does not ship the patterns' {
        (& $script:Product 'sharegate')['searched'] | Should -BeTrue
        (& $script:Product 'autopilot')['searched'] | Should -BeFalse
        (& $script:Product 'sharegate').Contains('detection') | Should -BeFalse
    }

    It 'does not change the catalog it reads' {
        InModuleScope TenantConverge { (Get-TcProductCatalog)['products'][0].Contains('traces') } | Should -BeFalse
    }
}

Describe 'A tenant with nothing collected' {
    BeforeAll {
        $script:Fixture = Get-TcReportFixture -SourceCount 2 -Folder $TestDrive
        Clear-TcReportTenant -Snapshot $script:Fixture['Snapshot'] -Role 'S2'
        $script:Fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $script:Fixture['Snapshot']
        $script:Fixture['Plan'] = New-TcPlan -Project $script:Fixture['Project'] -Snapshot $script:Fixture['Snapshot'] -RuleSet $script:Fixture['RuleSet']
        $script:Data = (Get-TcReportFixtureData -Fixture $script:Fixture)['Data']
    }

    It 'says so' {
        @($script:Data['tenants'] | Where-Object { $_['role'] -eq 'S2' })[0]['collection'] | Should -Be 'Nothing'
        @($script:Data['tenants'] | Where-Object { $_['role'] -eq 'S1' })[0]['collection'] | Should -Not -Be 'Nothing'
    }

    It 'keeps every exposure of that tenant empty' {
        foreach ($fact in $script:Data['solutions']['exposureFacts']) { $fact['values']['S2'] | Should -BeNullOrEmpty -Because $fact['id'] }
    }
}

Describe 'A single source with nothing collected' {
    It 'concludes nothing in any exposure line' {
        $fixture = Get-TcReportFixture -SourceCount 1 -Folder $TestDrive
        Clear-TcReportTenant -Snapshot $fixture['Snapshot'] -Role 'S1'
        $fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $fixture['Snapshot']
        $fixture['Plan'] = New-TcPlan -Project $fixture['Project'] -Snapshot $fixture['Snapshot'] -RuleSet $fixture['RuleSet']
        foreach ($fact in (Get-TcReportFixtureData -Fixture $fixture)['Data']['solutions']['exposureFacts']) {
            $fact['tone'] | Should -Be 'gap' -Because $fact['id']
            $fact['text'] | Should -Match 'Not read'
        }
    }
}

Describe 'A source of the project that the snapshot has not reached' {
    It 'keeps the tenant, and says it is absent' {
        $fixture = Get-TcReportFixture -SourceCount 2 -Folder $TestDrive
        $fixture['Snapshot']['tenants'].Remove('S2')
        $fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $fixture['Snapshot']
        $fixture['Plan'] = New-TcPlan -Project $fixture['Project'] -Snapshot $fixture['Snapshot'] -RuleSet $fixture['RuleSet']
        $data = (Get-TcReportFixtureData -Fixture $fixture)['Data']

        @($data['tenants'] | Where-Object { $_['role'] -eq 'S2' })[0]['collection'] | Should -Be 'Absent'
        $data['identity']['S2']['drafted'] | Should -BeFalse
    }
}

Describe 'An empty plan' {
    It 'still gives the report what it needs' {
        $fixture = Get-TcReportFixture -SourceCount 1 -Folder $TestDrive
        $fixture['Plan'] = New-TcEmptyPlan
        $data = (Get-TcReportFixtureData -Fixture $fixture)['Data']
        @($data['actions']).Count | Should -Be 0
        @($data['tasks']).Count | Should -Be 0
        @($data['moments']).Count | Should -Be 6
        @($data['tenants']).Count | Should -Be 2
    }
}

Describe 'Remediations' {
    It 'passes the list on, and reads an action with no key' {
        $fixture = Get-TcReportFixture -SourceCount 1 -Folder $TestDrive
        $fixture['Plan']['remediations'] = Get-TcSyntheticRemediation
        $fixture['Plan']['actions'][0]['remediations'] = @('REM-001')
        $data = (Get-TcReportFixtureData -Fixture $fixture)['Data']
        @($data['remediations']).Count | Should -Be 2
        @($data['actions'][0]['remediations']) | Should -Be 'REM-001'
    }
}

Describe 'Dates' {
    It 'writes a date read from JSON as a date, whatever the language of the computer' {
        $fixture = Get-TcReportFixture -SourceCount 1 -Folder $TestDrive
        $fixture['Snapshot']['meta']['finished'] = [datetime]'2026-01-15T09:05:00'
        $fixture['Snapshot']['meta']['started'] = '2026-01-15T08:00:00'
        $data = (Get-TcReportFixtureData -Fixture $fixture)['Data']
        $data['report']['snapshotFinished'] | Should -Be '2026-01-15 09:05'
        $data['report']['snapshotStarted'] | Should -Be '2026-01-15 08:00'
    }
}

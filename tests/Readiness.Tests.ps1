BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')

    $script:Workloads = 'Entra ID', 'Exchange Online', 'Domains and DNS', 'SharePoint and OneDrive', 'Teams', 'Teams Phone', 'Intune', 'Purview', 'Power Platform', 'Azure', 'Other services'

    function New-TcFullCoverage {
        <# One collector per workload for one role, all OK unless a status is given by workload. #>
        param([string]$Role, [hashtable]$Status = @{})
        foreach ($workload in $script:Workloads) {
            New-TcCoverageLine -Role $Role -Workload $workload -Status ($Status[$workload] ?? 'OK') -Id ($workload -replace '\W', '').ToUpperInvariant()
        }
    }

    function New-TcReadSnapshot {
        <#
        A snapshot where everything was read and nothing is wrong: S1 and the target hold every table,
        empty, plus the few rows that keep the rules quiet. Given adds rows to S1. A status other than OK
        on a workload of S1 takes its tables away, like a failed collector.
        #>
        param([hashtable]$Given = @{}, [hashtable]$Status = @{}, [hashtable]$TargetGiven = @{})
        $dictionary = InModuleScope TenantConverge { Get-TcTableDictionary }
        $quiet = @{
            securitySettings = @(@{ Setting = 'Security defaults enabled'; Value = $true })
            adminRoles       = @(@{ Role = 'Global Administrator'; Assignment = 'Active'; Principal = 'a' }, @{ Role = 'Global Administrator'; Assignment = 'Active'; Principal = 'b' })
        }
        $tables = @{ Target = @{}; S1 = @{} }
        foreach ($role in 'Target', 'S1') {
            foreach ($key in $dictionary.Keys) {
                $collected = $Status[$dictionary[$key]['workload']]
                if ($role -eq 'S1' -and $collected -and $collected -notin 'OK', 'Partial') { continue }
                $tables[$role][$key] = $quiet[$key] ?? @()
            }
        }
        $tables['Target']['crossTenantPartners'] = @(@{ Tenant = 'id-S1' })
        $tables['Target']['organizationRelationships'] = @(@{ Domains = 'alpine.example'; Enabled = $true })
        $tables['Target']['groupSettings'] = @(@{ Setting = 'Group.Unified.EnableGroupCreation'; Value = 'false' })
        foreach ($key in $Given.Keys) { $tables['S1'][$key] = $Given[$key] }
        foreach ($key in $TargetGiven.Keys) { $tables['Target'][$key] = $TargetGiven[$key] }
        New-TcRuleSnapshot -Given $tables -Coverage (@(New-TcFullCoverage 'Target') + @(New-TcFullCoverage 'S1' -Status $Status))
    }

    function Get-TcTenantReadiness {
        param($Snapshot, [string]$Role = 'S1')
        @(Get-TcReadiness -Snapshot $Snapshot) | Where-Object Role -EQ $Role
    }

    function Get-TcWorkloadLine {
        param($Tenant, [string]$Workload)
        $Tenant.Workloads | Where-Object Workload -EQ $Workload
    }

    # Each of these fires a finding of one severity on one workload of S1.
    $script:Severity = @{
        Critical = @{ phoneNumbers = @(@{ Number = '1'; Type = 'DirectRouting'; Assignment = 'Unassigned' }) }
        High     = @{ exchangeSettings = @(@{ Setting = 'Unified audit log enabled'; Value = $false }) }
        Medium   = @{ dlpPolicies = @(@{ Name = 'a'; Enabled = $true; Mode = 'm'; Workloads = 'w' }) }
        Low      = @{ teams = @(@{ Name = 'a'; Archived = $true }) }
    }
}

Describe 'Get-TcReadiness' {
    It 'gives one line per tenant, each with every workload' {
        $lines = @(Get-TcReadiness -Snapshot (New-TcRuleSnapshot -Sources 'S1', 'S2'))
        @($lines.Role) | Should -Be 'Target', 'S1', 'S2'
        foreach ($line in $lines) {
            @($line.Workloads.Workload) | Should -Be $script:Workloads
            $line.Tenant | Should -Not -BeNullOrEmpty
        }
    }

    It 'gives 100 when everything was read and nothing was found' {
        (Get-TcTenantReadiness (New-TcReadSnapshot)).Score | Should -Be 100
    }

    It 'reads <Severity> as <State>, weight <Weight>' -ForEach @(
        @{ Severity = 'Critical'; Workload = 'Teams Phone'; State = 'Blocking'; Weight = 0.0 }
        @{ Severity = 'High'; Workload = 'Exchange Online'; State = 'To address'; Weight = 0.35 }
        @{ Severity = 'Medium'; Workload = 'Purview'; State = 'Secondary'; Weight = 0.7 }
        @{ Severity = 'Low'; Workload = 'Teams'; State = 'Passed'; Weight = 1.0 }
    ) {
        $line = Get-TcWorkloadLine (Get-TcTenantReadiness (New-TcReadSnapshot -Given $script:Severity[$Severity])) $Workload
        $line.State | Should -Be $State
        $line.Weight | Should -Be $Weight
        $line.Credit | Should -Be $Weight
    }

    It 'averages the weights' {
        $given = @{}
        foreach ($set in $script:Severity['Critical'], $script:Severity['High'], $script:Severity['Medium']) { foreach ($key in $set.Keys) { $given[$key] = $set[$key] } }
        $tenant = Get-TcTenantReadiness (New-TcReadSnapshot -Given $given)
        # 8 passed, 1 secondary, 1 to address, 1 blocking: (8 + 0.7 + 0.35 + 0) / 11 = 82.27
        $tenant.Score | Should -Be 82
        $tenant.CollectedScore | Should -Be 82
    }

    It 'rounds a half up, not to the even number' {
        InModuleScope TenantConverge {
            ConvertTo-TcReadinessScore -Sum 1 -Count 8 | Should -Be 13
            ConvertTo-TcReadinessScore -Sum 2.5 -Count 8 | Should -Be 31
            ConvertTo-TcReadinessScore -Sum 0 -Count 0 | Should -Be 0
        }
    }

    It 'counts the workloads by state' {
        $tenant = Get-TcTenantReadiness (New-TcReadSnapshot -Given $script:Severity['Critical'] -Status @{ Azure = 'Insufficient access' })
        $tenant.States['Blocking'] | Should -Be 1
        $tenant.States['Passed'] | Should -Be 9
        $tenant.States['Not collected'] | Should -Be 1
    }

    It 'does not count an Info finding against a workload' {
        $given = @{ secureScore = @(@{ Setting = 'Percentage'; Value = 90 }, @{ Setting = 'Current score'; Value = 90 }, @{ Setting = 'Maximum score'; Value = 100 }) }
        $line = Get-TcWorkloadLine (Get-TcTenantReadiness (New-TcReadSnapshot -Given $given)) 'Other services'
        $line.State | Should -Be 'Passed'
        $line.Findings | Should -Be 1
        $line.Open | Should -Be 0
    }

    It 'counts a comparison finding against the source, never the target' {
        $lines = @(Get-TcReadiness -Snapshot (New-TcReadSnapshot -TargetGiven @{ crossTenantPartners = @() }))
        (Get-TcWorkloadLine ($lines | Where-Object Role -EQ 'S1') 'Entra ID').State | Should -Be 'To address'
        (Get-TcWorkloadLine ($lines | Where-Object Role -EQ 'Target') 'Entra ID').State | Should -Be 'Passed'
    }

    It 'leaves a finding on all tenants out of every tenant' {
        $person = @(@{ Type = 'Member'; Enabled = $true; 'First name' = 'Ana'; 'Last name' = 'Silva'; UPN = 'a@x'; Name = 'Ana Silva' })
        $tenant = Get-TcTenantReadiness (New-TcReadSnapshot -Given @{ users = $person } -TargetGiven @{ users = $person })
        $tenant.Score | Should -Be 100
    }

    It 'can reuse a rule set already computed' {
        $snapshot = New-TcReadSnapshot -Given $script:Severity['Critical']
        $ruleSet = Invoke-TcRuleSet -Snapshot $snapshot
        (@(Get-TcReadiness -Snapshot $snapshot -RuleSet $ruleSet) | Where-Object Role -EQ 'S1').Score | Should -Be (Get-TcTenantReadiness $snapshot).Score
    }
}

Describe 'A service that was not collected never improves the score' {
    It 'gives 0 to a tenant where everything failed' {
        $tenant = Get-TcTenantReadiness (New-TcReadSnapshot -Status @{
                'Entra ID' = 'Failed'; 'Exchange Online' = 'Insufficient access'; 'Domains and DNS' = 'Failed'; 'SharePoint and OneDrive' = 'Insufficient access'; Teams = 'Module missing'
                'Teams Phone' = 'Module missing'; Intune = 'Failed'; Purview = 'Failed'; 'Power Platform' = 'Module missing'; Azure = 'Insufficient access'; 'Other services' = 'Failed'
            })
        $tenant.Score | Should -Be 0
        $tenant.CollectedScore | Should -Be 0
        $tenant.States['Not collected'] | Should -Be 11
        foreach ($line in $tenant.Workloads) {
            $line.State | Should -Be 'Not collected'
            $line.Weight | Should -BeNullOrEmpty
            $line.Credit | Should -Be 0
        }
    }

    It 'gives 0 to a tenant with no coverage line at all' {
        $tenant = Get-TcTenantReadiness (New-TcRuleSnapshot)
        $tenant.Score | Should -Be 0
        $tenant.States['Not collected'] | Should -Be 11
    }

    It 'does not pass a workload no collector ran for' {
        $snapshot = New-TcReadSnapshot
        $snapshot['coverage'] = @($snapshot['coverage'] | Where-Object { -not ($_['role'] -eq 'S1' -and $_['workload'] -eq 'Intune') })
        $tenant = Get-TcTenantReadiness $snapshot
        (Get-TcWorkloadLine $tenant 'Intune').State | Should -Be 'Not collected'
        $tenant.Score | Should -Be 91
    }

    It 'lowers the score when a workload that was passing is lost' {
        (Get-TcTenantReadiness (New-TcReadSnapshot)).Score | Should -Be 100
        (Get-TcTenantReadiness (New-TcReadSnapshot -Status @{ Purview = 'Insufficient access' })).Score | Should -Be 91
    }

    It 'does not reward losing the worst workload, where a plain average would go up' {
        $bad = Get-TcTenantReadiness (New-TcReadSnapshot -Given $script:Severity['Critical'])
        $lost = Get-TcTenantReadiness (New-TcReadSnapshot -Status @{ 'Teams Phone' = 'Module missing' })
        $bad.Score | Should -Be 91
        $lost.Score | Should -BeLessOrEqual $bad.Score
        $lost.CollectedScore | Should -BeGreaterThan $bad.CollectedScore -Because 'the average of what was read goes up, which is why it is not the score'
    }

    It 'gives no credit to a workload whose rule could not read a table' {
        $snapshot = New-TcReadSnapshot
        $snapshot['tenants']['S1']['tables'].Remove('phoneNumbers')
        $line = Get-TcWorkloadLine (Get-TcTenantReadiness $snapshot) 'Teams Phone'
        $line.Complete | Should -BeFalse
        $line.Credit | Should -Be 0
        $line.Unread | Should -Contain 'phoneNumbers'
    }

    It 'keeps the state of the findings and still gives no credit when part of a workload is lost' {
        $snapshot = New-TcReadSnapshot -Given $script:Severity['High']
        $snapshot['tenants']['S1']['tables'].Remove('mailboxes')
        $snapshot['coverage'] = @($snapshot['coverage']) + @(New-TcCoverageLine -Role 'S1' -Workload 'Exchange Online' -Status 'Failed' -Id 'EXO-02')
        $tenant = Get-TcTenantReadiness $snapshot
        $line = Get-TcWorkloadLine $tenant 'Exchange Online'
        $line.State | Should -Be 'To address'
        $line.Coverage | Should -Be 'Partial'
        $line.Credit | Should -Be 0
        $tenant.CollectedScore | Should -BeGreaterThan $tenant.Score
    }

    It 'gives a source no credit for what the target could not show' {
        $snapshot = New-TcReadSnapshot -Given @{ users = @(@{ Type = 'Member'; Enabled = $true; 'License count' = 1; UPN = 'a' }) }
        $snapshot['tenants']['Target']['tables'].Remove('licenses')
        $line = Get-TcWorkloadLine (Get-TcTenantReadiness $snapshot) 'Entra ID'
        $line.Complete | Should -BeFalse
        $line.Unread | Should -Contain 'Target.licenses'
        $line.Credit | Should -Be 0
    }

    It 'treats a service the tenant does not have as out of the count, not as lost' {
        $tenant = Get-TcTenantReadiness (New-TcReadSnapshot -Status @{ Intune = 'License or service missing' })
        $line = Get-TcWorkloadLine $tenant 'Intune'
        $line.State | Should -Be 'Not collected'
        $line.Applicable | Should -BeFalse
        $tenant.Score | Should -Be 100
    }

    It 'gives no credit to a workload whose rules stopped' {
        $snapshot = New-TcReadSnapshot
        $set = Invoke-TcRuleSet -Snapshot $snapshot
        $set['errors'] = @([ordered]@{ role = 'S1'; workload = 'Teams'; message = 'Broken column' })
        $tenant = @(Get-TcReadiness -Snapshot $snapshot -RuleSet $set) | Where-Object Role -EQ 'S1'
        $line = Get-TcWorkloadLine $tenant 'Teams'
        $line.Complete | Should -BeFalse
        $line.Credit | Should -Be 0
        $line.RulesStopped | Should -Be 1
        $tenant.Score | Should -Be 91
    }

    It 'does not touch the same workload of another tenant' {
        $snapshot = New-TcReadSnapshot
        $set = Invoke-TcRuleSet -Snapshot $snapshot
        $set['errors'] = @([ordered]@{ role = 'S1'; workload = 'Teams'; message = 'Broken column' })
        $target = @(Get-TcReadiness -Snapshot $snapshot -RuleSet $set) | Where-Object Role -EQ 'Target'
        (Get-TcWorkloadLine $target 'Teams').Complete | Should -BeTrue
    }

    It 'counts an error that belongs to all tenants against each of them' {
        $snapshot = New-TcReadSnapshot
        $set = Invoke-TcRuleSet -Snapshot $snapshot
        $set['errors'] = @([ordered]@{ role = 'All'; workload = 'Teams'; message = 'Broken gap' })
        foreach ($tenant in @(Get-TcReadiness -Snapshot $snapshot -RuleSet $set)) { (Get-TcWorkloadLine $tenant 'Teams').Complete | Should -BeFalse }
    }

    It 'keeps a partial collector as collected, like the coverage rule' {
        $tenant = Get-TcTenantReadiness (New-TcReadSnapshot -Status @{ Purview = 'Partial' })
        (Get-TcWorkloadLine $tenant 'Purview').Coverage | Should -Be 'Partial'
        $tenant.Score | Should -Be 100
    }

    It 'gives no credit for an empty table of a partial collector' {
        $snapshot = New-TcReadSnapshot
        $producer = (InModuleScope TenantConverge { Get-TcTableDictionary })['phoneNumbers']['collectors'][0]
        $snapshot['coverage'] = @($snapshot['coverage']) + @(New-TcCoverageLine -Role 'S1' -Workload 'Teams Phone' -Status 'Partial' -Id $producer)
        $line = Get-TcWorkloadLine (Get-TcTenantReadiness $snapshot) 'Teams Phone'
        $line.Complete | Should -BeFalse
        $line.Credit | Should -Be 0
        $line.Unread | Should -Contain 'phoneNumbers'
    }

    It 'keeps the credit of a partial collector that returned rows' {
        $snapshot = New-TcReadSnapshot -Given @{ phoneNumbers = @(@{ Number = '1'; Type = 'CallingPlan'; Assignment = 'UserAssigned' }) }
        $producer = (InModuleScope TenantConverge { Get-TcTableDictionary })['phoneNumbers']['collectors'][0]
        $snapshot['coverage'] = @($snapshot['coverage']) + @(New-TcCoverageLine -Role 'S1' -Workload 'Teams Phone' -Status 'Partial' -Id $producer)
        (Get-TcWorkloadLine (Get-TcTenantReadiness $snapshot) 'Teams Phone').Unread | Should -Not -Contain 'phoneNumbers'
    }

    Context 'on a fictional consolidation' {
        BeforeAll {
            $script:Snapshot = Get-TcFakeSnapshot -SourceCount 2 -Folder $TestDrive
            $script:Base = @{}
            foreach ($line in Get-TcReadiness -Snapshot $script:Snapshot) { $script:Base[$line.Role] = $line.Score }
            $script:Collectors = @{}
            foreach ($row in $script:Snapshot['coverage']) { $script:Collectors[$row['id']] = $row['workload'] }

            function Remove-TcCollected {
                <# A copy of the snapshot where the given collectors of a role failed and left no table. #>
                param($Snapshot, [string]$Role, [string[]]$Id)
                $copy = $Snapshot | ConvertTo-Json -Depth 12 | ConvertFrom-Json -AsHashtable
                foreach ($line in $copy['coverage']) {
                    if ($line['role'] -ne $Role -or $line['id'] -notin $Id) { continue }
                    foreach ($table in @($line['tables'])) { [void]$copy['tenants'][$Role]['tables'].Remove($table) }
                    $line['status'] = 'Insufficient access'
                    $line['tables'] = @()
                }
                $copy
            }
        }

        It 'never raises a score when the whole of <Workload> is lost in the target or a source' -ForEach @(
            @{ Workload = 'Entra ID' }, @{ Workload = 'Exchange Online' }, @{ Workload = 'Domains and DNS' }, @{ Workload = 'SharePoint and OneDrive' }, @{ Workload = 'Teams' }, @{ Workload = 'Teams Phone' }
            @{ Workload = 'Intune' }, @{ Workload = 'Purview' }, @{ Workload = 'Power Platform' }, @{ Workload = 'Azure' }, @{ Workload = 'Other services' }
        ) {
            $ids = @($script:Collectors.Keys | Where-Object { $script:Collectors[$_] -eq $Workload })
            foreach ($role in 'Target', 'S1') {
                foreach ($line in Get-TcReadiness -Snapshot (Remove-TcCollected $script:Snapshot $role $ids)) {
                    $line.Score | Should -BeLessOrEqual $script:Base[$line.Role] -Because "$Workload lost in $role must not raise $($line.Role)"
                }
            }
        }
    }
}

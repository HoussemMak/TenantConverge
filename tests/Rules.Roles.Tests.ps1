BeforeDiscovery {
    $script:Counts = @(@{ Count = 1 }, @{ Count = 2 }, @{ Count = 3 })
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')

    $script:AllSources = 'S1', 'S2', 'S3'

    function Get-TcSources { param([int]$Count) @($script:AllSources | Select-Object -First $Count) }

    function Get-TcFinding {
        param($RuleSet, [string]$Id)
        , @($RuleSet['findings'] | Where-Object { $_['id'] -eq $Id })
    }

    function Invoke-TcSameTables {
        <# Gives every source the same tables, plus what the target holds. #>
        param([int]$Count, [hashtable]$Source = @{}, [hashtable]$Target = @{})
        $given = @{ Target = $Target }
        foreach ($role in Get-TcSources $Count) { $given[$role] = $Source }
        Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given -Sources (Get-TcSources $Count))
    }
}

Describe 'Consolidation with <Count> source(s)' -ForEach $script:Counts {
    It 'finds one person across the target and each source' {
        $person = @(@{ Type = 'Member'; Enabled = $true; 'First name' = 'Ana'; 'Last name' = 'Silva'; UPN = 'ana@x.example'; Name = 'Ana Silva' })
        $finding = Get-TcFinding (Invoke-TcSameTables $Count -Source @{ users = $person } -Target @{ users = $person }) 'CON-IDENTITIES'
        $finding.Count | Should -Be 1
        $finding[0]['itemCount'] | Should -Be 1
        ([regex]::Matches($finding[0]['items'][0], '\(ana@x\.example\)')).Count | Should -Be ($Count + 1)
        $finding[0]['code'] | Should -Be 'Consolidation'
        $finding[0]['role'] | Should -Be 'All'
    }

    It 'adds shared mailboxes and aliases over every tenant' {
        $box = @(@{ Type = 'SharedMailbox'; 'Primary address' = 'info@x.example'; Alias = 'info' })
        $result = Invoke-TcSameTables $Count -Source @{ mailboxes = $box } -Target @{ mailboxes = $box }
        (Get-TcFinding $result 'CON-SHARED-MAILBOXES')[0]['itemCount'] | Should -Be 1
        (Get-TcFinding $result 'CON-ALIASES')[0]['itemCount'] | Should -Be 1
    }

    It 'only compares site paths between sources' {
        $sites = @(@{ Url = 'https://x/sites/finance'; Path = '/sites/finance'; 'Storage MB' = 50; 'Days inactive' = 1 })
        $finding = Get-TcFinding (Invoke-TcSameTables $Count -Source @{ sites = $sites }) 'CON-SITES'
        $finding.Count | Should -Be $(if ($Count -ge 2) { 1 } else { 0 })
    }

    It 'adds the capacity, license and voice needs only when there are several sources' {
        $source = @{
            sites = @(@{ Url = 'https://x'; Path = '/'; 'Storage MB' = 1024; 'Days inactive' = 1 })
            users = @(@{ Type = 'Member'; Enabled = $true; 'License count' = 1; UPN = 'a' })
            teamsUsers = @(@{ UPN = 'a'; 'Enterprise Voice' = $true })
        }
        $target = @{
            sharePointSettings = @(@{ Setting = 'StorageQuota'; Value = 1024000 })
            sites = @(@{ Url = 'https://t'; Path = '/'; 'Storage MB' = 1024; 'Days inactive' = 1 })
            licenses = @(@{ SKU = 'E9'; Available = 2; Consumed = 1; Plans = 'MCOEV' })
        }
        $result = Invoke-TcSameTables $Count -Source $source -Target $target
        foreach ($id in 'CON-CAPACITY', 'CON-LICENSES', 'CON-VOICE') {
            (Get-TcFinding $result $id).Count | Should -Be $(if ($Count -ge 2) { 1 } else { 0 }) -Because $id
        }
        if ($Count -ge 2) {
            (Get-TcFinding $result 'CON-LICENSES')[0]['title'] | Should -BeLike "*estimated need $Count, available 2*"
            (Get-TcFinding $result 'CON-LICENSES')[0]['severity'] | Should -Be $(if ($Count -eq 3) { 'High' } else { 'Info' })
            (Get-TcFinding $result 'CON-CAPACITY')[0]['finding'] | Should -BeLike "*Summit 1 GB - Alpine 1 GB*"
            (Get-TcFinding $result 'CON-VOICE')[0]['title'] | Should -BeLike "*$Count voice user(s)*"
        }
    }

    It 'lists the domains of every source, and only those' {
        $finding = Get-TcFinding (Invoke-TcSameTables $Count) 'CON-DOMAINS'
        $finding[0]['itemCount'] | Should -Be $Count
        $finding[0]['title'] | Should -BeLike "*from $Count source(s)*"
    }

    It 'compares each source with the target, under its own code' {
        $box = @(@{ Type = 'SharedMailbox'; 'Primary address' = 'info@x.example'; Alias = 'info' })
        $result = Invoke-TcSameTables $Count -Source @{ mailboxes = $box } -Target @{ mailboxes = $box; organizationRelationships = @() }
        $codes = @((Get-TcFinding $result 'CMP-SHARED-MAILBOXES') | ForEach-Object { $_['code'] })
        $codes | Should -Be (Get-TcSources $Count)
        @((Get-TcFinding $result 'CMP-FREE-BUSY') | ForEach-Object { $_['code'] }) | Should -Be (Get-TcSources $Count)
    }

    It 'turns a setting gap between sources into CON-SETTINGS only with several sources' {
        $given = @{ Target = @{ sharePointSettings = @(@{ Setting = 'SharingCapability'; Value = 'a' }) } }
        $values = 'b', 'c', 'd'
        foreach ($i in 0..($Count - 1)) { $given[$script:AllSources[$i]] = @{ sharePointSettings = @(@{ Setting = 'SharingCapability'; Value = $values[$i] }) } }
        $result = Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given -Sources (Get-TcSources $Count))
        (Get-TcFinding $result 'CON-SETTINGS').Count | Should -Be $(if ($Count -ge 2) { 1 } else { 0 })
        (Get-TcFinding $result 'CMP-SETTINGS').Count | Should -Be $Count
    }

    It 'keeps measures to the tenants of the project' {
        $given = @{ Target = @{ users = @() } }
        foreach ($role in Get-TcSources $Count) { $given[$role] = @{ users = @(@{ Type = 'Member'; Enabled = $true }) } }
        $line = (Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given -Sources (Get-TcSources $Count)))['measures'] | Where-Object { $_['label'] -eq 'Active member accounts' }
        @($line['values'].Keys) | Should -Be (@('Target') + (Get-TcSources $Count))
        $line['sources'] | Should -Be $Count
        $line['after'] | Should -Be $Count
    }
}

Describe 'Consolidation totals that miss a source' {
    BeforeAll {
        $script:Sites = @(@{ Url = 'https://x'; Path = '/'; 'Storage MB' = 1024; 'Days inactive' = 1 })
        $script:Users = @(@{ Type = 'Member'; Enabled = $true; 'License count' = 1; UPN = 'a' })
        $script:Voice = @(@{ UPN = 'a'; 'Enterprise Voice' = $true })
        $script:Target = @{
            sharePointSettings = @(@{ Setting = 'StorageQuota'; Value = 1024000 })
            sites = @(@{ Url = 'https://t'; Path = '/'; 'Storage MB' = 1024; 'Days inactive' = 1 })
            licenses = @(@{ SKU = 'E9'; Available = 100; Consumed = 1; Plans = 'MCOEV' })
        }

        function Invoke-TcTwoSources {
            <# S1 holds every table it is given, S2 only those of its own list. #>
            param([hashtable]$First = @{}, [hashtable]$Second = @{}, [hashtable]$Target = $script:Target, [object[]]$Coverage = @())
            Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given @{ Target = $Target; S1 = $First; S2 = $Second } -Sources 'S1', 'S2' -Coverage $Coverage)
        }

        $script:Full = @{ sites = $script:Sites; users = $script:Users; teamsUsers = $script:Voice; phoneNumbers = @() }
    }

    It 'concludes on capacity and licenses when every tenant was read' {
        $result = Invoke-TcTwoSources -First $script:Full -Second $script:Full
        (Get-TcFinding $result 'CON-CAPACITY')[0]['action'] | Should -Match 'Enough capacity'
        (Get-TcFinding $result 'CON-LICENSES')[0]['action'] | Should -Match 'Enough licenses'
        (Get-TcFinding $result 'CON-VOICE')[0]['severity'] | Should -Be 'Info'
    }

    It 'does not state that capacity is enough when a source was not read, and names it' {
        $second = @{ users = $script:Users; teamsUsers = $script:Voice; phoneNumbers = @() }
        $finding = (Get-TcFinding (Invoke-TcTwoSources -First $script:Full -Second $second) 'CON-CAPACITY')[0]
        $finding['action'] | Should -Not -Match 'Enough'
        $finding['action'] | Should -Match 'Birch'
        $finding['title'] | Should -Match 'at least'
        $finding['finding'] | Should -Match 'Birch not read'
        $finding['finding'] | Should -Not -Match 'Birch 0 GB'
        $finding['severity'] | Should -Be 'Medium'
    }

    It 'counts the sites of the target among what was not read' {
        $target = @{ sharePointSettings = $script:Target['sharePointSettings']; licenses = $script:Target['licenses'] }
        $finding = (Get-TcFinding (Invoke-TcTwoSources -First $script:Full -Second $script:Full -Target $target) 'CON-CAPACITY')[0]
        $finding['finding'] | Should -Match 'Summit not read'
        $finding['action'] | Should -Not -Match 'Enough'
    }

    It 'keeps a shortage that is already certain, as a minimum' {
        $target = @{ sharePointSettings = @(@{ Setting = 'StorageQuota'; Value = 100 }); sites = $script:Target['sites']; licenses = $script:Target['licenses'] }
        $finding = (Get-TcFinding (Invoke-TcTwoSources -First $script:Full -Second @{ users = $script:Users } -Target $target) 'CON-CAPACITY')[0]
        $finding['severity'] | Should -Be 'Critical'
        $finding['action'] | Should -Match 'At least'
        $finding['action'] | Should -Match 'Birch'
    }

    It 'does not state that licenses are enough when a source was not read, and names it' {
        $finding = (Get-TcFinding (Invoke-TcTwoSources -First $script:Full -Second @{ sites = $script:Sites }) 'CON-LICENSES')[0]
        $finding['action'] | Should -Not -Match 'Enough'
        $finding['action'] | Should -Match 'Birch'
        $finding['title'] | Should -Match 'at least 1'
        $finding['finding'] | Should -Match 'Birch not read'
        $finding['finding'] | Should -Not -Match 'Birch 0'
        $finding['severity'] | Should -Be 'Medium'
    }

    It 'keeps a license shortage that is already certain, as a minimum' {
        $target = @{ sharePointSettings = $script:Target['sharePointSettings']; sites = $script:Target['sites']; licenses = @(@{ SKU = 'E9'; Available = 0; Consumed = 1; Plans = 'MCOEV' }) }
        $finding = (Get-TcFinding (Invoke-TcTwoSources -First $script:Full -Second @{ sites = $script:Sites } -Target $target) 'CON-LICENSES')[0]
        $finding['severity'] | Should -Be 'High'
        $finding['action'] | Should -Match 'at least 1'
        $finding['action'] | Should -Match 'Birch'
    }

    It 'does not ask to buy licenses when those of the target were not read' {
        $target = @{ sharePointSettings = $script:Target['sharePointSettings']; sites = $script:Target['sites'] }
        $finding = (Get-TcFinding (Invoke-TcTwoSources -First $script:Full -Second $script:Full -Target $target) 'CON-LICENSES')[0]
        $finding['action'] | Should -Not -Match 'Plan to buy'
        $finding['action'] | Should -Match 'Summit'
        $finding['title'] | Should -Match 'available unknown'
        $finding['title'] | Should -Not -Match '^ '
    }

    It 'says which source is unknown even when the others need nothing' {
        $first = @{ sites = $script:Sites; users = @(); teamsUsers = @(); phoneNumbers = @() }
        $finding = (Get-TcFinding (Invoke-TcTwoSources -First $first -Second @{ sites = $script:Sites }) 'CON-LICENSES')[0]
        $finding['finding'] | Should -Match 'Birch not read'
    }

    It 'does not close the voice count on a source that was not read' {
        $finding = (Get-TcFinding (Invoke-TcTwoSources -First $script:Full -Second @{ sites = $script:Sites; users = $script:Users }) 'CON-VOICE')[0]
        $finding['severity'] | Should -Be 'Medium'
        $finding['title'] | Should -Match 'at least 1 voice'
        $finding['finding'] | Should -Match 'Birch not read'
        $finding['finding'] | Should -Not -Match 'Birch 0'
    }

    It 'does not call a voice shortage when the licenses of the target were not read' {
        $target = @{ sharePointSettings = $script:Target['sharePointSettings']; sites = $script:Target['sites'] }
        $finding = (Get-TcFinding (Invoke-TcTwoSources -First $script:Full -Second $script:Full -Target $target) 'CON-VOICE')[0]
        $finding['severity'] | Should -Be 'Medium'
        $finding['finding'] | Should -Match 'unknown'
    }

    It 'does not conclude on an empty table of a partial collector' {
        $producer = (InModuleScope TenantConverge { Get-TcTableDictionary })['users']['collectors'][0]
        $coverage = @(New-TcCoverageLine -Role 'S2' -Workload 'Entra ID' -Id $producer -Status 'Partial')
        $second = @{ sites = $script:Sites; users = @(); teamsUsers = $script:Voice; phoneNumbers = @() }
        $finding = (Get-TcFinding (Invoke-TcTwoSources -First $script:Full -Second $second -Coverage $coverage) 'CON-LICENSES')[0]
        $finding['action'] | Should -Not -Match 'Enough'
        $finding['finding'] | Should -Match 'Birch not read'
    }

    It 'still concludes when a source simply does not have the service' {
        $producer = (InModuleScope TenantConverge { Get-TcTableDictionary })['sites']['collectors'][0]
        $coverage = @(New-TcCoverageLine -Role 'S2' -Workload 'SharePoint and OneDrive' -Id $producer -Status 'License or service missing')
        $second = @{ users = $script:Users; teamsUsers = $script:Voice; phoneNumbers = @() }
        $finding = (Get-TcFinding (Invoke-TcTwoSources -First $script:Full -Second $second -Coverage $coverage) 'CON-CAPACITY')[0]
        $finding['action'] | Should -Match 'Enough capacity'
    }
}

Describe 'A fictional consolidation with <Count> source(s)' -ForEach $script:Counts {
    BeforeAll {
        $script:Snapshot = Get-TcFakeSnapshot -SourceCount $Count -Folder $TestDrive
        $script:Result = Invoke-TcRuleSet -Snapshot $script:Snapshot
        $script:Roles = @('Target') + (Get-TcSources $Count)
    }

    It 'runs every rule without an error' {
        $script:Result['errors'] | Should -BeNullOrEmpty
    }

    It 'names only the roles of the project' {
        foreach ($finding in $script:Result['findings']) { $finding['code'] | Should -BeIn ($script:Roles + 'Consolidation') }
    }

    It 'leaves no placeholder unfilled' {
        foreach ($finding in $script:Result['findings']) {
            "$($finding['title']) $($finding['finding']) $($finding['action'])" | Should -Not -Match '[{}]' -Because $finding['id']
        }
    }

    It 'writes no blank where a tenant name belongs' {
        foreach ($finding in $script:Result['findings']) { $finding['tenant'] | Should -Not -BeNullOrEmpty }
    }

    It 'runs the comparison rules once per source at most' {
        $groups = @($script:Result['findings'] | Where-Object { $_['id'] -like 'CMP-*' } | Group-Object { "$($_['id'])|$($_['code'])" })
        $groups | Where-Object Count -GT 1 | Should -BeNullOrEmpty
    }
}

Describe 'Tenants that are not there' {
    It 'works on sources with a gap in their numbers' {
        $given = @{ S1 = @{ teamsUsers = @() }; S3 = @{ users = @(@{ Type = 'Guest'; UPN = 'g' }) } }
        $result = Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given $given -Sources 'S1', 'S3')
        $result['errors'] | Should -BeNullOrEmpty
        (Get-TcFinding $result 'ENT-GUESTS')[0]['code'] | Should -Be 'S3'
        (Get-TcFinding $result 'CON-DOMAINS')[0]['title'] | Should -BeLike '*from 2 source(s)*'
    }

    It 'runs on the target alone, with nothing to compare' {
        $result = Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Sources @() -Given @{ Target = @{ riskyUsers = @(@{ UPN = 'a'; Level = 'high'; State = 'atRisk' }) } })
        $result['errors'] | Should -BeNullOrEmpty
        @($result['findings'] | ForEach-Object { $_['id'] }) | Should -Be 'ENT-RISK'
    }

    It 'runs on a source when the target was left out of the run' {
        $snapshot = New-TcRuleSnapshot -Given @{ S1 = @{ riskyUsers = @(@{ UPN = 'a'; Level = 'high'; State = 'atRisk' }) } }
        $snapshot['tenants'].Remove('Target')
        $result = Invoke-TcRuleSet -Snapshot $snapshot
        $result['errors'] | Should -BeNullOrEmpty
        @($result['findings'] | Where-Object { $_['id'] -like 'CMP-*' }) | Should -BeNullOrEmpty
        (Get-TcFinding $result 'ENT-RISK')[0]['tenant'] | Should -Be 'Alpine'
    }

    It 'uses the role when a tenant has no name' {
        $snapshot = New-TcRuleSnapshot -Given @{ S1 = @{ riskyUsers = @(@{ UPN = 'a'; Level = 'high'; State = 'atRisk' }) } }
        $snapshot['tenants']['S1'].Remove('displayName')
        (Get-TcFinding (Invoke-TcRuleSet -Snapshot $snapshot) 'ENT-RISK')[0]['tenant'] | Should -Be 'S1'
    }
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    $script:Tool = Join-Path $PSScriptRoot '../tools/New-TcFakeSnapshot.ps1'
    $script:Dictionary = Get-Content (Join-Path $PSScriptRoot '../src/TenantConverge/Data/tables.json') -Raw | ConvertFrom-Json -AsHashtable

    function New-TcSampleSnapshot {
        [ordered]@{
            schemaVersion = 1
            meta          = [ordered]@{ project = 'Summit'; started = '2026-01-15T08:00:00'; finished = '2026-01-15T09:00:00'; moduleVersion = '0.1.0'; depth = 'Complete' }
            coverage      = @(
                [ordered]@{ role = 'S1'; tenant = 'Alpine Group'; id = 'ENT-01'; workload = 'Entra ID'; title = 'Organization'; service = 'Microsoft Graph'; status = 'OK'; message = ''; remedy = ''; duration = 1.5; rows = 1; tables = @('domains') }
            )
            tenants       = [ordered]@{
                Target = [ordered]@{ displayName = 'Summit Holdings'; primaryDomain = 'summit.example'; tenantId = 'id-1'; tables = [ordered]@{} }
                S1     = [ordered]@{ displayName = 'Alpine Group'; primaryDomain = 'alpine.example'; tenantId = 'id-2'; tables = [ordered]@{ domains = @([ordered]@{ Domain = 'alpine.example'; Verified = $true }) } }
            }
        }
    }
}

Describe 'Table dictionary' {
    It 'lists every table of the old inventory' {
        @($Dictionary.tables).Count | Should -Be 111
    }

    It 'gives every table a camelCase key, a label, a workload and columns' {
        $workloads = 'Entra ID', 'Exchange Online', 'SharePoint and OneDrive', 'Teams', 'Teams Phone', 'Intune', 'Purview', 'Power Platform', 'Azure', 'Domains and DNS', 'Other services'
        foreach ($table in $Dictionary.tables) {
            $table.key | Should -MatchExactly '^[a-z][A-Za-z0-9]+$'
            $table.label | Should -Not -BeNullOrEmpty
            $table.workload | Should -BeIn $workloads
            @($table.columns).Count | Should -BeGreaterThan 0 -Because $table.key
            @($table.collectors).Count | Should -BeGreaterThan 0 -Because $table.key
        }
    }

    It 'uses each key once and each column once per table' {
        @($Dictionary.tables.key | Group-Object | Where-Object Count -GT 1) | Should -BeNullOrEmpty
        foreach ($table in $Dictionary.tables) {
            @($table.columns | Group-Object | Where-Object Count -GT 1) | Should -BeNullOrEmpty -Because $table.key
        }
    }

    It 'names the examples of the conventions' {
        ($Dictionary.tables | Where-Object key -EQ 'users').columns | Should -Contain 'Last name'
        ($Dictionary.tables | Where-Object key -EQ 'users').columns | Should -Contain 'AD anchor'
        @($Dictionary.tables.key) | Should -Contain 'organizationSettings'
        @($Dictionary.tables.key) | Should -Contain 'domains'
    }

    It 'is plain English text' {
        (Get-Content (Join-Path $PSScriptRoot '../src/TenantConverge/Data/tables.json') -Raw) | Should -Not -Match '[^\x00-\x7F]'
    }
}

Describe 'Snapshot format' {
    It 'writes and reads a snapshot' {
        $path = Join-Path $TestDrive 'snapshot.json'
        InModuleScope TenantConverge -Parameters @{ Path = $path; Snapshot = (New-TcSampleSnapshot) } {
            param($Path, $Snapshot)
            Write-TcSnapshot -Path $Path -Snapshot $Snapshot
            $read = Read-TcSnapshot -Path $Path
            $read['schemaVersion'] | Should -Be 1
            $read['meta']['project'] | Should -Be 'Summit'
            @($read['tenants'].Keys) | Should -Be @('Target', 'S1')
            @($read['tenants']['S1']['tables']['domains'])[0]['Domain'] | Should -Be 'alpine.example'
            $read['coverage'][0]['status'] | Should -Be 'OK'
        }
    }

    It 'keeps accented names and a single row as a list' {
        $path = Join-Path $TestDrive 'accents.json'
        $snapshot = New-TcSampleSnapshot
        $snapshot.tenants.S1.displayName = 'Société Générale de Québec'
        InModuleScope TenantConverge -Parameters @{ Path = $path; Snapshot = $snapshot } {
            param($Path, $Snapshot)
            Write-TcSnapshot -Path $Path -Snapshot $Snapshot
            (Read-TcSnapshot -Path $Path)['tenants']['S1']['displayName'] | Should -Be 'Société Générale de Québec'
        }
        (Get-Content $path -Raw) | Should -Match '"domains":\s*\['
    }

    It 'accepts a valid snapshot' {
        InModuleScope TenantConverge -Parameters @{ Snapshot = (New-TcSampleSnapshot) } {
            param($Snapshot)
            @(Test-TcSnapshot -Snapshot $Snapshot) | Should -BeNullOrEmpty
        }
    }

    It 'refuses to write a snapshot that breaks the format' {
        $snapshot = New-TcSampleSnapshot
        $snapshot.tenants.S1.tables['inventedTable'] = @()
        $path = Join-Path $TestDrive 'bad.json'
        InModuleScope TenantConverge -Parameters @{ Path = $path; Snapshot = $snapshot } {
            param($Path, $Snapshot)
            { Write-TcSnapshot -Path $Path -Snapshot $Snapshot } | Should -Throw '*inventedTable*'
        }
        Test-Path $path | Should -BeFalse
    }

    It 'finds what breaks the format' -TestCases @(
        @{ Name = 'an unknown table'; Change = { param($s) $s.tenants.S1.tables['inventedTable'] = @() }; Expected = 'TC2004' }
        @{ Name = 'an unknown column'; Change = { param($s) $s.tenants.S1.tables.domains[0]['Invented'] = 1 }; Expected = 'TC2005' }
        @{ Name = 'an unknown role'; Change = { param($s) $s.tenants['S4'] = $s.tenants.S1 }; Expected = 'TC2003' }
        @{ Name = 'a missing target'; Change = { param($s) $s.tenants.Remove('Target') }; Expected = 'TC2003' }
        @{ Name = 'another schema version'; Change = { param($s) $s.schemaVersion = 2 }; Expected = 'TC2001' }
        @{ Name = 'a missing meta key'; Change = { param($s) $s.meta.Remove('depth') }; Expected = 'TC2002' }
        @{ Name = 'an unknown coverage status'; Change = { param($s) $s.coverage[0]['status'] = 'Partiel' }; Expected = 'TC2006' }
        @{ Name = 'a missing coverage key'; Change = { param($s) $s.coverage[0].Remove('remedy') }; Expected = 'TC2006' }
    ) {
        $snapshot = New-TcSampleSnapshot
        & $Change $snapshot
        $codes = InModuleScope TenantConverge -Parameters @{ Snapshot = $snapshot } {
            param($Snapshot)
            @(Test-TcSnapshot -Snapshot $Snapshot).Code
        }
        $codes | Should -Contain $Expected
    }

    It 'refuses to read another schema version' {
        $path = Join-Path $TestDrive 'future.json'
        '{"schemaVersion": 2}' | Set-Content -LiteralPath $path
        InModuleScope TenantConverge -Parameters @{ Path = $path } {
            param($Path)
            { Read-TcSnapshot -Path $Path } | Should -Throw '*schema version 2*'
        }
    }
}

Describe 'Table state' {
    BeforeAll {
        function Get-State {
            param($Snapshot, [string]$Role, [string]$Table)
            InModuleScope TenantConverge -Parameters @{ Snapshot = $Snapshot; Role = $Role; Table = $Table } {
                param($Snapshot, $Role, $Table)
                Get-TcTableState -Snapshot $Snapshot -Role $Role -Table $Table
            }
        }
    }

    It 'says Collected for a table with rows' {
        (Get-State (New-TcSampleSnapshot) 'S1' 'domains').State | Should -Be 'Collected'
    }

    It 'says NotUsed for a collected table with no row' {
        $snapshot = New-TcSampleSnapshot
        $snapshot.tenants.S1.tables['phoneNumbers'] = @()
        (Get-State $snapshot 'S1' 'phoneNumbers').State | Should -Be 'NotUsed'
    }

    It 'says NotFullyRead for an empty table of a Partial collector, with its reason' {
        $snapshot = New-TcSampleSnapshot
        $snapshot.tenants.S1.tables['phoneNumbers'] = @()
        $snapshot.coverage += [ordered]@{
            role = 'S1'; tenant = 'Alpine Group'; id = 'TEL-01'; workload = 'Teams Phone'; title = 'Numbers'; service = 'Microsoft Teams'
            status = 'Partial'; message = 'Limit reached'; remedy = 'Review by hand'; duration = 0; rows = 0; tables = @('phoneNumbers')
        }
        $state = Get-State $snapshot 'S1' 'phoneNumbers'
        $state.State | Should -Be 'NotFullyRead'
        $state.Status | Should -Be 'Partial'
        $state.Message | Should -Be 'Limit reached'
        $state.Remedy | Should -Be 'Review by hand'
    }

    It 'keeps a Partial collector that returned rows as collected' {
        $snapshot = New-TcSampleSnapshot
        $snapshot.coverage += [ordered]@{
            role = 'S1'; tenant = 'Alpine Group'; id = 'ENT-01'; workload = 'Entra ID'; title = 'Domains'; service = 'Microsoft Graph'
            status = 'Partial'; message = 'Part refused'; remedy = 'Grant a role'; duration = 0; rows = 1; tables = @('domains')
        }
        (Get-State $snapshot 'S1' 'domains').State | Should -Be 'Collected'
    }

    It 'does not read a Partial collector of another tenant' {
        $snapshot = New-TcSampleSnapshot
        $snapshot.tenants.S1.tables['phoneNumbers'] = @()
        $snapshot.coverage += [ordered]@{
            role = 'Target'; tenant = 'Summit'; id = 'TEL-01'; workload = 'Teams Phone'; title = 'Numbers'; service = 'Microsoft Teams'
            status = 'Partial'; message = 'Limit reached'; remedy = 'Review by hand'; duration = 0; rows = 0; tables = @('phoneNumbers')
        }
        (Get-State $snapshot 'S1' 'phoneNumbers').State | Should -Be 'NotUsed'
    }

    It 'says NotCollected with the reason of the collector for a missing table' {
        $snapshot = New-TcSampleSnapshot
        $snapshot.coverage += [ordered]@{
            role = 'S1'; tenant = 'Alpine Group'; id = 'TEL-01'; workload = 'Teams Phone'; title = 'Numbers'; service = 'Microsoft Teams'
            status = 'Insufficient access'; message = 'Forbidden'; remedy = 'Grant a role'; duration = 0; rows = 0; tables = @()
        }
        $state = Get-State $snapshot 'S1' 'phoneNumbers'
        $state.State | Should -Be 'NotCollected'
        $state.Status | Should -Be 'Insufficient access'
        $state.Remedy | Should -Be 'Grant a role'
    }

    It 'says NotCollected for a collector that never ran' {
        $state = Get-State (New-TcSampleSnapshot) 'S1' 'phoneNumbers'
        $state.State | Should -Be 'NotCollected'
        $state.Status | Should -Be 'Not run'
    }
}

Describe 'New-TcFakeSnapshot' {
    BeforeAll {
        function Get-Fake {
            param([int]$SourceCount, [int]$Seed)
            $path = Join-Path $TestDrive "fake-$SourceCount-$Seed.json"
            if (-not (Test-Path $path)) { & $script:Tool -SourceCount $SourceCount -Seed $Seed -Path $path | Out-Null }
            Get-Content $path -Raw | ConvertFrom-Json -AsHashtable -Depth 50
        }
        $script:Fake = Get-Fake 3 42
    }

    It 'gives the same bytes for the same seed' {
        $first = Join-Path $TestDrive 'first.json'
        $second = Join-Path $TestDrive 'second.json'
        & $script:Tool -SourceCount 2 -Seed 7 -Path $first | Out-Null
        & $script:Tool -SourceCount 2 -Seed 7 -Path $second | Out-Null
        (Get-FileHash $first).Hash | Should -Be (Get-FileHash $second).Hash
    }

    It 'gives other data for another seed' {
        $first = Join-Path $TestDrive 'seed1.json'
        $second = Join-Path $TestDrive 'seed2.json'
        & $script:Tool -SourceCount 1 -Seed 1 -Path $first | Out-Null
        & $script:Tool -SourceCount 1 -Seed 2 -Path $second | Out-Null
        (Get-FileHash $first).Hash | Should -Not -Be (Get-FileHash $second).Hash
    }

    It 'builds 1, 2 and 3 sources' -TestCases @(
        @{ Count = 1; Roles = @('Target', 'S1') }
        @{ Count = 2; Roles = @('Target', 'S1', 'S2') }
        @{ Count = 3; Roles = @('Target', 'S1', 'S2', 'S3') }
    ) {
        @((Get-Fake $Count 42).tenants.Keys) | Should -Be $Roles
    }

    It 'refuses any other number of sources' -TestCases @(@{ Count = 0 }, @{ Count = 4 }) {
        { & $script:Tool -SourceCount $Count -Seed 1 -Path (Join-Path $TestDrive 'no.json') } | Should -Throw
    }

    It 'respects the snapshot format' -TestCases @(@{ Count = 1 }, @{ Count = 2 }, @{ Count = 3 }) {
        $snapshot = Get-Fake $Count 42
        InModuleScope TenantConverge -Parameters @{ Snapshot = $snapshot } {
            param($Snapshot)
            @(Test-TcSnapshot -Snapshot $Snapshot) | Should -BeNullOrEmpty
        }
    }

    It 'stays on reserved example domains' {
        $text = Get-Content (Join-Path $TestDrive 'fake-3-42.json') -Raw
        foreach ($match in [regex]::Matches($text, '@([a-z0-9.-]+\.[a-z]{2,})')) {
            $match.Groups[1].Value | Should -Match '\.example$|\.onmicrosoft\.com$' -Because 'addresses must be fictional'
        }
        foreach ($tenant in $Fake.tenants.Values) { $tenant.primaryDomain | Should -Match '\.example$' }
    }

    It 'fills every table of the dictionary somewhere' {
        $filled = foreach ($tenant in $Fake.tenants.Values) {
            foreach ($key in $tenant.tables.Keys) { if (@($tenant.tables[$key]).Count) { $key } }
        }
        @($Dictionary.tables.key | Where-Object { $_ -notin $filled }) | Should -BeNullOrEmpty
    }

    It 'gives every row the columns of the dictionary' {
        $columns = @{}
        foreach ($table in $Dictionary.tables) { $columns[$table.key] = @($table.columns) }
        foreach ($tenant in $Fake.tenants.Values) {
            foreach ($key in $tenant.tables.Keys) {
                foreach ($row in @($tenant.tables[$key]) | Select-Object -First 1) {
                    @($columns[$key] | Where-Object { $_ -notin $row.Keys }) | Should -BeNullOrEmpty -Because $key
                }
            }
        }
    }

    It 'has a coverage line for each collector of each tenant' {
        foreach ($role in $Fake.tenants.Keys) {
            @($Fake.coverage | Where-Object role -EQ $role).Count | Should -Be 56 -Because $role
        }
    }

    It 'shows a service that is not used apart from one that was not collected' {
        $s2 = $Fake.tenants.S2.tables
        $s2.Contains('phoneNumbers') | Should -BeTrue
        @($s2.phoneNumbers).Count | Should -Be 0
        $s1 = $Fake.tenants.S1.tables
        $s1.Contains('powerEnvironments') | Should -BeFalse
        ($Fake.coverage | Where-Object { $_.role -eq 'S1' -and $_.id -eq 'POW-01' }).status | Should -Be 'Insufficient access'
    }

    It 'has accented and very long names' {
        $names = @($Fake.tenants.S1.tables.users.Name)
        @($names -match '[^\x00-\x7F]').Count | Should -BeGreaterThan 0
        @($names | Where-Object { $_.Length -gt 64 }).Count | Should -BeGreaterThan 0
    }

    It 'has the cases the rules look for' -TestCases @(
        @{ Why = 'inactive members'; Table = 'users'; Test = { $_.Type -eq 'Member' -and $_.Enabled -and [int]$_.'Days inactive' -ge 90 -and [int]$_.'Days since creation' -ge 90 } }
        @{ Why = 'members who never signed in'; Table = 'users'; Test = { $_.Type -eq 'Member' -and [int]$_.'Days inactive' -eq -1 } }
        @{ Why = 'disabled accounts with licenses'; Table = 'users'; Test = { -not $_.Enabled -and $_.'License count' -gt 0 } }
        @{ Why = 'guests who did not accept'; Table = 'users'; Test = { $_.Type -eq 'Guest' -and $_.'Invitation state' -eq 'PendingAcceptance' } }
        @{ Why = 'license errors'; Table = 'users'; Test = { $_.'License errors' -gt 0 } }
        @{ Why = 'global admins'; Table = 'adminRoles'; Test = { $_.Role -eq 'Global Administrator' -and $_.Assignment -eq 'Active' } }
        @{ Why = 'a report-only policy'; Table = 'conditionalAccess'; Test = { $_.State -eq 'enabledForReportingButNotEnforced' } }
        @{ Why = 'expiring secrets'; Table = 'applications'; Test = { $null -ne $_.'Days to expiry' -and $_.'Days to expiry' -le 60 } }
        @{ Why = 'third-party apps'; Table = 'servicePrincipals'; Test = { $_.Origin -eq 'Third party' } }
        @{ Why = 'admin consents'; Table = 'delegatedConsents'; Test = { $_.'Consent type' -like 'Administrator*' } }
        @{ Why = 'phone licenses'; Table = 'licenses'; Test = { $_.Plans -match 'MCOEV' } }
        @{ Why = 'Copilot licenses'; Table = 'licenses'; Test = { $_.SKU -match '(?i)copilot' } }
        @{ Why = 'forwarding'; Table = 'mailboxes'; Test = { $_.'SMTP forwarding' } }
        @{ Why = 'litigation holds'; Table = 'mailboxes'; Test = { $_.'Litigation hold' } }
        @{ Why = 'shared mailboxes'; Table = 'mailboxes'; Test = { $_.Type -eq 'SharedMailbox' } }
        @{ Why = 'rooms'; Table = 'mailboxes'; Test = { $_.Type -eq 'RoomMailbox' } }
        @{ Why = 'big mailboxes'; Table = 'mailboxUsage'; Test = { $_.'Size GB' -ge 45 } }
        @{ Why = 'open auto-forward'; Table = 'remoteDomains'; Test = { $_.Domain -eq '*' -and $_.'Auto-forward' } }
        @{ Why = 'classic sites'; Table = 'sites'; Test = { $_.Template -match '^STS#0' } }
        @{ Why = 'open sharing'; Table = 'sites'; Test = { $_.Sharing -eq 'ExternalUserAndGuestSharing' } }
        @{ Why = 'stale sites'; Table = 'sites'; Test = { $_.'Days inactive' -ge 365 } }
        @{ Why = 'big sites'; Table = 'sites'; Test = { $_.'Storage MB' -ge 102400 } }
        @{ Why = 'custom scripts'; Table = 'sites'; Test = { $_.'Custom scripts' } }
        @{ Why = 'teams with one owner'; Table = 'teamComposition'; Test = { $_.Owners -le 1 } }
        @{ Why = 'private channels'; Table = 'teamComposition'; Test = { $_.'Private channels' -gt 0 } }
        @{ Why = 'custom Teams policies'; Table = 'teamsPolicies'; Test = { $_.Custom } }
        @{ Why = 'voice users'; Table = 'teamsUsers'; Test = { $_.'Enterprise Voice' } }
        @{ Why = 'noncompliant devices'; Table = 'managedDevices'; Test = { $_.Compliance -eq 'noncompliant' } }
        @{ Why = 'expiring Apple tokens'; Table = 'intuneConnectors'; Test = { $_.'Days remaining' -le 45 } }
        @{ Why = 'encrypted labels'; Table = 'sensitivityLabels'; Test = { $_.Encryption } }
        @{ Why = 'open eDiscovery cases'; Table = 'ediscoveryCases'; Test = { $_.Status -ne 'Closed' } }
        @{ Why = 'virtual desktops'; Table = 'azureResources'; Test = { $_.Type -match '(?i)DesktopVirtualization' } }
        @{ Why = 'foreign sign-ins'; Table = 'signInSummary'; Test = { $_.Dimension -eq 'Country' -and $_.Value -notin 'CA', 'US', '(empty)' } }
        @{ Why = 'legacy protocols'; Table = 'mailboxProtocols'; Test = { $_.POP -or $_.IMAP } }
        @{ Why = 'authenticated SMTP'; Table = 'mailboxProtocols'; Test = { $_.'Authenticated SMTP' -eq $true } }
        @{ Why = 'external inbox rules'; Table = 'inboxRules'; Test = { $_.External } }
        @{ Why = 'a third-party mail gateway'; Table = 'dnsSummary'; Test = { $_.'Inbound mail flow' -eq 'Third-party gateway' } }
        @{ Why = 'missing SPF'; Table = 'dnsSummary'; Test = { $_.SPF -eq 'Missing' } }
        @{ Why = 'several SPF records'; Table = 'dnsSummary'; Test = { $_.SPF -like 'Multiple*' } }
        @{ Why = 'weak DMARC'; Table = 'dnsSummary'; Test = { $_.DMARC -in 'Missing', 'none' } }
        @{ Why = 'long MX TTL'; Table = 'dnsSummary'; Test = { $_.'MX TTL' -gt 3600 } }
    ) {
        $rows = foreach ($tenant in (Get-Fake 1 42).tenants.Values) { @($tenant.tables[$Table]) }
        @($rows | Where-Object $Test).Count | Should -BeGreaterThan 0 -Because $Why
    }

    It 'repeats identities, sites, teams and aliases across tenants' {
        $target = $Fake.tenants.Target.tables
        $s1 = $Fake.tenants.S1.tables
        @($s1.users.Name | Where-Object { $_ -in $target.users.Name }).Count | Should -BeGreaterThan 0
        @($s1.sites.Path | Where-Object { $_ -in $target.sites.Path -and $_ -match '^/sites/' }).Count | Should -BeGreaterThan 0
        @($s1.teams.Name | Where-Object { $_ -in $target.teams.Name }).Count | Should -BeGreaterThan 0
    }

    It 'shows a setting that differs between tenants' {
        $value = { param($tenant) ($tenant.tables.sharePointSettings | Where-Object Setting -EQ 'SharingCapability').Value }
        (& $value $Fake.tenants.Target) | Should -Be 'ExternalUserSharingOnly'
        (& $value $Fake.tenants.S1) | Should -Be 'ExternalUserAndGuestSharing'
    }

    It 'links a partner tenant by its ID' {
        $partners = @($Fake.tenants.Target.tables.crossTenantPartners.Tenant)
        $partners | Should -Contain $Fake.tenants.S1.tenantId
    }
}

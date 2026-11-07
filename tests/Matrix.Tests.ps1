BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    $script:Tool = Join-Path $PSScriptRoot '../tools/New-TcFakeSnapshot.ps1'

    function Get-TcFake {
        param([int]$SourceCount)
        $path = Join-Path $TestDrive "fake-$SourceCount.json"
        if (-not (Test-Path $path)) { & $script:Tool -SourceCount $SourceCount -Seed 5 -Path $path | Out-Null }
        InModuleScope TenantConverge -Parameters @{ Path = $path } {
            param($Path)
            , (Read-TcSnapshot -Path $Path)
        }
    }

    function Get-TcSmallSnapshot {
        param([hashtable[]]$SourceUsers, [hashtable[]]$TargetUsers = @(), [hashtable[]]$Mailboxes = @())
        $user = {
            param($item)
            $row = [ordered]@{
                Id = 'id'; UPN = ''; Name = ''; Type = 'Member'; Enabled = $true; 'Last sign-in' = '2026-01-10 08:00'; Licenses = 'SPE_E3'; 'License count' = 1; 'First name' = ''; 'Last name' = ''
            }
            foreach ($key in $item.Keys) { $row[$key] = $item[$key] }
            $row
        }
        [ordered]@{
            schemaVersion = 1
            meta          = [ordered]@{ project = 'x'; started = '2026-01-15T08:00:00'; finished = ''; moduleVersion = '0'; depth = 'Complete' }
            coverage      = @()
            tenants       = [ordered]@{
                Target = [ordered]@{
                    displayName = 'Summit'; primaryDomain = 'summit.example'; tenantId = 't'
                    tables = [ordered]@{ users = @($TargetUsers | ForEach-Object { & $user $_ }); domains = @([ordered]@{ Domain = 'summit.onmicrosoft.com'; Initial = $true }) }
                }
                S1 = [ordered]@{
                    displayName = 'Alpine'; primaryDomain = 'alpine.example'; tenantId = 's'
                    tables = [ordered]@{ users = @($SourceUsers | ForEach-Object { & $user $_ }); mailboxes = @($Mailboxes | ForEach-Object { [ordered]@{ UPN = $_['UPN']; Type = $_['Type']; ObjectId = 'o' } }) }
                }
            }
        }
    }

    function Invoke-TcMatrix {
        param($Snapshot, [string]$SourceRole = 'S1', [string[]]$IgnoreNameSuffix = @())
        InModuleScope TenantConverge -Parameters @{ Snapshot = $Snapshot; SourceRole = $SourceRole; Suffix = $IgnoreNameSuffix } {
            param($Snapshot, $SourceRole, $Suffix)
            ConvertTo-TcIdentityMatrix -Snapshot $Snapshot -SourceRole $SourceRole -IgnoreNameSuffix $Suffix
        }
    }
}

Describe 'Identity matrix draft' {
    It 'proposes to create an account with no match in the target' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'ana@alpine.example'; Name = 'Ana Silva'; 'First name' = 'Ana'; 'Last name' = 'Silva' })
        $row = @(Invoke-TcMatrix $snapshot)[0]
        $row['Source UPN'] | Should -Be 'ana@alpine.example'
        $row['Display name'] | Should -Be 'Ana Silva'
        $row['First name'] | Should -Be 'Ana'
        $row['Last name'] | Should -Be 'Silva'
        $row['Type'] | Should -Be 'User'
        $row['Decision'] | Should -Be 'Create'
        $row['Target UPN'] | Should -Be 'ana@alpine.example'
        $row['Temporary UPN'] | Should -Be 's1.ana@summit.onmicrosoft.com'
    }

    It 'flags a likely duplicate, ignoring accents, case and punctuation' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'eloise@alpine.example'; Name = 'Éloïse CÔTÉ-Tremblay' }) -TargetUsers @(@{ UPN = 'e.cote@summit.example'; Name = 'eloise cote-tremblay' })
        $row = @(Invoke-TcMatrix $snapshot)[0]
        $row['Decision'] | Should -Be 'Duplicate'
        $row['Target UPN'] | Should -Be 'e.cote@summit.example'
        $row['Temporary UPN'] | Should -Be ''
        $row['Notes'] | Should -Match 'likely duplicate of e\.cote@summit\.example'
    }

    It 'ignores a name suffix only when asked' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'ana@alpine.example'; Name = 'Ana Silva' }) -TargetUsers @(@{ UPN = 'ana@summit.example'; Name = 'Ana Silva SH' })
        @(Invoke-TcMatrix $snapshot)[0]['Decision'] | Should -Be 'Create'
        @(Invoke-TcMatrix $snapshot -IgnoreNameSuffix 'SH')[0]['Decision'] | Should -Be 'Duplicate'
    }

    It 'leaves out guests on both sides' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(
            @{ UPN = 'ana@alpine.example'; Name = 'Ana Silva' }
            @{ UPN = 'guest_x#EXT#@alpine.example'; Name = 'Marc Roy'; Type = 'Guest' }
        ) -TargetUsers @(@{ UPN = 'marc@x'; Name = 'Marc Roy'; Type = 'Guest' })
        $rows = @(Invoke-TcMatrix $snapshot)
        $rows.Count | Should -Be 1
        $rows[0]['Source UPN'] | Should -Be 'ana@alpine.example'
    }

    It 'sends a disabled account for review' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'off@alpine.example'; Name = 'Off User'; Enabled = $false })
        $row = @(Invoke-TcMatrix $snapshot)[0]
        $row['Decision'] | Should -Be 'To review'
        $row['Notes'] | Should -Match 'disabled account'
    }

    It 'sends an account inactive for 90 days for review' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'old@alpine.example'; Name = 'Old User'; 'Last sign-in' = '2020-02-03 08:00' })
        $row = @(Invoke-TcMatrix $snapshot)[0]
        $row['Decision'] | Should -Be 'To review'
        $row['Notes'] | Should -Match 'inactive since 2020-02-03'
    }

    It 'sends an account with no license and no sign-in for review' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'none@alpine.example'; Name = 'No User'; 'Last sign-in' = $null; Licenses = ''; 'License count' = 0 })
        $row = @(Invoke-TcMatrix $snapshot)[0]
        $row['Decision'] | Should -Be 'To review'
        $row['Notes'] | Should -Match 'no license and no known sign-in'
    }

    It 'reads the type from the mailbox' -TestCases @(
        @{ Mailbox = 'SharedMailbox'; Expected = 'Shared' }
        @{ Mailbox = 'SchedulingMailbox'; Expected = 'Shared' }
        @{ Mailbox = 'RoomMailbox'; Expected = 'Resource' }
        @{ Mailbox = 'EquipmentMailbox'; Expected = 'Resource' }
        @{ Mailbox = 'UserMailbox'; Expected = 'User' }
    ) {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'box@alpine.example'; Name = 'Box' }) -Mailboxes @(@{ UPN = 'box@alpine.example'; Type = $Mailbox })
        @(Invoke-TcMatrix $snapshot)[0]['Type'] | Should -Be $Expected
    }

    It 'does not review a shared mailbox for inactivity' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'info@alpine.example'; Name = 'Info'; Enabled = $false; 'Last sign-in' = $null }) -Mailboxes @(@{ UPN = 'info@alpine.example'; Type = 'SharedMailbox' })
        @(Invoke-TcMatrix $snapshot)[0]['Decision'] | Should -Be 'Create'
    }

    It 'sends a Bookings page for review: it cannot be moved' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'book@alpine.example'; Name = 'Booking' }) -Mailboxes @(@{ UPN = 'book@alpine.example'; Type = 'SchedulingMailbox' })
        $row = @(Invoke-TcMatrix $snapshot)[0]
        $row['Decision'] | Should -Be 'To review'
        $row['Notes'] | Should -Match 'Bookings'
    }

    It 'sorts rows by display name' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'z@alpine.example'; Name = 'Zoe' }, @{ UPN = 'a@alpine.example'; Name = 'Ana' })
        @(Invoke-TcMatrix $snapshot | ForEach-Object { $_['Display name'] }) | Should -Be @('Ana', 'Zoe')
    }

    It 'returns nothing when the users of the source were not collected' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @()
        $snapshot.tenants.S1.tables.Remove('users')
        @(Invoke-TcMatrix $snapshot) | Should -BeNullOrEmpty
    }

    It 'proposes no creation when the accounts of the target were not collected' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'ana@alpine.example'; Name = 'Ana Silva' })
        $snapshot.tenants.Target.tables.Remove('users')
        $row = @(Invoke-TcMatrix $snapshot)[0]
        $row['Decision'] | Should -Be 'To review'
        $row['Notes'] | Should -Match 'accounts of the target were not read'
    }

    It 'proposes no creation when the accounts of the target came back empty from a partial collector' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'ana@alpine.example'; Name = 'Ana Silva' })
        $snapshot.coverage = @([ordered]@{ role = 'Target'; id = 'ENT-03'; status = 'Partial'; message = 'stopped'; remedy = 'review' })
        @(Invoke-TcMatrix $snapshot)[0]['Decision'] | Should -Be 'To review'
    }

    It 'keeps the other notes of an account when the target was not read' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'ana@alpine.example'; Name = 'Ana Silva'; Enabled = $false })
        $snapshot.tenants.Target.tables.Remove('users')
        $notes = @(Invoke-TcMatrix $snapshot)[0]['Notes']
        $notes | Should -Match 'disabled account'
        $notes | Should -Match 'accounts of the target were not read'
    }

    It 'fails clearly for a role that is not a source' {
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'ana@alpine.example'; Name = 'Ana' })
        { Invoke-TcMatrix $snapshot -SourceRole 'S3' } | Should -Throw '*S3*'
    }

    It 'builds a draft per source on fictional tenants' -TestCases @(@{ Count = 1 }, @{ Count = 2 }, @{ Count = 3 }) {
        $snapshot = Get-TcFake $Count
        foreach ($role in @($snapshot['tenants'].Keys | Where-Object { $_ -ne 'Target' })) {
            $rows = @(Invoke-TcMatrix $snapshot -SourceRole $role)
            $rows.Count | Should -BeGreaterThan 10 -Because $role
            @($rows | Where-Object { $_['Decision'] -eq 'Duplicate' }).Count | Should -BeGreaterThan 0 -Because "$role shares people with the target"
            @($rows | Where-Object { $_['Decision'] -eq 'Create' }).Count | Should -BeGreaterThan 0 -Because $role
            @($rows | Where-Object { $_['Decision'] -eq 'To review' }).Count | Should -BeGreaterThan 0 -Because $role
            @($rows | Where-Object { $_['Decision'] -notin 'Create', 'Duplicate', 'Exclude', 'To review' }) | Should -BeNullOrEmpty
        }
    }

    It 'writes one CSV per source' {
        $snapshot = Get-TcFake 2
        $folder = Join-Path $TestDrive 'matrix'
        New-Item -ItemType Directory -Force $folder | Out-Null
        InModuleScope TenantConverge -Parameters @{ Snapshot = $snapshot; Folder = $folder } {
            param($Snapshot, $Folder)
            Export-TcIdentityMatrix -Snapshot $Snapshot -Folder $Folder
        }
        @(Get-ChildItem $folder -Filter 'identity-matrix-*.csv').Name | Should -Be @('identity-matrix-S1.csv', 'identity-matrix-S2.csv')
        $line = Get-Content (Join-Path $folder 'identity-matrix-S1.csv') -TotalCount 1
        $line | Should -Match '"Source UPN","Display name","First name","Last name","Type","Decision","Target UPN","Temporary UPN","License","Groups","Notes"'
        [System.IO.File]::ReadAllBytes((Join-Path $folder 'identity-matrix-S1.csv'))[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
    }

    It 'neutralizes a display name that Excel would read as a formula' {
        $folder = Join-Path $TestDrive 'matrix-formula'
        New-Item -ItemType Directory -Force $folder | Out-Null
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'a@alpine.example'; Name = '=HYPERLINK("http://bad.example")'; 'First name' = '@Ana'; 'Last name' = 'Silva' })
        InModuleScope TenantConverge -Parameters @{ Snapshot = $snapshot; Folder = $folder } {
            param($Snapshot, $Folder)
            Export-TcIdentityMatrix -Snapshot $Snapshot -Folder $Folder
        }
        $row = Import-Csv (Join-Path $folder 'identity-matrix-S1.csv')
        $row.'Display name' | Should -Be '''=HYPERLINK("http://bad.example")'
        $row.'First name' | Should -Be '''@Ana'
        $row.'Last name' | Should -Be 'Silva'
        $row.'Source UPN' | Should -Be 'a@alpine.example'
    }

    It 'finds the duplicate of a display name that holds <Label>' -ForEach @(
        @{ Label = 'a non-character'; Code = 0xFFFE }
        @{ Label = 'half of a surrogate pair'; Code = 0xD83D }
    ) {
        $name = "Ana$([char]$Code) Silva"
        $snapshot = Get-TcSmallSnapshot -SourceUsers @(@{ UPN = 'ana@alpine.example'; Name = $name }) -TargetUsers @(@{ UPN = 'ana@summit.example'; Name = 'Ana Silva' })
        $row = @(Invoke-TcMatrix $snapshot)[0]
        $row['Decision'] | Should -Be 'Duplicate'
        $row['Display name'] | Should -BeExactly $name
    }

    It 'reads every character there is as a name' {
        $text = -join (0..0xFFFF | ForEach-Object { [char]$_ })
        InModuleScope TenantConverge -Parameters @{ Text = $text } {
            param($Text)
            ConvertTo-TcMatchName -Name $Text | Should -Match 'abc'
        }
    }

    It 'keeps the rules running on a tenant with such a name' {
        . (Join-Path $PSScriptRoot 'Support/WorkbookFixtures.ps1')
        $snapshot = Get-TcFake 1
        Add-TcWorkbookUser -Snapshot $snapshot -Role 'S1' -Name "x$([char]0xFFFE)" -Upn 'odd@alpine.example'
        $result = Invoke-TcRuleSet -Snapshot $snapshot
        @($result['errors']) | Should -BeNullOrEmpty
    }

    It 'compares every character there is as a person across tenants' {
        $text = -join (0..0xFFFF | ForEach-Object { [char]$_ })
        InModuleScope TenantConverge -Parameters @{ Text = $text } {
            param($Text)
            ConvertTo-TcPersonKey $Text | Should -Match 'abc'
        }
    }

    It 'makes a plan from a tenant with such a name' {
        . (Join-Path $PSScriptRoot 'Support/WorkbookFixtures.ps1')
        $snapshot = Get-TcFake 1
        Add-TcWorkbookUser -Snapshot $snapshot -Role 'S1' -Name "x$([char]0xFFFE)" -Upn 'odd@alpine.example'
        $plan = New-TcPlan -Project (New-TcWorkbookProject) -Snapshot $snapshot
        @($plan['actions']).Count | Should -BeGreaterThan 0
    }
}

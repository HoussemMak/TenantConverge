BeforeDiscovery {
    $script:Mutations = @(
        @{ Name = 'a missing target'; Code = 'TC1003'; Change = { param($p) $p.PSObject.Properties.Remove('target') } }
        @{ Name = 'an invalid domain'; Code = 'TC1004'; Change = { param($p) $p.sources[0].primaryDomain = 'not a domain' } }
        @{ Name = 'an invalid tenant ID'; Code = 'TC1005'; Change = { param($p) $p.sources[0].tenantId = 'abc' } }
        @{ Name = 'an unsupported schema version'; Code = 'TC1008'; Change = { param($p) $p.schemaVersion = 2 } }
        @{ Name = 'roles out of order'; Code = 'TC1009'; Change = { param($p) $p.sources[0].role = 'S2' } }
        @{ Name = 'an empty display name'; Code = 'TC1010'; Change = { param($p) $p.target.displayName = ' ' } }
        @{ Name = 'a display name over 64 characters'; Code = 'TC1010'; Change = { param($p) $p.target.displayName = 'x' * 65 } }
        @{ Name = 'a control character in a display name'; Code = 'TC1010'; Change = { param($p) $p.target.displayName = "a`tb" } }
        @{ Name = 'an unknown access mode'; Code = 'TC1011'; Change = { param($p) $p.access.mode = 'Password' } }
        @{ Name = 'an empty output folder'; Code = 'TC1012'; Change = { param($p) $p.output.path = '' } }
        @{ Name = 'an unknown target state'; Code = 'TC1013'; Change = { param($p) $p.target.state = 'Maybe' } }
    )
}

Describe 'Project validation' {
    BeforeAll {
        $root = Join-Path $PSScriptRoot '..'
        Import-Module (Join-Path $root 'src/TenantConverge/TenantConverge.psd1') -Force

        function New-Sample {
            param([int]$Count)
            $sources = @()
            for ($i = 1; $i -le $Count; $i++) {
                $sources += [pscustomobject]@{
                    role          = "S$i"
                    displayName   = "Source $i"
                    primaryDomain = "s$i.example"
                    tenantId      = $null
                    wave          = 1
                }
            }
            [pscustomobject]@{
                schemaVersion = 1
                name          = 'Sample consolidation'
                target        = [pscustomobject]@{
                    displayName   = 'Target'
                    primaryDomain = 'target.example'
                    tenantId      = $null
                    state         = 'Production'
                }
                sources       = $sources
                access        = [pscustomobject]@{ mode = 'Browser' }
                output        = [pscustomobject]@{ path = './output' }
                team          = @()
            }
        }

        function Get-ProjectError {
            param($Project)
            InModuleScope TenantConverge -Parameters @{ P = $Project } {
                param($P)
                Test-TcProjectDefinition -Project $P
            }
        }
    }

    It 'accepts <_> source(s)' -ForEach 1, 2, 3 {
        Get-ProjectError (New-Sample $_) | Should -BeNullOrEmpty
    }

    It 'rejects 4 sources with TC1002 and names the limit' {
        $errors = @(Get-ProjectError (New-Sample 4))
        $errors.Code | Should -Contain 'TC1002'
        $found = $errors | Where-Object Code -EQ 'TC1002'
        $found.Message | Should -Match 'at most 3'
        $found.Message | Should -Match 'has 4'
    }

    It 'rejects a project with no source' {
        (Get-ProjectError (New-Sample 0)).Code | Should -Contain 'TC1001'
    }

    It 'rejects <Name>' -ForEach $Mutations {
        $project = New-Sample 1
        & $Change $project
        (Get-ProjectError $project).Code | Should -Contain $Code
    }

    It 'reports missing sections instead of crashing' {
        $codes = (Get-ProjectError ([pscustomobject]@{})).Code
        $codes | Should -Contain 'TC1001'
        $codes | Should -Contain 'TC1003'
        $codes | Should -Contain 'TC1008'
        $codes | Should -Contain 'TC1011'
        $codes | Should -Contain 'TC1012'
    }

    It 'rejects sources written as one object instead of a list' {
        $project = New-Sample 1
        $project.sources = $project.sources[0]
        (Get-ProjectError $project).Code | Should -Contain 'TC1016'
    }

    It 'accepts a list of one source, as a file holds it' {
        $text = New-Sample 1 | ConvertTo-Json -Depth 5
        Get-ProjectError ($text | ConvertFrom-Json) | Should -BeNullOrEmpty
    }

    It 'reports a source that is not an object' {
        $project = New-Sample 1
        $project.sources = @('text')
        (Get-ProjectError $project).Code | Should -Contain 'TC1004'
    }

    It 'treats SUMMIT.example. and summit.example as one tenant' {
        $project = New-Sample 1
        $project.target.primaryDomain = 'summit.example'
        $project.sources[0].primaryDomain = ' SUMMIT.example. '
        (Get-ProjectError $project).Code | Should -Contain 'TC1006'
    }

    It 'detects two sources that share a domain' {
        $project = New-Sample 2
        $project.sources[1].primaryDomain = $project.sources[0].primaryDomain
        (Get-ProjectError $project).Code | Should -Contain 'TC1006'
    }

    It 'detects two sources that share a tenant ID whatever the case' {
        $project = New-Sample 2
        $id = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
        $project.sources[0].tenantId = $id
        $project.sources[1].tenantId = $id.ToUpperInvariant()
        (Get-ProjectError $project).Code | Should -Contain 'TC1006'
    }

    It 'accepts waves that share a number' {
        $project = New-Sample 3
        $project.sources[1].wave = 2
        $project.sources[2].wave = 2
        Get-ProjectError $project | Should -BeNullOrEmpty
    }

    It 'rejects waves 1 and 3' {
        $project = New-Sample 2
        $project.sources[1].wave = 3
        (Get-ProjectError $project).Code | Should -Contain 'TC1007'
    }

    It 'rejects a wave written as text' {
        $project = New-Sample 1
        $project.sources[0].wave = 'one'
        (Get-ProjectError $project).Code | Should -Contain 'TC1007'
    }

    It 'says that a wave must be a whole number, for <Name>' -ForEach @(
        @{ Name = 'text'; Wave = 'one' }
        @{ Name = 'a fraction'; Wave = 1.5 }
        @{ Name = 'zero'; Wave = 0 }
        @{ Name = 'nothing'; Wave = $null }
    ) {
        $project = New-Sample 1
        $project.sources[0].wave = $Wave
        $message = @(Get-ProjectError $project | Where-Object Code -EQ 'TC1007').Message
        $message | Should -Match 'whole number'
        $message | Should -Not -Match 'gaps'
    }

    It 'keeps the message about gaps for whole numbers with a gap' {
        $project = New-Sample 2
        $project.sources[1].wave = 3
        @(Get-ProjectError $project | Where-Object Code -EQ 'TC1007').Message | Should -Match 'no gaps'
    }
}

Describe 'Domain normalization' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    }

    It 'lowers case and removes spaces and the final dot' {
        InModuleScope TenantConverge {
            ConvertTo-TcDomain -Value ' Summit.EXAMPLE. ' | Should -Be 'summit.example'
        }
    }

    It 'returns an empty string for a missing value' {
        InModuleScope TenantConverge {
            ConvertTo-TcDomain -Value $null | Should -Be ''
        }
    }
}

Describe 'Project files' {
    BeforeAll {
        $root = Join-Path $PSScriptRoot '..'
        Import-Module (Join-Path $root 'src/TenantConverge/TenantConverge.psd1') -Force
        $newArguments = @{
            Name              = 'Summit consolidation'
            TargetDomain      = 'Summit.example'
            TargetDisplayName = 'Summit Holdings'
            TargetState       = 'Production'
            Source            = @(
                @{ DisplayName = 'Alpine Group'; PrimaryDomain = 'alpine.example' }
                @{ DisplayName = 'Birch Partners'; PrimaryDomain = 'birch.example'; Wave = 2 }
            )
        }
    }

    It 'creates a valid file, assigns roles and defaults the wave' {
        $path = Join-Path $TestDrive 'new.json'
        $project = New-TcProject @newArguments -Path $path
        $project.sources.role | Should -Be @('S1', 'S2')
        $project.sources.wave | Should -Be @(1, 2)
        $project.target.primaryDomain | Should -Be 'summit.example'
        $project.access.mode | Should -Be 'Browser'
        Test-TcProject -Path $path | Should -BeTrue
    }

    It 'keeps accents through a file round trip, without BOM' {
        $path = Join-Path $TestDrive 'accent.json'
        $arguments = $newArguments.Clone()
        $arguments.TargetDisplayName = 'Société Générale Émeraude'
        New-TcProject @arguments -Path $path | Out-Null
        $bytes = [IO.File]::ReadAllBytes($path)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        $loaded = InModuleScope TenantConverge -Parameters @{ F = $path } {
            param($F)
            Read-TcProjectFile -Path $F
        }
        $loaded.target.displayName | Should -Be 'Société Générale Émeraude'
    }

    It 'writes one kind of line ending, on any system' {
        $path = Join-Path $TestDrive 'endings.json'
        New-TcProject @newArguments -Path $path | Out-Null
        [IO.File]::ReadAllText($path) | Should -Not -Match "`r"
    }

    It 'joins the problems of a project in one place' {
        $hits = Get-ChildItem (Join-Path $root 'src') -Recurse -Filter '*.ps1' | Select-String -SimpleMatch '"$($_.Code): $($_.Message)"'
        @($hits).Count | Should -Be 1
    }

    It 'refuses to overwrite a project without -Force' {
        $path = Join-Path $TestDrive 'twice.json'
        New-TcProject @newArguments -Path $path | Out-Null
        { New-TcProject @newArguments -Path $path } | Should -Throw '*already exists*'
    }

    It 'overwrites with -Force' {
        $path = Join-Path $TestDrive 'force.json'
        New-TcProject @newArguments -Path $path | Out-Null
        { New-TcProject @newArguments -Path $path -Force } | Should -Not -Throw
    }

    It 'writes nothing when the definition is invalid' {
        $path = Join-Path $TestDrive 'four.json'
        $arguments = $newArguments.Clone()
        $arguments.Source = 1..4 | ForEach-Object { @{ DisplayName = "S$_"; PrimaryDomain = "s$_.example" } }
        { New-TcProject @arguments -Path $path } | Should -Throw '*TC1002*'
        Test-Path $path | Should -BeFalse
    }

    It 'resolves a relative path against the current location' {
        Push-Location $TestDrive
        try {
            New-TcProject @newArguments -Path 'relative.json' | Out-Null
            Test-Path (Join-Path $TestDrive 'relative.json') | Should -BeTrue
        }
        finally {
            Pop-Location
        }
    }

    It 'reports a hand-edited file with 4 sources' {
        $path = Join-Path $TestDrive 'edited.json'
        New-TcProject @newArguments -Path $path | Out-Null
        $json = Get-Content $path -Raw | ConvertFrom-Json
        $json.sources = 1..4 | ForEach-Object {
            [pscustomobject]@{ role = "S$_"; displayName = "S$_"; primaryDomain = "s$_.example"; tenantId = $null; wave = 1 }
        }
        $json | ConvertTo-Json -Depth 5 | Set-Content $path
        Test-TcProject -Path $path | Should -BeFalse
        (Test-TcProject -Path $path -Detailed).Code | Should -Contain 'TC1002'
    }

    It 'reports a file that is not JSON' {
        $path = Join-Path $TestDrive 'broken.json'
        Set-Content -Path $path -Value '{ not json'
        Test-TcProject -Path $path | Should -BeFalse
        (Test-TcProject -Path $path -Detailed).Code | Should -Contain 'TC1014'
    }

    It 'reports a missing file' {
        (Test-TcProject -Path (Join-Path $TestDrive 'absent.json') -Detailed).Code | Should -Contain 'TC1015'
    }

    It 'makes the read error start with the first code' {
        $path = Join-Path $TestDrive 'read.json'
        Set-Content -Path $path -Value '{ not json'
        InModuleScope TenantConverge -Parameters @{ F = $path } {
            param($F)
            { Read-TcProjectFile -Path $F } | Should -Throw 'TC1014*'
        }
    }
}

Describe 'Examples and schema' {
    BeforeAll {
        $root = Join-Path $PSScriptRoot '..'
        Import-Module (Join-Path $root 'src/TenantConverge/TenantConverge.psd1') -Force
        $schemaPath = Join-Path $root 'src/TenantConverge/Data/project.schema.json'
        $examples = Get-ChildItem (Join-Path $root 'examples') -Filter '*.project.json'
    }

    It 'provides one example per scenario' {
        ($examples | ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).sources.Count } | Sort-Object) |
            Should -Be @(1, 2, 3)
    }

    It 'accepts every example file' {
        $examples | Should -Not -BeNullOrEmpty
        foreach ($example in $examples) {
            Test-TcProject -Path $example.FullName | Should -BeTrue
        }
    }

    It 'writes the limit once in the schema: a wave has no maximum of its own' {
        $schema = Get-Content $schemaPath -Raw | ConvertFrom-Json
        $schema.properties.sources.items.properties.wave.PSObject.Properties.Name | Should -Not -Contain 'maximum'
    }

    It 'matches the schema with every example file' {
        $examples | Should -Not -BeNullOrEmpty
        foreach ($example in $examples) {
            Test-Json -Json (Get-Content $example.FullName -Raw) -SchemaFile $schemaPath | Should -BeTrue
        }
    }

    It 'keeps the schema limit equal to TcMaxSources' {
        $schema = Get-Content $schemaPath -Raw | ConvertFrom-Json
        $limit = InModuleScope TenantConverge { $script:TcMaxSources }
        $schema.properties.sources.maxItems | Should -Be $limit
    }
}

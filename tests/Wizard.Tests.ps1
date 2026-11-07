Describe 'Start-TenantConverge' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force

        function Set-Answer {
            param([string[]]$Answers)
            $global:TcTestAnswers = [Collections.Generic.Queue[string]]::new()
            foreach ($answer in $Answers) { $global:TcTestAnswers.Enqueue($answer) }
        }

        # Target, then the answers that follow the sources in every scenario.
        $target = @('summit.example', 'Summit Holdings', 'y')
        $closing = @('1', '', '', 'y')
    }

    BeforeEach {
        $path = Join-Path $TestDrive "$([guid]::NewGuid()).json"
        $safeOutput = Join-Path $TestDrive 'out'
        $saved = @{
            OneDrive           = $env:OneDrive
            OneDriveCommercial = $env:OneDriveCommercial
            OneDriveConsumer   = $env:OneDriveConsumer
        }
        $env:OneDrive = $null
        $env:OneDriveCommercial = $null
        $env:OneDriveConsumer = $null
        Mock Read-TcAnswer -ModuleName TenantConverge {
            if ($global:TcTestAnswers.Count -eq 0) { throw "No scripted answer left for: $Prompt" }
            $global:TcTestAnswers.Dequeue()
        }
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Test-TcPrerequisite -ModuleName TenantConverge { [pscustomobject]@{ Ready = $true; PowerShell = '7.4.6'; WindowsPowerShell = $true; Modules = @(); Missing = @() } }
        Mock Invoke-TcAssessment -ModuleName TenantConverge { [pscustomobject]@{ Folder = 'run'; Snapshot = 'run/snapshot.json'; NotCollected = 0 } }
    }

    AfterEach {
        $env:OneDrive = $saved.OneDrive
        $env:OneDriveCommercial = $saved.OneDriveCommercial
        $env:OneDriveConsumer = $saved.OneDriveConsumer
    }

    AfterAll {
        Remove-Variable -Name TcTestAnswers -Scope Global -ErrorAction SilentlyContinue
    }

    It 'builds a 3-to-1 project from scripted answers' {
        Set-Answer (@('3') + $target +
            @('Alpine Group', 'alpine.example', '1') +
            @('Birch Partners', 'birch.example', '2') +
            @('Cedar Services', 'cedar.example', '2') +
            @('1', $safeOutput, 'Ana, Ben', 'y'))

        $project = Start-TenantConverge -Path $path

        $project.sources.role | Should -Be @('S1', 'S2', 'S3')
        $project.sources.wave | Should -Be @(1, 2, 2)
        $project.target.state | Should -Be 'Production'
        $project.team | Should -Be @('Ana', 'Ben')
        $project.name | Should -Be 'Summit Holdings consolidation'
        Test-TcProject -Path $path | Should -BeTrue
    }

    It 'asks again after 4, three or an empty answer' {
        Set-Answer (@('4', 'three', '', '1') + $target + @('Alpine Group', 'alpine.example') + $closing)

        $project = Start-TenantConverge -Path $path

        @($project.sources).Count | Should -Be 1
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -Times 3 -Exactly -ParameterFilter { $Message -match '1, 2 or 3' }
    }

    It 'explains waves before asking for them' {
        Set-Answer (@('2') + $target +
            @('Alpine Group', 'alpine.example', '1') +
            @('Birch Partners', 'birch.example', '2') + $closing)

        Start-TenantConverge -Path $path | Out-Null

        Should -Invoke Write-TcMessage -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter { $Message -match 'A wave is' }
    }

    It 'skips the wave question for one source' {
        Set-Answer (@('1') + $target + @('Alpine Group', 'alpine.example') + $closing)

        $project = Start-TenantConverge -Path $path

        @($project.sources)[0].wave | Should -Be 1
        Should -Not -Invoke Read-TcAnswer -ModuleName TenantConverge -ParameterFilter { $Prompt -match 'wave' }
    }

    It 'asks again when a source repeats the target domain' {
        Set-Answer (@('1') + $target + @('Alpine Group', 'SUMMIT.example.', 'alpine.example') + $closing)

        $project = Start-TenantConverge -Path $path

        @($project.sources)[0].primaryDomain | Should -Be 'alpine.example'
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -Times 1 -ParameterFilter { $Message -match 'already used' }
    }

    It 'asks again for an invalid domain' {
        Set-Answer (@('1', 'not a domain') + @($target) + @('Alpine Group', 'alpine.example') + $closing)

        $project = Start-TenantConverge -Path $path

        $project.target.primaryDomain | Should -Be 'summit.example'
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -Times 1 -ParameterFilter { $Message -match 'not a valid domain' }
    }

    It 'asks again for an empty display name' {
        Set-Answer (@('1', 'summit.example', '', 'Summit Holdings', 'y') + @('Alpine Group', 'alpine.example') + $closing)

        $project = Start-TenantConverge -Path $path

        $project.target.displayName | Should -Be 'Summit Holdings'
    }

    It 'asks the waves again when they leave a gap' {
        Set-Answer (@('3') + $target +
            @('Alpine Group', 'alpine.example', '1') +
            @('Birch Partners', 'birch.example', '3') +
            @('Cedar Services', 'cedar.example', '3') +
            @('1', '2', '2') + $closing)

        $project = Start-TenantConverge -Path $path

        $project.sources.wave | Should -Be @(1, 2, 2)
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -Times 1 -ParameterFilter { $Message -match 'no gaps' }
    }

    It 'records the application sign-in choice' {
        Set-Answer (@('1') + $target + @('Alpine Group', 'alpine.example') + @('2', '', '', 'y'))

        (Start-TenantConverge -Path $path).access.mode | Should -Be 'Application'
    }

    It 'records a new target' {
        Set-Answer (@('1', 'summit.example', 'Summit Holdings', 'n') + @('Alpine Group', 'alpine.example') + $closing)

        (Start-TenantConverge -Path $path).target.state | Should -Be 'New'
    }

    It 'offers a default output folder under the home folder' {
        Set-Answer (@('1') + $target + @('Alpine Group', 'alpine.example') + $closing)

        $project = Start-TenantConverge -Path $path

        $project.output.path | Should -Be (Join-Path $HOME 'TenantConverge/summit-holdings-consolidation')
    }

    It 'warns when the output folder is synced and goes on after yes' {
        $env:OneDrive = Join-Path $TestDrive 'cloud'
        Set-Answer (@('1') + $target + @('Alpine Group', 'alpine.example') +
            @('1', (Join-Path $env:OneDrive 'reports'), 'y', '', 'y'))

        $project = Start-TenantConverge -Path $path

        $project.output.path | Should -Be (Join-Path $env:OneDrive 'reports')
        Should -Invoke Read-TcAnswer -ModuleName TenantConverge -Times 1 -ParameterFilter { $Prompt -match 'syncs to OneDrive' }
    }

    It 'asks for another output folder after no' {
        $env:OneDrive = Join-Path $TestDrive 'cloud'
        Set-Answer (@('1') + $target + @('Alpine Group', 'alpine.example') +
            @('1', (Join-Path $env:OneDrive 'reports'), 'n', $safeOutput, '', 'y'))

        (Start-TenantConverge -Path $path).output.path | Should -Be $safeOutput
    }

    It 'writes nothing when the user declines' {
        Set-Answer (@('1') + $target + @('Alpine Group', 'alpine.example') + @('1', '', '', 'n'))

        Start-TenantConverge -Path $path | Should -BeNullOrEmpty
        Test-Path $path | Should -BeFalse
    }

    It 'never overwrites a project without -Force' {
        Set-Content -Path $path -Value '{}'

        { Start-TenantConverge -Path $path } | Should -Throw '*already exists*'
        Should -Invoke Read-TcAnswer -ModuleName TenantConverge -Times 0 -Exactly
    }

    It 'refuses a hand-edited project with 4 sources' {
        $project = Get-Content (Join-Path $PSScriptRoot '../examples/three-to-one.project.json') -Raw | ConvertFrom-Json
        $project.sources += [pscustomobject]@{ role = 'S4'; displayName = 'Delta'; primaryDomain = 'delta.example'; tenantId = $null; wave = 1 }
        $project | ConvertTo-Json -Depth 5 | Set-Content $path

        { Start-TenantConverge -Project $path } | Should -Throw '*TC1002*'
        Should -Invoke Read-TcAnswer -ModuleName TenantConverge -Times 0 -Exactly
    }

    It 'loads a valid project without asking anything' {
        $example = Join-Path $PSScriptRoot '../examples/two-to-one.project.json'

        $project = Start-TenantConverge -Project $example

        @($project.sources).Count | Should -Be 2
        Should -Invoke Read-TcAnswer -ModuleName TenantConverge -Times 0 -Exactly
    }
}

Describe 'Get-TcSyncRisk' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    }

    BeforeEach {
        $saved = @{
            OneDrive           = $env:OneDrive
            OneDriveCommercial = $env:OneDriveCommercial
            OneDriveConsumer   = $env:OneDriveConsumer
        }
        $env:OneDrive = $null
        $env:OneDriveCommercial = $null
        $env:OneDriveConsumer = $null
    }

    AfterEach {
        $env:OneDrive = $saved.OneDrive
        $env:OneDriveCommercial = $saved.OneDriveCommercial
        $env:OneDriveConsumer = $saved.OneDriveConsumer
    }

    It 'names <Service> for <Folder>' -ForEach @(
        @{ Folder = 'C:/Users/ana/OneDrive - Summit/reports'; Service = 'OneDrive' }
        @{ Folder = 'C:/Users/ana/Dropbox/reports'; Service = 'Dropbox' }
        @{ Folder = 'C:/Users/ana/Google Drive/reports'; Service = 'Google Drive' }
        @{ Folder = 'C:/Users/ana/iCloudDrive/reports'; Service = 'iCloud' }
    ) {
        InModuleScope TenantConverge -Parameters @{ F = $Folder; S = $Service } {
            param($F, $S)
            Get-TcSyncRisk -Path $F | Should -Be $S
        }
    }

    It 'follows the OneDrive environment variable whatever the folder name' {
        $env:OneDriveCommercial = 'C:\Corp Files'
        InModuleScope TenantConverge {
            Get-TcSyncRisk -Path 'C:\Corp Files\reports' | Should -Be 'OneDrive'
        }
    }

    It 'does not confuse a sibling folder with the OneDrive folder' {
        $env:OneDrive = 'C:\Corp'
        InModuleScope TenantConverge {
            Get-TcSyncRisk -Path 'C:\Corporate\reports' | Should -BeNullOrEmpty
        }
    }

    It 'returns nothing for a local folder' {
        InModuleScope TenantConverge {
            Get-TcSyncRisk -Path 'C:\Reports\summit' | Should -BeNullOrEmpty
        }
    }
}

Describe 'ConvertTo-TcSlug' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    }

    It 'turns <Name> into <Slug>' -ForEach @(
        @{ Name = 'Summit Holdings consolidation'; Slug = 'summit-holdings-consolidation' }
        @{ Name = 'Société Générale & Fils'; Slug = 'societe-generale-fils' }
        @{ Name = '***'; Slug = 'project' }
    ) {
        InModuleScope TenantConverge -Parameters @{ N = $Name; S = $Slug } {
            param($N, $S)
            ConvertTo-TcSlug -Value $N | Should -Be $S
        }
    }

    It 'makes a folder name from every character there is' {
        $text = -join (0..0xFFFF | ForEach-Object { [char]$_ })
        InModuleScope TenantConverge -Parameters @{ Text = $text } {
            param($Text)
            ConvertTo-TcSlug -Value $Text | Should -Match 'abc'
        }
    }
}

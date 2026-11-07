BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')
    . (Join-Path $PSScriptRoot 'Support/ReportFixtures.ps1')
    . (Join-Path $PSScriptRoot 'Support/WorkbookReader.ps1')

    $script:Fixture = Get-TcReportFixture -SourceCount 2 -Folder $TestDrive

    function New-TcStartFolder {
        <# Writes what an assessment leaves on disk, from the fictional fixture. #>
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
        $run = (New-Item -ItemType Directory -Path (Join-Path $folder 'output/run')).FullName
        $project = Join-Path $folder 'project.json'
        $data = $script:Fixture['Project'] | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $data['output'] = [ordered]@{ path = './output' }
        InModuleScope TenantConverge -Parameters @{ Data = $data; Path = $project; Run = $run; Fixture = $script:Fixture } {
            param($Data, $Path, $Run, $Fixture)
            Write-TcJsonFile -Path $Path -InputObject $Data
            Write-TcJsonFile -Path (Join-Path $Run 'snapshot.json') -InputObject $Fixture['Snapshot']
            Write-TcJsonFile -Path (Join-Path $Run 'findings.json') -InputObject $Fixture['RuleSet']
            Write-TcJsonFile -Path (Join-Path $Run 'plan.json') -InputObject $Fixture['Plan']
        }
        [pscustomobject]@{
            Folder     = $folder
            Project    = $project
            Assessment = [pscustomobject]@{ Folder = $run; Snapshot = (Join-Path $run 'snapshot.json'); Plan = (Join-Path $run 'plan.json'); NotCollected = 0 }
        }
    }

    function Set-TcStartMock {
        param([string[]]$Missing = @())
        $script:Missing = $Missing
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Open-TcReport -ModuleName TenantConverge
        Mock Test-TcPrerequisite -ModuleName TenantConverge { [pscustomobject]@{ Ready = $true; PowerShell = '7.4.6'; WindowsPowerShell = $true; Modules = @(); Missing = $script:Missing } }
        Mock Invoke-TcAssessment -ModuleName TenantConverge { $script:Here.Assessment }
    }
}

Describe 'Start-TenantConverge, the report and the workbook' {
    BeforeEach {
        $script:Here = New-TcStartFolder
        Set-TcStartMock
    }

    It 'writes both next to the runs, from what the run saved' {
        Start-TenantConverge -Project $script:Here.Project -WarningAction SilentlyContinue | Out-Null
        Test-Path -LiteralPath (Join-Path $script:Here.Folder 'output/consolidation-report.html') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Here.Folder 'output/consolidation-workbook.xlsx') | Should -BeTrue
    }

    It 'shows in the report the plan of the run, read back from its file' {
        Start-TenantConverge -Project $script:Here.Project -WarningAction SilentlyContinue | Out-Null
        $html = [System.IO.File]::ReadAllText((Join-Path $script:Here.Folder 'output/consolidation-report.html'))
        $data = [regex]::Match($html, '<script id="report-data" type="application/json">(?<json>.*?)</script>', 'Singleline').Groups['json'].Value | ConvertFrom-Json -AsHashtable
        @($data['actions']).Count | Should -Be @($script:Fixture['Plan']['actions']).Count
        @($data['tasks']).Count | Should -Be @($script:Fixture['Plan']['tasks']).Count
    }

    It 'shows the remediations of the plan in both, each one untested' {
        Start-TenantConverge -Project $script:Here.Project -WarningAction SilentlyContinue | Out-Null
        $expected = @($script:Fixture['Plan']['remediations']).Count
        $expected | Should -BeGreaterThan 0

        $html = [System.IO.File]::ReadAllText((Join-Path $script:Here.Folder 'output/consolidation-report.html'))
        $data = [regex]::Match($html, '<script id="report-data" type="application/json">(?<json>.*?)</script>', 'Singleline').Groups['json'].Value | ConvertFrom-Json -AsHashtable
        @($data['remediations']).Count | Should -Be $expected
        @($data['remediations'] | Where-Object { $_['testedOnRealTenant'] -ne $false }).Count | Should -Be 0

        $book = Read-TcXlsx -Path (Join-Path $script:Here.Folder 'output/consolidation-workbook.xlsx')
        @(Get-TcXlsxRow -Book $book -Table 'Remediations').Count | Should -Be $expected
    }

    It 'gives the report the snapshot as a file, so that the collection log joins it' {
        Mock New-TcReport -ModuleName TenantConverge { [pscustomobject]@{ Path = 'report.html' } }
        Mock New-TcWorkbook -ModuleName TenantConverge { 'workbook.xlsx' }
        Start-TenantConverge -Project $script:Here.Project | Out-Null
        Should -Invoke New-TcReport -ModuleName TenantConverge -Times 1 -ParameterFilter { $Snapshot -is [string] -and $Snapshot -eq $script:Here.Assessment.Snapshot }
    }

    It 'opens the report it wrote' {
        Start-TenantConverge -Project $script:Here.Project -WarningAction SilentlyContinue | Out-Null
        Should -Invoke Open-TcReport -ModuleName TenantConverge -Times 1 -ParameterFilter { $Path -like '*consolidation-report.html' }
    }

    It 'leaves the report closed with -NoOpen' {
        Start-TenantConverge -Project $script:Here.Project -NoOpen -WarningAction SilentlyContinue | Out-Null
        Should -Invoke Open-TcReport -ModuleName TenantConverge -Times 0
    }

    It 'keeps the workbook when the report fails, and says so' {
        Mock New-TcReport -ModuleName TenantConverge { throw 'report stopped' }
        Mock New-TcWorkbook -ModuleName TenantConverge { 'workbook.xlsx' }
        Start-TenantConverge -Project $script:Here.Project | Out-Null
        Should -Invoke New-TcWorkbook -ModuleName TenantConverge -Times 1
        Should -Invoke Open-TcReport -ModuleName TenantConverge -Times 0
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'report could not be written' -and $Message -match 'report stopped' }
    }

    It 'keeps the report when the workbook fails, and says so' {
        Mock New-TcReport -ModuleName TenantConverge { [pscustomobject]@{ Path = 'report.html' } }
        Mock New-TcWorkbook -ModuleName TenantConverge { throw 'workbook stopped' }
        Start-TenantConverge -Project $script:Here.Project | Out-Null
        Should -Invoke Open-TcReport -ModuleName TenantConverge -Times 1
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'workbook could not be written' -and $Message -match 'workbook stopped' }
    }

    It 'writes neither without a plan, and says so' {
        Mock New-TcReport -ModuleName TenantConverge
        Mock New-TcWorkbook -ModuleName TenantConverge
        $script:Here.Assessment.Plan = $null
        Start-TenantConverge -Project $script:Here.Project | Out-Null
        Should -Invoke New-TcReport -ModuleName TenantConverge -Times 0
        Should -Invoke New-TcWorkbook -ModuleName TenantConverge -Times 0
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'no report and no workbook' }
    }

    It 'still returns the project' {
        (Start-TenantConverge -Project $script:Here.Project -WarningAction SilentlyContinue)['name'] | Should -Be $script:Fixture['Project']['name']
    }
}

Describe 'Start-TenantConverge without ImportExcel' {
    BeforeEach {
        $script:Here = New-TcStartFolder
        Set-TcStartMock -Missing @('ImportExcel', 'PnP.PowerShell')
        Mock New-TcReport -ModuleName TenantConverge { [pscustomobject]@{ Path = 'report.html' } }
        Mock New-TcWorkbook -ModuleName TenantConverge { 'workbook.xlsx' }
        Start-TenantConverge -Project $script:Here.Project | Out-Null
    }

    It 'does not call the workbook module something that was not collected' {
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Message -match 'not collected' -and $Message -match 'ImportExcel' } -Times 0
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Message -match 'Missing, so not collected: PnP\.PowerShell\.' } -Times 1
    }

    It 'skips the workbook, says so, and still writes the report' {
        Should -Invoke New-TcWorkbook -ModuleName TenantConverge -Times 0
        Should -Invoke New-TcReport -ModuleName TenantConverge -Times 1
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'ImportExcel is missing' -and $Message -match 'no workbook' } -Times 1
    }
}

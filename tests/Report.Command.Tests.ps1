BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')
    . (Join-Path $PSScriptRoot 'Support/ReportFixtures.ps1')

    $script:Fixture = Get-TcReportFixture -SourceCount 1 -Folder $TestDrive
    $script:Header = 'Type,Id,Label,Field,Value,Author,Date,Replaces'

    function New-TcTestFolder { (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName }

    function New-TcReportHere {
        <# Writes a report in a new folder, from the shared fixture. #>
        param([string]$Folder = (New-TcTestFolder), [hashtable]$More = @{})
        $parameters = @{ Project = $script:Fixture['Project']; Snapshot = $script:Fixture['Snapshot']; Plan = $script:Fixture['Plan']; RuleSet = $script:Fixture['RuleSet']; OutputPath = $Folder }
        foreach ($key in $More.Keys) { $parameters[$key] = $More[$key] }
        New-TcReport @parameters -WarningAction SilentlyContinue
    }

    function Get-ReportData {
        param([string]$Path)
        $html = [System.IO.File]::ReadAllText($Path)
        [regex]::Match($html, '<script id="report-data" type="application/json">(?<json>.*?)</script>', 'Singleline').Groups['json'].Value | ConvertFrom-Json -AsHashtable -Depth 50
    }
}

Describe 'New-TcReport' {
    It 'writes the report in the folder given' {
        $folder = New-TcTestFolder
        $result = New-TcReportHere -Folder $folder
        $result.Path | Should -Be (Join-Path $folder 'consolidation-report.html')
        $result.Path | Should -Exist
    }

    It 'takes a file name too, and creates the folder' {
        $path = Join-Path (New-TcTestFolder) 'deep/my-report.html'
        (New-TcReportHere -Folder $path).Path | Should -Be $path
        $path | Should -Exist
    }

    It 'writes UTF-8 with no byte order mark' {
        $result = New-TcReportHere
        $bytes = [System.IO.File]::ReadAllBytes($result.Path)
        $bytes[0..2] -join ',' | Should -Not -Be '239,187,191'
        [System.Text.Encoding]::UTF8.GetString($bytes, 0, 15) | Should -Be '<!doctype html>'
    }

    It 'leaves no temporary file' {
        $folder = New-TcTestFolder
        New-TcReportHere -Folder $folder | Out-Null
        @(Get-ChildItem $folder -Name | Sort-Object) | Should -Be @('consolidation-report.html', 'team-tracking.csv')
    }

    It 'computes the plan when none is given' {
        $folder = New-TcTestFolder
        $result = New-TcReport -Project $script:Fixture['Project'] -Snapshot $script:Fixture['Snapshot'] -OutputPath $folder -WarningAction SilentlyContinue
        $result.Actions | Should -Be @($script:Fixture['Plan']['actions']).Count
    }

    It 'uses the plan it is given' {
        $plan = New-TcEmptyPlan
        $result = New-TcReportHere -More @{ Plan = $plan }
        $result.Actions | Should -Be 0
        @((Get-ReportData $result.Path)['actions']).Count | Should -Be 0
    }

    It 'reads a project and a snapshot from their files, and the log beside the snapshot' {
        $folder = New-TcTestFolder
        $run = New-Item -ItemType Directory -Path (Join-Path $folder 'output/20260115-090000-assessment')
        $snapshotPath = Join-Path $run 'snapshot.json'
        $script:Fixture['Snapshot'] | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $snapshotPath -Encoding utf8
        Set-Content -LiteralPath (Join-Path $run 'journal.log') -Value 'first line', 'second line' -Encoding utf8
        $projectPath = Join-Path $folder 'project.json'
        New-TcReportProject -SourceCount 1 | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $projectPath -Encoding utf8

        $result = New-TcReport -Project $projectPath -Snapshot $snapshotPath -WarningAction SilentlyContinue

        $result.Path | Should -Be (Join-Path $folder 'output/consolidation-report.html')
        @((Get-ReportData $result.Path)['log']) | Should -Be 'first line', 'second line'
    }

    It 'has no log when it is given a snapshot in memory' {
        @((Get-ReportData (New-TcReportHere).Path)['log']).Count | Should -Be 0
    }

    It 'refuses a snapshot of another project' {
        $project = New-TcReportProject -SourceCount 1
        $snapshot = Get-TcFakeSnapshot -SourceCount 2 -Folder $TestDrive
        { New-TcReport -Project $project -Snapshot $snapshot -OutputPath (New-TcTestFolder) -WarningAction SilentlyContinue } | Should -Throw '*not in the project*'
    }

    It 'stops when the catalog cites what does not exist' {
        InModuleScope TenantConverge { $script:Saved = $script:TcProductCatalog; $script:TcProductCatalog = Get-TcProductCatalog | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable; $script:TcProductCatalog['products'][0]['tasks'] = @('NOPE-01') }
        try { { New-TcReportHere } | Should -Throw '*NOPE-01*' }
        finally { InModuleScope TenantConverge { $script:TcProductCatalog = $script:Saved } }
    }

    It 'warns that the file holds personal data' {
        $warnings = @()
        New-TcReport -Project $script:Fixture['Project'] -Snapshot $script:Fixture['Snapshot'] -Plan $script:Fixture['Plan'] -RuleSet $script:Fixture['RuleSet'] -OutputPath (New-TcTestFolder) -WarningVariable warnings -WarningAction SilentlyContinue | Out-Null
        ($warnings -join ' ') | Should -Match 'personal data'
    }

    It 'writes nothing with -WhatIf' {
        $folder = New-TcTestFolder
        New-TcReport -Project $script:Fixture['Project'] -Snapshot $script:Fixture['Snapshot'] -Plan $script:Fixture['Plan'] -RuleSet $script:Fixture['RuleSet'] -OutputPath $folder -WhatIf -WarningAction SilentlyContinue
        @(Get-ChildItem $folder).Count | Should -Be 0
    }

    It 'leaves the module with no state from the run' {
        New-TcReportHere | Out-Null
        InModuleScope TenantConverge { $script:TcRuleRun } | Should -BeNullOrEmpty
    }
}

Describe 'The tracking file' {
    It 'is created empty when it does not exist, in English, with commas and a byte order mark' {
        $result = New-TcReportHere
        $bytes = [System.IO.File]::ReadAllBytes($result.TrackingPath)
        $bytes[0..2] -join ',' | Should -Be '239,187,191'
        [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) | Should -Be "$script:Header`r`n"
    }

    It 'is never written once it exists' {
        $folder = New-TcTestFolder
        $path = Join-Path $folder 'team-tracking.csv'
        $original = [System.Text.UTF8Encoding]::new($true).GetPreamble() + [System.Text.Encoding]::UTF8.GetBytes("$script:Header`nnote row, kept as typed`n")
        [System.IO.File]::WriteAllBytes($path, $original)
        New-TcReportHere -Folder $folder | Out-Null
        [System.IO.File]::ReadAllBytes($path) -join ',' | Should -Be ($original -join ',')
    }

    It 'goes into the report as it is' {
        $folder = New-TcTestFolder
        $text = "$script:Header`r`naction,S1-X,Old title,status,Done,Pat,2026-01-15T09:00:00.000Z,`r`n"
        [System.IO.File]::WriteAllText((Join-Path $folder 'team-tracking.csv'), $text, [System.Text.UTF8Encoding]::new($true))
        $result = New-TcReportHere -Folder $folder
        (Get-ReportData $result.Path)['tracking']['text'] | Should -Be $text
    }

    It 'can live somewhere else' {
        $path = Join-Path (New-TcTestFolder) 'shared.csv'
        (New-TcReportHere -More @{ TrackingPath = $path }).TrackingPath | Should -Be $path
        $path | Should -Exist
    }

    It 'counts rows whose item left the plan, through the merge of the plan' {
        $folder = New-TcTestFolder
        $known = $script:Fixture['Plan']['actions'][0]['id']
        $lines = @($script:Header, "action,$known,Title,status,Done,Pat,2026-01-15T09:00:00.000Z,", 'task,OLD-01.S3,Gone,status,Done,Sam,2026-01-15T09:00:00.000Z,', 'task,OLD-01.S3,Gone,assignee,Sam,Sam,2026-01-15T09:00:00.000Z,', 'action,S3-GONE,Gone too,status,To do,Sam,2026-01-15T09:00:00.000Z,')
        [System.IO.File]::WriteAllLines((Join-Path $folder 'team-tracking.csv'), $lines, [System.Text.UTF8Encoding]::new($true))
        $result = New-TcReportHere -Folder $folder
        $result.TrackingRows | Should -Be 4
        @($result.OrphanRows | Sort-Object) | Should -Be 'OLD-01.S3', 'S3-GONE'
    }

    It 'does not call a setting of the plan an orphan' {
        $folder = New-TcTestFolder
        $line = $script:Fixture['Plan']['targetConfigurations'][0]
        $key = '{0}|{1}' -f $line['role'], $line['setting']
        [System.IO.File]::WriteAllLines((Join-Path $folder 'team-tracking.csv'), @($script:Header, ('configuration,"{0}",,applied,Yes,Pat,2026-01-15T09:00:00.000Z,' -f $key)), [System.Text.UTF8Encoding]::new($true))
        @((New-TcReportHere -Folder $folder).OrphanRows).Count | Should -Be 0
    }

    It 'reads a file saved by Excel with semicolons in an old code page' {
        $folder = New-TcTestFolder
        $text = "Type;Id;Label;Field;Value;Author;Date;Replaces`r`ntask;OLD-01.S3;Vérifié;note;déjà fait;José;2026-01-15T09:00:00.000Z;`r`n"
        [System.IO.File]::WriteAllBytes((Join-Path $folder 'team-tracking.csv'), [System.Text.Encoding]::GetEncoding(1252).GetBytes($text))
        $result = New-TcReportHere -Folder $folder
        @($result.OrphanRows) | Should -Be 'OLD-01.S3'
        (Get-ReportData $result.Path)['tracking']['text'] | Should -Match 'déjà fait'
    }

    It 'reads a file that Excel holds open' {
        $folder = New-TcTestFolder
        $path = Join-Path $folder 'team-tracking.csv'
        [System.IO.File]::WriteAllLines($path, @($script:Header, 'action,SOME-ID,,status,done,Pat,2026-11-01,'), [System.Text.UTF8Encoding]::new($true))
        $lock = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'Read')
        try {
            $result = New-TcReport -Project $script:Fixture['Project'] -Snapshot $script:Fixture['Snapshot'] -Plan $script:Fixture['Plan'] -RuleSet $script:Fixture['RuleSet'] -OutputPath $folder -WarningAction SilentlyContinue
        }
        finally { $lock.Dispose() }
        $result.TrackingRows | Should -Be 1
    }

    It 'still writes the report when nothing can open the file, and says why' {
        $folder = New-TcTestFolder
        $path = Join-Path $folder 'team-tracking.csv'
        [System.IO.File]::WriteAllLines($path, @($script:Header, 'action,SOME-ID,,status,done,Pat,2026-11-01,'), [System.Text.UTF8Encoding]::new($true))
        $warnings = @()
        $lock = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
        try {
            $result = New-TcReport -Project $script:Fixture['Project'] -Snapshot $script:Fixture['Snapshot'] -Plan $script:Fixture['Plan'] -RuleSet $script:Fixture['RuleSet'] -OutputPath $folder -WarningVariable warnings -WarningAction SilentlyContinue
        }
        finally { $lock.Dispose() }
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        ($warnings -join ' ') | Should -Match 'open in another program'
        ($warnings -join ' ') | Should -Not -Match 'lost its columns'
    }

    It 'warns about a damaged file, and leaves it alone' {
        $folder = New-TcTestFolder
        $path = Join-Path $folder 'team-tracking.csv'
        [System.IO.File]::WriteAllText($path, "this is not the header`r`n1,2,3`r`n")
        $warnings = @()
        $result = New-TcReport -Project $script:Fixture['Project'] -Snapshot $script:Fixture['Snapshot'] -Plan $script:Fixture['Plan'] -RuleSet $script:Fixture['RuleSet'] -OutputPath $folder -WarningVariable warnings -WarningAction SilentlyContinue
        ($warnings -join ' ') | Should -Match 'columns'
        $result.TrackingRows | Should -Be 0
        [System.IO.File]::ReadAllText($path) | Should -Be "this is not the header`r`n1,2,3`r`n"
    }
}

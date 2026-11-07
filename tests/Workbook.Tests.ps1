BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Support/WorkbookFixtures.ps1')
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')
    . (Join-Path $PSScriptRoot 'Support/WorkbookFixtures.ps1')
    . (Join-Path $PSScriptRoot 'Support/WorkbookReader.ps1')

    $script:Fake = @{}
    $script:Sets = @{}
    $script:Plans = @{}
    $script:Books = @{}
    foreach ($count in 1, 2, 3) {
        $script:Fake[$count] = Get-TcFakeSnapshot -SourceCount $count -Folder $TestDrive
        $script:Sets[$count] = Invoke-TcRuleSet -Snapshot $script:Fake[$count]
        $project = New-TcWorkbookProject -SourceCount $count
        $script:Plans[$count] = Remove-TcPlanRemediation -Plan (New-TcPlan -Project $project -Snapshot $script:Fake[$count] -RuleSet $script:Sets[$count])
        $path = New-TcWorkbook -Project $project -Snapshot $script:Fake[$count] -Plan $script:Plans[$count] -RuleSet $script:Sets[$count] -OutputPath (Join-Path $TestDrive "book-$count.xlsx")
        $script:Books[$count] = Read-TcXlsx -Path $path
    }

    # Most tests are not about size: a small plan keeps them quick.
    $script:Small = Get-TcSmallPlan -Plan $script:Plans[1]
    $script:LightPlan = Get-TcSmallPlan -Plan $script:Plans[2] -Actions 120 -Tasks 20
    $script:Light = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject -SourceCount 2) -Snapshot $script:Fake[2] -Plan $script:LightPlan -RuleSet $script:Sets[2] -OutputPath (Join-Path $TestDrive 'light.xlsx'))

    # Two sources, the second with nothing collected.
    $script:Nothing = $script:Fake[2] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
    Clear-TcWorkbookTenant -Snapshot $script:Nothing -Role 'S2'
    $script:NothingProject = New-TcWorkbookProject -SourceCount 2
    $script:NothingPlan = New-TcPlan -Project $script:NothingProject -Snapshot $script:Nothing
    $script:NothingBook = Read-TcXlsx -Path (New-TcWorkbook -Project $script:NothingProject -Snapshot $script:Nothing -Plan $script:NothingPlan -OutputPath (Join-Path $TestDrive 'nothing.xlsx'))

    # A plan with nothing in it.
    $plan = Get-TcSmallPlan -Plan $script:Plans[1]
    $plan['actions'] = @(); $plan['tasks'] = @(); $plan['targetConfigurations'] = @(); $plan['decisions'] = @(); $plan['procedures'] = @{}
    $script:EmptyBook = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $plan -RuleSet $script:Sets[1] -OutputPath (Join-Path $TestDrive 'emptyplan2.xlsx'))
}

Describe 'ConvertTo-TcWorkbookText' {
    It 'keeps ordinary text, accents and line breaks' {
        InModuleScope TenantConverge {
            $text = "H$([char]0xE9)l$([char]0xE8)ne`nline two`ttab"
            ConvertTo-TcWorkbookText $text | Should -BeExactly $text
        }
    }

    It 'reads nothing as an empty text' {
        InModuleScope TenantConverge { ConvertTo-TcWorkbookText $null | Should -BeExactly '' }
    }

    It 'removes the control characters XML cannot hold' {
        InModuleScope TenantConverge { ConvertTo-TcWorkbookText "a$([char]1)b$([char]0x1F)c$([char]0xFFFE)d" | Should -BeExactly 'abcd' }
    }

    It 'replaces half of a surrogate pair, which stops the save' {
        InModuleScope TenantConverge {
            ConvertTo-TcWorkbookText "a$([char]0xD83D)b" | Should -BeExactly "a$([char]0xFFFD)b"
            ConvertTo-TcWorkbookText "a$([char]0xDE00)b" | Should -BeExactly "a$([char]0xFFFD)b"
        }
    }

    It 'keeps a whole surrogate pair' {
        InModuleScope TenantConverge {
            $emoji = [char]::ConvertFromUtf32(0x1F600)
            ConvertTo-TcWorkbookText "a$($emoji)b" | Should -BeExactly "a$($emoji)b"
        }
    }

    It 'makes one line break of a Windows line break' {
        InModuleScope TenantConverge { ConvertTo-TcWorkbookText "a`r`nb`rc" | Should -BeExactly "a`nb`nc" }
    }

    It 'cuts at the limit of a cell, and says so' {
        InModuleScope TenantConverge {
            $text = ConvertTo-TcWorkbookText ('x' * 40000)
            $text.Length | Should -Be 32767
            $text | Should -Match 'cut: 40000 characters in all'
        }
    }

    It 'leaves a text of exactly the limit alone' {
        InModuleScope TenantConverge { (ConvertTo-TcWorkbookText ('x' * 32767)) | Should -BeExactly ('x' * 32767) }
    }

    It 'never cuts through a surrogate pair' {
        InModuleScope TenantConverge {
            $emoji = [char]::ConvertFromUtf32(0x1F600)
            foreach ($padding in 0, 1) {
                $text = ConvertTo-TcWorkbookText (('y' * $padding) + (($emoji) * 20000))
                $text.Length | Should -BeLessOrEqual 32767
                (ConvertTo-TcWorkbookText $text) | Should -BeExactly $text
            }
        }
    }
}

Describe 'New-TcWorkbook, the file' {
    It 'names the file consolidation-workbook.xlsx in a folder that is given' {
        $folder = Join-Path $TestDrive 'named'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $path = New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1] -OutputPath $folder
        $path | Should -Be (Join-Path $folder 'consolidation-workbook.xlsx')
        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It 'writes in the output folder of the project by default, next to the project file' {
        $folder = Join-Path $TestDrive 'byproject'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $file = Join-Path $folder 'project.json'
        New-TcWorkbookProject -OutputPath './out' | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding utf8
        $path = New-TcWorkbook -Project $file -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1]
        $path | Should -Be (Join-Path (Join-Path $folder 'out') 'consolidation-workbook.xlsx')
        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It 'computes what it is not given' {
        $path = New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -OutputPath (Join-Path $TestDrive 'computed.xlsx')
        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It 'writes nothing with -WhatIf' {
        $path = Join-Path $TestDrive 'whatif.xlsx'
        New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1] -OutputPath $path -WhatIf
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'says what to do when ImportExcel is missing' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { $null }
        { New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1] -OutputPath (Join-Path $TestDrive 'nomodule.xlsx') } |
            Should -Throw '*ImportExcel*Test-TcPrerequisite -Service Workbook -Install*'
    }

    It 'finds an ImportExcel installed after this session last looked for it' {
        InModuleScope TenantConverge {
            $script:TcModuleVersions['ImportExcel|False'] = $null
            { Import-TcWorkbookModule } | Should -Not -Throw
            $script:TcModuleVersions['ImportExcel|False'] | Should -Not -BeNullOrEmpty
        }
    }

    It 'finds a newer ImportExcel when this session last saw one too old' {
        InModuleScope TenantConverge {
            $script:TcModuleVersions['ImportExcel|False'] = [version]'1.0'
            { Import-TcWorkbookModule } | Should -Not -Throw
            $script:TcModuleVersions['ImportExcel|False'] | Should -BeGreaterThan ([version]'1.0')
        }
    }

    It 'says what to do when the file is open elsewhere, and leaves it as it was, with no temporary file' {
        $folder = Join-Path $TestDrive 'locked'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $path = Join-Path $folder 'consolidation-workbook.xlsx'
        Set-Content -LiteralPath $path -Value 'kept' -NoNewline
        $lock = [System.IO.File]::Open($path, 'Open', 'Read', 'None')
        try {
            { New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1] -OutputPath $path } |
                Should -Throw '*open in another program*-OutputPath*'
        }
        finally { $lock.Dispose() }
        Get-Content -LiteralPath $path -Raw | Should -BeExactly 'kept'
        @(Get-ChildItem -LiteralPath $folder -Force).Count | Should -Be 1
    }

    It 'keeps the workbook it replaces, whose status columns a team may have filled' {
        $folder = Join-Path $TestDrive 'replaced'
        New-Item -ItemType Directory -Path $folder | Out-Null
        $path = Join-Path $folder 'consolidation-workbook.xlsx'
        Set-Content -LiteralPath $path -Value 'filled by the team' -NoNewline
        Mock Write-TcMessage -ModuleName TenantConverge
        New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1] -OutputPath $path | Out-Null
        $kept = @(Get-ChildItem -LiteralPath $folder -Filter 'consolidation-workbook-previous-*.xlsx')
        $kept.Count | Should -Be 1
        Get-Content -LiteralPath $kept[0].FullName -Raw | Should -BeExactly 'filled by the team'
        (Read-TcXlsx -Path $path).Sheets.Count | Should -BeGreaterThan 0
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'previous' }
    }

    Context 'what does not carry over from a replaced workbook' {
        BeforeAll {
            $script:YellowColumns = @(
                'Action plan (Status, Assigned to, Note, Done on)'
                'Detailed steps (Status, Done on, Note)'
                'Target configurations (Applied, Done on, Note)'
                'Identity matrix (Validated decision, License, Groups, Validated by, Validated on)'
                'Decisions (Status, Answer, Decided by, Date)'
            )
            $script:Replace = {
                param([string]$Folder, [switch]$Existing)
                New-Item -ItemType Directory -Path $Folder | Out-Null
                $path = Join-Path $Folder 'consolidation-workbook.xlsx'
                if ($Existing) { Set-Content -LiteralPath $path -Value 'filled by the team' -NoNewline }
                New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1] -OutputPath $path -InformationVariable said | Out-Null
                @($said | ForEach-Object { $_.MessageData.Message }) -join ' '
            }
        }

        It 'warns that the yellow columns are not in the new workbook, and names them' {
            $text = & $script:Replace (Join-Path $TestDrive 'warned') -Existing
            $text | Should -Match 'yellow columns'
            foreach ($column in $script:YellowColumns) { $text | Should -Match ([regex]::Escape($column)) }
        }

        It 'says that the previous file is the only copy' {
            $text = & $script:Replace (Join-Path $TestDrive 'onlycopy') -Existing
            $kept = @(Get-ChildItem -LiteralPath (Join-Path $TestDrive 'onlycopy') -Filter 'consolidation-workbook-previous-*.xlsx')[0]
            $text | Should -Match ([regex]::Escape($kept.FullName))
            $text | Should -Match 'only copy'
        }

        It 'says nothing about it when no workbook was replaced' {
            & $script:Replace (Join-Path $TestDrive 'firsttime') | Should -Not -Match 'yellow columns'
        }

        It 'says the same in the help' {
            $help = ((Get-Help New-TcWorkbook -Full).description.Text -join ' ') -replace '\s+', ' '
            $help | Should -Match 'yellow columns do not carry over'
            $help | Should -Match 'only copy'
            foreach ($column in $script:YellowColumns) { $help | Should -Match ([regex]::Escape($column)) }
        }
    }

    It 'leaves no temporary file next to the workbook' {
        @(Get-ChildItem -LiteralPath $TestDrive -Force -Filter '*.tmp*').Count | Should -Be 0
    }
}

Describe 'New-TcWorkbook, the metadata' {
    It 'gives TenantConverge as author, company and last editor' {
        foreach ($count in 1, 2, 3) {
            $properties = $script:Books[$count].Properties
            $properties['creator'] | Should -BeExactly 'TenantConverge'
            $properties['lastModifiedBy'] | Should -BeExactly 'TenantConverge'
            $properties['Company'] | Should -BeExactly 'TenantConverge'
        }
    }

    It 'never holds the Windows user name' {
        foreach ($name in 'docProps/core.xml', 'docProps/app.xml', 'docProps/custom.xml', 'xl/workbook.xml') {
            $text = $script:Books[3].Parts[$name]
            if ($text) { $text | Should -Not -Match ([regex]::Escape($env:USERNAME)) -Because $name }
        }
    }
}

Describe 'New-TcWorkbook, the tabs' {
    It 'has the tabs of the plan, in order, with no Remediations tab for an empty list' {
        foreach ($count in 1, 2, 3) {
            @($script:Books[$count].Sheets.Keys) | Should -Be @('Dashboard', 'Tenant view', 'Action plan', 'Detailed steps', 'Target configurations', 'Identity matrix', 'Decisions', 'Settings')
        }
    }

    It 'gives every tab a name Excel accepts' {
        foreach ($name in $script:Books[3].Sheets.Keys) {
            $name.Length | Should -BeLessOrEqual 31
            $name | Should -Not -Match '[\[\]:*?/\\]'
        }
    }
}

Describe 'New-TcWorkbook, the action plan' {
    BeforeAll {
        $script:Rows = @(Get-TcXlsxRow -Book $script:Books[2] -Table 'ActionPlan')
        $script:Plan = $script:Plans[2]
    }

    It 'has one row per action and per task' {
        foreach ($count in 1, 2, 3) {
            @(Get-TcXlsxRow -Book $script:Books[$count] -Table 'ActionPlan').Count | Should -Be (@($script:Plans[$count]['actions']).Count + @($script:Plans[$count]['tasks']).Count)
        }
    }

    It 'tells actions from tasks' {
        @($script:Rows | Where-Object { $_['Kind'] -eq 'Action' }).Count | Should -Be @($script:Plan['actions']).Count
        @($script:Rows | Where-Object { $_['Kind'] -eq 'Task' }).Count | Should -Be @($script:Plan['tasks']).Count
    }

    It 'carries what the plan says of an action' {
        $action = @($script:Plan['actions'] | Where-Object { $_['blocking'] -and $_['ruleId'] })[0]
        $row = @($script:Rows | Where-Object { $_['ID'] -eq $action['id'] })[0]
        $row['Tenant'] | Should -BeExactly $action['tenant']
        $row['Role'] | Should -BeExactly $action['role']
        $row['Moment'] | Should -BeExactly $action['moment']
        $row['What to do'] | Should -BeExactly $action['title']
        $row['Severity'] | Should -BeExactly $action['severity']
        $row['Blocking'] | Should -BeExactly 'Yes'
        $row['Owner'] | Should -BeExactly $action['owner']
        $row['Finding'] | Should -BeExactly $action['finding']
        $row['Why'] | Should -BeExactly $action['why']
        $row['Status'] | Should -BeExactly 'To do'
    }

    It 'says All tenants for a wave of two sources' {
        $project = New-TcWorkbookProject -SourceCount 2
        $project.sources[1].wave = 1
        $plan = New-TcPlan -Project $project -Snapshot $script:Fake[2] -RuleSet $script:Sets[2]
        $task = @($plan['tasks'] | Where-Object { $_['scope'] -eq 'Wave' })[0]
        $small = Get-TcSmallPlan -Plan $plan
        $small['tasks'] = @($task)
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project $project -Snapshot $script:Fake[2] -Plan $small -RuleSet $script:Sets[2] -OutputPath (Join-Path $TestDrive 'samewave.xlsx'))
        $row = @(Get-TcXlsxRow -Book $book -Table 'ActionPlan' | Where-Object { $_['ID'] -eq $task['id'] })[0]
        $row['Role'] | Should -BeExactly 'All'
        $row['Tenant'] | Should -BeExactly 'All tenants'
        [int]$row['Wave'] | Should -Be 1
    }

    It 'leaves Blocking empty when an action does not block' {
        $action = @($script:Plan['actions'] | Where-Object { -not $_['blocking'] })[0]
        (@($script:Rows | Where-Object { $_['ID'] -eq $action['id'] })[0])['Blocking'] | Should -BeNullOrEmpty
    }

    It 'names the tenant of a wave task when its wave has one source' {
        $task = @($script:Plan['tasks'] | Where-Object { $_['scope'] -eq 'Wave' })[0]
        $source = $task['sources'][0]
        $row = @($script:Rows | Where-Object { $_['ID'] -eq $task['id'] })[0]
        $row['Role'] | Should -BeExactly $source
        $row['Tenant'] | Should -BeExactly (@($script:Plan['tenants'] | Where-Object { $_['role'] -eq $source })[0]['displayName'])
    }

    It 'lists every item of an action, on one line' {
        $action = @($script:Plan['actions'] | Where-Object { @($_['items']).Count -ge 2 })[0]
        $row = @($script:Rows | Where-Object { $_['ID'] -eq $action['id'] })[0]
        $row['Item count'] | Should -Be $action['itemCount']
        foreach ($item in @($action['items'])) { $row['Items'] | Should -Match ([regex]::Escape($item)) }
    }

    It 'has no column that is empty for every row, apart from those for the team' {
        foreach ($count in 1, 2, 3) {
            $rows = @(Get-TcXlsxRow -Book $script:Books[$count] -Table 'ActionPlan')
            foreach ($column in $script:Books[$count].Tables['ActionPlan'].Columns) {
                if ($column -in 'Assigned to', 'Note', 'Done on', 'Blocking') { continue }
                @($rows | Where-Object { $_[$column] }).Count | Should -BeGreaterThan 0 -Because "$column in $count source(s)"
            }
        }
    }

    It 'has no Reason column when no task is unconfirmed' {
        $script:Books[2].Tables['ActionPlan'].Columns | Should -Not -Contain 'Reason'
    }

    It 'keeps an unconfirmed task visible, with its reason' {
        $tasks = @($script:NothingPlan['tasks'] | Where-Object { $_['confirmation'] -eq 'Unconfirmed' })
        $tasks.Count | Should -BeGreaterThan 0 -Because 'the fixture must hold such a task'

        $rows = @(Get-TcXlsxRow -Book $script:NothingBook -Table 'ActionPlan')
        foreach ($task in $tasks) {
            $row = @($rows | Where-Object { $_['ID'] -eq $task['id'] })[0]
            $row['Confirmation'] | Should -BeExactly 'Unconfirmed'
            $row['Reason'] | Should -BeExactly $task['reason']
        }
    }

    It 'writes a sentence, and no table, for a plan with nothing in it' {
        $script:EmptyBook.Tables.Contains('ActionPlan') | Should -BeFalse
        @($script:EmptyBook.Sheets['Action plan'].Cells.Values | Where-Object { $_.Value -match 'No action' }).Count | Should -BeGreaterThan 0
    }
}

Describe 'New-TcWorkbook, text that a spreadsheet would run or change' {
    BeforeAll {
        $plan = Get-TcSmallPlan -Plan $script:Plans[2] -Actions 25 -Tasks 10
        $script:Texts = @(Get-TcHostileText) + @(Get-TcFragileText)
        $script:TextIndex = 0
        $next = { $value = $script:Texts[$script:TextIndex % $script:Texts.Count]; $script:TextIndex++; $value }
        foreach ($action in @($plan['actions'])) {
            foreach ($key in 'title', 'finding', 'action', 'why', 'question') { $action[$key] = & $next }
            $action['items'] = @((& $next), 'second item')
        }
        foreach ($task in @($plan['tasks'])) { $task['title'] = & $next; $task['confirmation'] = 'Unconfirmed'; $task['reason'] = & $next }
        foreach ($row in @($plan['targetConfigurations'])) { foreach ($key in 'setting', 'current', 'target', 'where') { $row[$key] = & $next } }
        foreach ($row in @($plan['decisions'])) { $row['question'] = & $next }
        $path = New-TcWorkbook -Project (New-TcWorkbookProject -SourceCount 2) -Snapshot $script:Fake[2] -Plan $plan -RuleSet $script:Sets[2] -OutputPath (Join-Path $TestDrive 'hostile-plan.xlsx')
        $script:Hostile = Read-TcXlsx -Path $path
        $script:HostileCells = @(Get-TcXlsxAllCell -Book $script:Hostile)
    }

    It 'keeps <_> as a plain text cell' -ForEach @(Get-TcHostileText) {
        $text = $_
        $cells = @($script:HostileCells | Where-Object { $_.Value -ceq $text -and -not $_.Formula })
        $cells.Count | Should -BeGreaterThan 0
        foreach ($cell in $cells) {
            $cell.Type | Should -Be 's'
            $cell.Formula | Should -BeNullOrEmpty
            $cell.Format | Should -Be '@'
        }
    }

    It 'marks <_> so that pressing Enter in the cell does not run it' -ForEach @(Get-TcHostileText | Where-Object { $_ -notmatch '^(http|<)' }) {
        $text = $_
        foreach ($cell in @($script:HostileCells | Where-Object { $_.Value -ceq $text -and -not $_.Formula })) { $cell.Quote | Should -BeTrue -Because "$($cell.Sheet)!$($cell.Address)" }
    }

    It 'keeps <_> exactly as it was typed, as text' -ForEach @(Get-TcFragileText) {
        $text = $_
        $cells = @($script:HostileCells | Where-Object { $_.Value -ceq $text -and -not $_.Formula })
        $cells.Count | Should -BeGreaterThan 0
        foreach ($cell in $cells) {
            $cell.Type | Should -Be 's'
            $cell.Format | Should -Be '@'
        }
    }

    It 'shows a hostile value in the list of the Tenant view as the text result of a formula of the module' {
        $shown = @($script:HostileCells | Where-Object { $_.Sheet -eq 'Tenant view' -and $_.Formula -and $_.Value -ceq '=1+1' })
        $shown.Count | Should -BeGreaterThan 0
        foreach ($cell in $shown) {
            $cell.Type | Should -Be 'str'
            $cell.Formula | Should -Match 'T\(INDEX\('
        }
    }

    It 'makes no formula out of a tenant value' {
        foreach ($cell in @($script:HostileCells | Where-Object { $_.Formula })) {
            $cell.Formula | Should -Not -Match 'evil|calc|onerror|1\+1|2\+3' -Because "$($cell.Sheet)!$($cell.Address)"
        }
    }

    It 'makes no link out of a tenant value' {
        foreach ($sheet in $script:Hostile.Sheets.Values) {
            foreach ($link in $sheet.Links) { $link.External | Should -BeNullOrEmpty -Because "$($sheet.Name)!$($link.Cell)" }
        }
        foreach ($part in @($script:Hostile.Parts.Keys | Where-Object { $_ -match 'sheet\d+\.xml\.rels$' })) { $script:Hostile.Parts[$part] | Should -Not -Match 'evil' }
    }
}

Describe 'New-TcWorkbook, text that does not fit' {
    BeforeAll {
        $plan = Get-TcSmallPlan -Plan $script:Plans[1]
        @($plan['actions'])[0]['finding'] = 'x' * 40000
        @($plan['actions'])[0]['items'] = @(1..4000 | ForEach-Object { "item number $_ with a long enough name" })
        @($plan['actions'])[1]['finding'] = "broken$([char]0xD83D)pair and$([char]1)control"
        $script:Long = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $plan -RuleSet $script:Sets[1] -OutputPath (Join-Path $TestDrive 'long.xlsx'))
        $script:LongRows = @(Get-TcXlsxRow -Book $script:Long -Table 'ActionPlan')
    }

    It 'keeps every cell within what Excel holds' {
        foreach ($cell in @(Get-TcXlsxAllCell -Book $script:Long)) { ([string]$cell.Value).Length | Should -BeLessOrEqual 32767 }
    }

    It 'says that it cut a text' {
        $script:LongRows[0]['Finding'] | Should -Match 'cut: 40000 characters in all'
        $script:LongRows[0]['Items'] | Should -Match 'cut: \d+ characters in all'
    }

    It 'still writes a text with half of a surrogate pair and a control character' {
        $script:LongRows[1]['Finding'] | Should -BeExactly "broken$([char]0xFFFD)pair andcontrol"
    }
}

Describe 'New-TcWorkbook, the detailed steps' {
    BeforeAll {
        $script:Steps = @(Get-TcXlsxRow -Book $script:Light -Table 'DetailedSteps')
        $script:Plan = $script:LightPlan
        $script:Actions = @(Get-TcXlsxRow -Book $script:Light -Table 'ActionPlan')
        $script:Sample = @($script:Plan['actions'] | Where-Object { $_['procedure'] -and @($script:Plan['procedures'][$_['procedure']]['risks']).Count -and @($script:Plan['procedures'][$_['procedure']]['verification']).Count })[0]
        $script:Procedure = $script:Plan['procedures'][$script:Sample['procedure']]
        $script:Lines = @($script:Steps | Where-Object { $_['Item'] -eq $script:Sample['id'] })

        # Sets steps of the sample item to Done, recalculates, and reads how far it stands on its row, on the
        # row of its tenant in the Dashboard, and in the tile.
        $script:MarkDone = {
            param([object[]]$Line)
            $book = $script:Light
            $row = @($script:Actions | Where-Object { $_['ID'] -eq $script:Sample['id'] })[0]
            $status = Get-TcXlsxColumnLetter -Book $book -Table 'DetailedSteps' -Column 'Status'
            $cells = @($book.Sheets['Dashboard'].Cells.Values)
            $labels = @($cells | Where-Object { $_.Value -ceq 'Steps done' })
            $tile = @($cells | Where-Object { $_.Row -eq $labels[0].Row + 1 -and $_.Column -eq $labels[0].Column })[0]
            $tenant = @($cells | Where-Object { $_.Row -gt $labels[1].Row -and $_.Column -eq 2 -and $_.Value -ceq $row['Role'] })[0].Row
            $progress = @($cells | Where-Object { $_.Row -eq $labels[1].Row -and $_.Value -ceq 'Progress' })[0]
            $read = Invoke-TcXlsxRecalculation -Path $book.Path -Change @($Line | ForEach-Object { @{ Sheet = 'Detailed steps'; Address = "$status$($_['#Row'])"; Value = 'Done' } }) -Read @(
                @{ Sheet = 'Action plan'; Address = "$(Get-TcXlsxColumnLetter -Book $book -Table 'ActionPlan' -Column 'Steps done')$($row['#Row'])" }
                @{ Sheet = 'Action plan'; Address = "$(Get-TcXlsxColumnLetter -Book $book -Table 'ActionPlan' -Column 'Progress')$($row['#Row'])" }
                @{ Sheet = 'Dashboard'; Address = @($cells | Where-Object { $_.Row -eq $tenant -and $_.Column -eq $labels[1].Column })[0].Address }
                @{ Sheet = 'Dashboard'; Address = @($cells | Where-Object { $_.Row -eq $tenant -and $_.Column -eq $progress.Column })[0].Address }
                @{ Sheet = 'Dashboard'; Address = $tile.Address })
            @{ StepsDone = [int]$read[0]; Progress = [double]$read[1]; TenantDone = [int]$read[2]; TenantProgress = [double]$read[3]; Tile = [string]$read[4]; Count = [int]$row['Steps'] }
        }
        $script:ToTick = @($script:Steps | Where-Object { $_['Type'] -ne 'Watch point' }).Count
    }

    It 'lists the prerequisites, the watch points, the steps and the checks of a procedure, in that order' {
        $expected = @(@($script:Procedure['prerequisites'] | ForEach-Object { 'Prerequisite' }) + @($script:Procedure['risks'] | ForEach-Object { 'Watch point' }) + @($script:Procedure['steps'] | ForEach-Object { 'Step' }) + @($script:Procedure['verification'] | ForEach-Object { 'Verification' }))
        @($script:Lines | ForEach-Object { $_['Type'] }) | Should -Be $expected
        @($script:Lines | ForEach-Object { [int]$_['No.'] }) | Should -Be @(1..$expected.Count)
    }

    It 'gives the text, the place and the command of a step' {
        $step = @($script:Procedure['steps'])[0]
        $line = @($script:Lines | Where-Object { $_['Type'] -eq 'Step' })[0]
        $line['What to do'] | Should -BeExactly $step['text']
        $line['Where'] | Should -BeExactly $step['where']
        if ($step['command']) { $line['Command'] | Should -BeExactly $step['command'] }
    }

    It 'names the tenant and the moment of the item' {
        $script:Lines[0]['Tenant'] | Should -BeExactly $script:Sample['tenant']
        $script:Lines[0]['Moment'] | Should -BeExactly $script:Sample['moment']
    }

    It 'leaves a watch point to read, and everything else to do' {
        @($script:Lines | Where-Object { $_['Type'] -eq 'Watch point' } | ForEach-Object { $_['Status'] } | Sort-Object -Unique) | Should -Be @('To read')
        @($script:Lines | Where-Object { $_['Type'] -ne 'Watch point' } | ForEach-Object { $_['Status'] } | Sort-Object -Unique) | Should -Be @('To do')
    }

    It 'covers the tasks too' {
        $task = @($script:Plan['tasks'] | Where-Object { $_['procedure'] })[0]
        @($script:Steps | Where-Object { $_['Item'] -eq $task['id'] }).Count | Should -BeGreaterThan 0
    }

    It 'counts in the action plan the steps to tick, not the watch points' {
        $row = @($script:Actions | Where-Object { $_['ID'] -eq $script:Sample['id'] })[0]
        $count = @($script:Procedure['prerequisites']).Count + @($script:Procedure['steps']).Count + @($script:Procedure['verification']).Count
        [int]$row['Steps done'] | Should -Be 0
        [int]$row['Steps'] | Should -Be $count
        [double]$row['Progress'] | Should -Be 0
    }

    It 'moves the progress of an item when a step is done' {
        $row = @($script:Actions | Where-Object { $_['ID'] -eq $script:Sample['id'] })[0]
        $count = @($script:Procedure['prerequisites']).Count + @($script:Procedure['steps']).Count + @($script:Procedure['verification']).Count
        $book = $script:Light
        $status = @($book.Sheets['Detailed steps'].Cells.Values | Where-Object { $_.Value -eq 'To do' -and $_.Row -eq $script:Lines[0]['#Row'] })[0]
        $letters = @{ Progress = Get-TcXlsxColumnLetter -Book $book -Table 'ActionPlan' -Column 'Progress'; Done = Get-TcXlsxColumnLetter -Book $book -Table 'ActionPlan' -Column 'Steps done' }
        $result = Invoke-TcXlsxRecalculation -Path $book.Path -Change @(@{ Sheet = 'Detailed steps'; Address = $status.Address; Value = 'Done' }) -Read @(
            @{ Sheet = 'Action plan'; Address = "$($letters['Progress'])$($row['#Row'])" }, @{ Sheet = 'Action plan'; Address = "$($letters['Done'])$($row['#Row'])" })
        [double]$result[0] | Should -BeGreaterThan (1 / $count - 0.000001) -Because 'one line of the procedure is done'
        [double]$result[0] | Should -BeLessThan (1 / $count + 0.000001) -Because 'one line of the procedure is done'
        [double]$result[1] | Should -Be 1
    }

    It 'never counts a watch point marked Done, on the item, the tenant or the Dashboard' {
        $watch = @($script:Lines | Where-Object { $_['Type'] -eq 'Watch point' })
        $watch.Count | Should -BeGreaterThan 0 -Because 'the sample item must hold a watch point'
        $result = & $script:MarkDone $watch
        $result['StepsDone'] | Should -Be 0
        $result['Progress'] | Should -Be 0
        $result['TenantDone'] | Should -Be 0
        $result['TenantProgress'] | Should -Be 0
        $result['Tile'] | Should -BeExactly "0 / $($script:ToTick)"
    }

    It 'counts a step done next to a watch point marked Done, once, everywhere' {
        $watch = @($script:Lines | Where-Object { $_['Type'] -eq 'Watch point' })[0]
        $step = @($script:Lines | Where-Object { $_['Type'] -eq 'Step' })[0]
        $result = & $script:MarkDone @($watch, $step)
        $result['StepsDone'] | Should -Be 1
        $result['Progress'] | Should -BeGreaterThan (1 / $result['Count'] - 0.000001)
        $result['Progress'] | Should -BeLessThan (1 / $result['Count'] + 0.000001)
        $result['TenantDone'] | Should -Be 1
        $result['TenantProgress'] | Should -BeGreaterThan 0
        $result['Tile'] | Should -BeExactly "1 / $($script:ToTick)"
    }

    It 'keeps the column that tells a step from a watch point out of sight, and out of the table' {
        $book = $script:Light
        $columns = $book.Tables['DetailedSteps'].Columns
        $columns | Should -Not -Contain 'Ticked'
        $header = @($book.Sheets['Detailed steps'].Cells.Values | Where-Object { $_.Value -ceq 'Ticked' })[0]
        $header.Column | Should -BeGreaterThan ($columns.Count + 1) -Because 'one column stays free, so the table does not grow into it'
        $book.Sheets['Detailed steps'].HiddenColumns | Should -Contain $header.Column
    }

    It 'offers a link to the steps only to an item that has some' {
        $with = @($script:Actions | Where-Object { [int]$_['Steps'] -gt 0 })[0]
        $with['Open'] | Should -BeExactly 'Open'
        $without = @($script:Plan['actions'] | Where-Object { -not $_['procedure'] })
        foreach ($action in $without) { (@($script:Actions | Where-Object { $_['ID'] -eq $action['id'] })[0])['Open'] | Should -BeNullOrEmpty }
        $without.Count | Should -BeGreaterThan 0 -Because 'the plan must hold such an action'
    }

    It 'says an item is complete when its own status is Done, whatever its steps' {
        $row = @($script:Actions | Where-Object { $_['ID'] -eq $script:Sample['id'] })[0]
        $book = $script:Light
        $status = Get-TcXlsxColumnLetter -Book $book -Table 'ActionPlan' -Column 'Status'
        $progress = Get-TcXlsxColumnLetter -Book $book -Table 'ActionPlan' -Column 'Progress'
        $result = Invoke-TcXlsxRecalculation -Path $book.Path -Change @(@{ Sheet = 'Action plan'; Address = "$status$($row['#Row'])"; Value = 'Done' }) -Read @(@{ Sheet = 'Action plan'; Address = "$progress$($row['#Row'])" })
        [double]$result[0] | Should -Be 1
    }
}

Describe 'New-TcWorkbook, the target configurations' {
    BeforeAll {
        $script:Rows = @(Get-TcXlsxRow -Book $script:Books[2] -Table 'TargetConfigurations')
        $script:Plan = $script:Plans[2]
    }

    It 'has one row per setting of the plan' {
        foreach ($count in 1, 2, 3) {
            @(Get-TcXlsxRow -Book $script:Books[$count] -Table 'TargetConfigurations').Count | Should -Be @($script:Plans[$count]['targetConfigurations']).Count
        }
    }

    It 'carries a setting, with the team still to apply it' {
        $setting = @($script:Plan['targetConfigurations'] | Where-Object { $_['current'] -and $_['action'] })[0]
        $row = @($script:Rows | Where-Object { $_['Setting'] -ceq $setting['setting'] -and $_['Role'] -eq $setting['role'] -and $_['Action'] -eq $setting['action'] })[0]
        $row['Current'] | Should -BeExactly $setting['current']
        $row['Target'] | Should -BeExactly $setting['target']
        $row['Where'] | Should -BeExactly $setting['where']
        $row['Origin'] | Should -BeExactly $setting['origin']
        $row['Applied'] | Should -BeExactly 'No'
    }

    It 'says a value was not measured rather than leaving it empty' {
        $missing = @($script:Plan['targetConfigurations'] | Where-Object { -not $_['current'] }).Count
        $missing | Should -BeGreaterThan 0
        @($script:Rows | Where-Object { $_['Current'] -eq 'Not measured' }).Count | Should -Be $missing
    }

    It 'opens the action of a setting, and offers nothing without one' {
        (@($script:Rows | Where-Object { $_['Action'] })[0])['Open'] | Should -BeExactly 'Open'
        (@($script:Rows | Where-Object { -not $_['Action'] })[0])['Open'] | Should -BeNullOrEmpty
    }
}

Describe 'New-TcWorkbook, the decisions' {
    BeforeAll {
        $script:Rows = @(Get-TcXlsxRow -Book $script:Books[2] -Table 'Decisions')
        $script:Plan = $script:Plans[2]
    }

    It 'has one row per decision, open' {
        $script:Rows.Count | Should -Be @($script:Plan['decisions']).Count
        @($script:Rows | ForEach-Object { $_['Status'] } | Sort-Object -Unique) | Should -Be @('Open')
    }

    It 'carries the question and names the tenant' {
        $decision = @($script:Plan['decisions'])[0]
        $row = @($script:Rows | Where-Object { $_['ID'] -eq $decision['id'] })[0]
        $row['Question'] | Should -BeExactly $decision['question']
        $row['Tenant'] | Should -BeExactly (@($script:Plan['tenants'] | Where-Object { $_['role'] -eq $decision['role'] })[0]['displayName'])
        $row['Reference'] | Should -BeExactly $decision['reference']
    }

    It 'calls a decision on all tenants so' {
        $decision = @($script:Plan['decisions'] | Where-Object { $_['role'] -eq 'All' })[0]
        (@($script:Rows | Where-Object { $_['ID'] -eq $decision['id'] })[0])['Tenant'] | Should -BeExactly 'All tenants'
    }
}

Describe 'New-TcWorkbook, the identity matrix' {
    BeforeAll {
        $script:Rows = @(Get-TcXlsxRow -Book $script:Books[2] -Table 'IdentityMatrix')
        $script:Draft = InModuleScope TenantConverge -Parameters @{ Snapshot = $script:Fake[2] } {
            param($Snapshot)
            @(ConvertTo-TcIdentityMatrix -Snapshot $Snapshot -SourceRole 'S1') + @(ConvertTo-TcIdentityMatrix -Snapshot $Snapshot -SourceRole 'S2')
        }
    }

    It 'has one row per account of the draft of each source' {
        $script:Rows.Count | Should -Be $script:Draft.Count
    }

    It 'carries the draft and leaves the decision to the customer' {
        $line = @($script:Draft | Where-Object { $_['Decision'] -eq 'Duplicate' })[0]
        $row = @($script:Rows | Where-Object { $_['Source UPN'] -eq $line['Source UPN'] })[0]
        $row['Display name'] | Should -BeExactly $line['Display name']
        $row['Proposed decision'] | Should -BeExactly 'Duplicate'
        $row['Target UPN'] | Should -BeExactly $line['Target UPN']
        $row['Notes'] | Should -BeExactly $line['Notes']
        $row['Validated decision'] | Should -BeNullOrEmpty
    }

    It 'keeps the names of a hostile tenant as text, and numbers that are not numbers' {
        $snapshot = New-TcHostileSnapshot -Snapshot $script:Fake[1]
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $snapshot -OutputPath (Join-Path $TestDrive 'hostile-snapshot.xlsx'))
        $cells = @($book.Sheets['Identity matrix'].Cells.Values)
        foreach ($text in @(Get-TcHostileText) + @(Get-TcFragileText)) {
            $found = @($cells | Where-Object { $_.Value -ceq $text })
            $found.Count | Should -BeGreaterThan 0 -Because $text
            foreach ($cell in $found) {
                $cell.Type | Should -Be 's'
                $cell.Formula | Should -BeNullOrEmpty
            }
        }
        foreach ($cell in @(Get-TcXlsxAllCell -Book $book | Where-Object { $_.Formula })) { $cell.Formula | Should -Not -Match 'evil|calc|onerror' }
    }

    It 'says why a source has no draft' {
        $action = @($script:NothingPlan['actions'] | Where-Object { $_['id'] -eq 'S2-IDENTITY-MATRIX' })[0]
        $action['drafted'] | Should -BeFalse
        $rows = @(Get-TcXlsxRow -Book $script:NothingBook -Table 'IdentityMatrix')
        $gap = @($rows | Where-Object { $_['Role'] -eq 'S2' })
        $gap.Count | Should -Be 1
        $gap[0]['Proposed decision'] | Should -BeExactly 'No draft'
        $gap[0]['Notes'] | Should -BeExactly $action['finding']
        @($rows | Where-Object { $_['Role'] -eq 'S1' }).Count | Should -BeGreaterThan 0
    }

    It 'proposes no creation when the accounts of the target were not read' {
        $snapshot = $script:Fake[1] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        Clear-TcWorkbookTenant -Snapshot $snapshot -Role 'Target'
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $snapshot -OutputPath (Join-Path $TestDrive 'notarget.xlsx'))
        $rows = @(Get-TcXlsxRow -Book $book -Table 'IdentityMatrix')
        @($rows | Where-Object { $_['Proposed decision'] -eq 'Create' }).Count | Should -Be 0
        @($rows | Where-Object { $_['Proposed decision'] -eq 'To review' -and $_['Notes'] -match 'accounts of the target were not read' }).Count | Should -Be $rows.Count
    }
}

Describe 'New-TcWorkbook, the remediations' {
    BeforeAll {
        $script:Banner = 'UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.'
        $plan = Get-TcSmallPlan -Plan $script:Plans[1]
        $plan['remediations'] = @(
            [ordered]@{ id = 'REM-ONE'; title = 'First fix'; workload = 'Entra ID'; ruleIds = @('ENT-A', 'ENT-B'); nature = 'Decision'; risk = 'High'; reversible = $false; permissions = @('User.ReadWrite.All', 'Group.ReadWrite.All'); testedOnRealTenant = $false; testedEvidence = $null }
            [ordered]@{ id = 'REM-TWO'; title = '=1+1'; workload = 'Teams'; ruleIds = @(); nature = 'Report'; risk = 'Low'; reversible = $true; permissions = @(); testedOnRealTenant = $true; testedEvidence = '2026-11-01, test tenant A' }
            [ordered]@{ id = 'REM-THREE'; title = 'Claims a test'; workload = 'Teams'; ruleIds = @(); nature = 'Partial'; risk = 'Medium'; reversible = $true; permissions = @(); testedOnRealTenant = $true; testedEvidence = $null }
        )
        @($plan['actions'])[0]['remediations'] = @('REM-ONE', 'REM-TWO')
        @($plan['actions'])[1]['remediations'] = @('REM-GONE')
        $script:RemediationBook = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $plan -RuleSet $script:Sets[1] -OutputPath (Join-Path $TestDrive 'remediations.xlsx'))
        $script:Rows = @(Get-TcXlsxRow -Book $script:RemediationBook -Table 'Remediations')
        $script:Items = @(Get-TcXlsxRow -Book $script:RemediationBook -Table 'ActionPlan')
        $script:PlanWith = $plan
    }

    It 'adds the tab, after the target configurations' {
        @($script:RemediationBook.Sheets.Keys) | Should -Be @('Dashboard', 'Tenant view', 'Action plan', 'Detailed steps', 'Target configurations', 'Remediations', 'Identity matrix', 'Decisions', 'Settings')
    }

    It 'shows the exact warning of the project' {
        @($script:RemediationBook.Sheets['Remediations'].Cells.Values | Where-Object { $_.Value -ceq $script:Banner }).Count | Should -Be 1
    }

    It 'has one row per remediation, with what it says' {
        $script:Rows.Count | Should -Be 3
        $row = $script:Rows[0]
        $row['ID'] | Should -BeExactly 'REM-ONE'
        $row['Title'] | Should -BeExactly 'First fix'
        $row['Workload'] | Should -BeExactly 'Entra ID'
        $row['Rules'] | Should -BeExactly 'ENT-A, ENT-B'
        $row['Nature'] | Should -BeExactly 'Decision'
        $row['Risk'] | Should -BeExactly 'High'
        $row['Reversible'] | Should -BeExactly 'No'
        $row['Permissions'] | Should -BeExactly 'User.ReadWrite.All, Group.ReadWrite.All'
        $row['Test status'] | Should -BeExactly 'Untested'
    }

    It 'gives a tested remediation its evidence' {
        $script:Rows[1]['Test status'] | Should -BeExactly 'Tested'
        $script:Rows[1]['Test evidence'] | Should -BeExactly '2026-11-01, test tenant A'
    }

    It 'does not believe a test with no evidence' {
        $script:Rows[2]['Test status'] | Should -BeExactly 'Untested'
    }

    It 'lists the actions a remediation serves' {
        $id = @($script:PlanWith['actions'])[0]['id']
        $script:Rows[0]['Actions'] | Should -BeExactly $id
    }

    It 'shows the remediations of an action, with their badge' {
        $id = @($script:PlanWith['actions'])[0]['id']
        (@($script:Items | Where-Object { $_['ID'] -eq $id })[0])['Remediations'] | Should -BeExactly 'REM-ONE (Untested), REM-TWO (Tested)'
    }

    It 'reads a remediation the plan does not list as untested' {
        $id = @($script:PlanWith['actions'])[1]['id']
        (@($script:Items | Where-Object { $_['ID'] -eq $id })[0])['Remediations'] | Should -BeExactly 'REM-GONE (Untested)'
    }

    It 'shows nothing at all for an empty list' {
        $script:Books[2].Sheets.Contains('Remediations') | Should -BeFalse
        $script:Books[2].Tables['ActionPlan'].Columns | Should -Not -Contain 'Remediations'
        $script:Books[2].Sheets['Dashboard'].Xml | Should -Not -Match 'Remediation'
    }

    It 'reads a plan with no remediation key' {
        $plan = Get-TcSmallPlan -Plan $script:Plans[1]
        $plan.Remove('remediations')
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $plan -RuleSet $script:Sets[1] -OutputPath (Join-Path $TestDrive 'noremediationkey.xlsx'))
        $book.Sheets.Contains('Remediations') | Should -BeFalse
    }
}

Describe 'New-TcWorkbook, cells in error' {
    BeforeAll {
        $all = $script:Fake[1] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        Clear-TcWorkbookTenant -Snapshot $all -Role 'Target'
        Clear-TcWorkbookTenant -Snapshot $all -Role 'S1'
        $script:AllBook = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $all -OutputPath (Join-Path $TestDrive 'allnothing.xlsx'))
    }

    It 'has no cell in error at <_> source(s)' -ForEach 1, 2, 3 {
        $bad = @(Get-TcXlsxAllCell -Book $script:Books[$_] | Where-Object { $_.Type -eq 'e' -or $_.Value -match '^#(VALUE|REF|NAME|DIV/0|N/A|NUM|NULL)' })
        @($bad | ForEach-Object { "$($_.Sheet)!$($_.Address)" }) | Should -BeNullOrEmpty
    }

    It 'has no cell in error on a tenant with nothing collected' {
        @(Get-TcXlsxAllCell -Book $script:NothingBook | Where-Object { $_.Type -eq 'e' } | ForEach-Object { "$($_.Sheet)!$($_.Address)" }) | Should -BeNullOrEmpty
    }

    It 'has no cell in error when nothing at all was collected' {
        @(Get-TcXlsxAllCell -Book $script:AllBook | Where-Object { $_.Type -eq 'e' } | ForEach-Object { "$($_.Sheet)!$($_.Address)" }) | Should -BeNullOrEmpty
    }

    It 'has no cell in error for a plan with nothing in it' {
        @(Get-TcXlsxAllCell -Book $script:EmptyBook | Where-Object { $_.Type -eq 'e' } | ForEach-Object { "$($_.Sheet)!$($_.Address)" }) | Should -BeNullOrEmpty
    }

    It 'gives every formula a stored value, for a reader that does not recalculate' {
        foreach ($count in 1, 3) {
            foreach ($cell in @(Get-TcXlsxAllCell -Book $script:Books[$count] | Where-Object { $_.Formula -and $_.Sheet -ne 'Tenant view' })) {
                [string]$cell.Value | Should -Not -BeNullOrEmpty -Because "$($cell.Sheet)!$($cell.Address)"
            }
        }
    }

    It 'asks Excel to recalculate when it opens the file' {
        $script:Books[2].Workbook | Should -Match 'fullCalcOnLoad="1"'
    }
}

Describe 'New-TcWorkbook, the Settings tab' {
    It 'gives each list a name that points at its values' {
        $book = $script:Books[2]
        foreach ($name in 'TcStatus', 'TcStepStatus', 'TcYesNo', 'TcDecisionStatus', 'TcMatrixDecision', 'TcViewTenant', 'TcViewMoment', 'TcViewOwner', 'TcViewState', 'TcViewBlocking') {
            $book.Names.Contains($name) | Should -BeTrue -Because $name
            $book.Names[$name] | Should -Match "Settings"
        }
    }

    It 'lists only the tenants that exist' {
        $values = @($script:Books[1].Sheets['Settings'].Cells.Values | ForEach-Object { $_.Value })
        $values | Should -Contain 'Alpine Group'
        $values | Should -Not -Contain 'Birch Partners'
        $values | Should -Not -Contain 'Cedar Services'
        @($script:Books[3].Sheets['Settings'].Cells.Values | Where-Object { $_.Value -eq 'Cedar Services' }).Count | Should -BeGreaterThan 0
    }

    It 'gives no team list when the project has no team, and offers the team when it has one' {
        $script:Books[1].Names.Contains('TcTeam') | Should -BeFalse
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject -Team 'Pat', 'Sam') -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1] -OutputPath (Join-Path $TestDrive 'team.xlsx'))
        $book.Names.Contains('TcTeam') | Should -BeTrue
        @($book.Sheets['Action plan'].Validations | Where-Object { $_.Formula -eq 'TcTeam' }).Count | Should -Be 1
    }
}

Describe 'New-TcWorkbook, validations and conditional formats' {
    It 'keeps the drop-down menu of <Column> in <Table>' -ForEach @(
        @{ Table = 'ActionPlan'; Sheet = 'Action plan'; Column = 'Status'; List = 'TcStatus' }
        @{ Table = 'DetailedSteps'; Sheet = 'Detailed steps'; Column = 'Status'; List = 'TcStepStatus' }
        @{ Table = 'TargetConfigurations'; Sheet = 'Target configurations'; Column = 'Applied'; List = 'TcYesNo' }
        @{ Table = 'IdentityMatrix'; Sheet = 'Identity matrix'; Column = 'Validated decision'; List = 'TcMatrixDecision' }
        @{ Table = 'Decisions'; Sheet = 'Decisions'; Column = 'Status'; List = 'TcDecisionStatus' }
    ) {
        foreach ($count in 1, 2, 3) {
            $book = $script:Books[$count]
            $letter = Get-TcXlsxColumnLetter -Book $book -Table $Table -Column $Column
            $last = @(Get-TcXlsxRow -Book $book -Table $Table)[-1]['#Row']
            $rule = @($book.Sheets[$Sheet].Validations | Where-Object { $_.Formula -eq $List })
            $rule.Count | Should -Be 1
            $rule[0].Type | Should -Be 'list'
            $rule[0].Range | Should -BeExactly "$($letter)10:$letter$last"
        }
    }

    It 'keeps the five boxes of the Tenant view' {
        $rules = @($script:Books[2].Sheets['Tenant view'].Validations)
        @($rules | ForEach-Object { $_.Range }) | Should -Be @('C6', 'D6', 'E6', 'F6', 'G6')
        @($rules | ForEach-Object { $_.Formula }) | Should -Be @('TcViewTenant', 'TcViewMoment', 'TcViewOwner', 'TcViewState', 'TcViewBlocking')
    }

    It 'colors the status of the action plan' {
        $book = $script:Books[2]
        $letter = Get-TcXlsxColumnLetter -Book $book -Table 'ActionPlan' -Column 'Status'
        $rules = @($book.Sheets['Action plan'].Formats | Where-Object { $_.Range -like "$($letter)10:*" -and $_.Type -eq 'cellIs' } | ForEach-Object { $_.Formula })
        foreach ($value in 'Done', 'In progress', 'Blocked', 'To do') { $rules | Should -Contain "`"$value`"" }
    }

    It 'draws the progress as a bar' {
        $book = $script:Books[2]
        $letter = Get-TcXlsxColumnLetter -Book $book -Table 'ActionPlan' -Column 'Progress'
        @($book.Sheets['Action plan'].Formats | Where-Object { $_.Range -like "$($letter)10:*" -and $_.Type -eq 'dataBar' }).Count | Should -Be 1
    }

    It 'crosses out an item that is done' {
        $book = $script:Books[2]
        $status = Get-TcXlsxColumnLetter -Book $book -Table 'ActionPlan' -Column 'Status'
        @($book.Sheets['Action plan'].Formats | Where-Object { $_.Type -eq 'expression' -and $_.Formula -eq "`$$($status)10=`"Done`"" }).Count | Should -Be 1
    }

    It 'colors a tenant by its role, only for the roles of the project' {
        $rules = { param($Book) @($Book.Sheets['Action plan'].Formats | Where-Object { $_.Type -eq 'expression' } | ForEach-Object { $_.Formula }) -join ' ' }
        $one = & $rules $script:Books[1]
        $one | Should -Match '"S1"'
        $one | Should -Not -Match '"S2"|"S3"'
        & $rules $script:Books[3] | Should -Match '"S3"'
    }

    It 'never puts a tenant name in a rule or in a menu' {
        foreach ($sheet in $script:Books[3].Sheets.Values) {
            foreach ($rule in @($sheet.Formats) + @($sheet.Validations)) { [string]$rule.Formula | Should -Not -Match 'Alpine|Birch|Cedar|Summit' -Because $sheet.Name }
        }
    }
}

Describe 'New-TcWorkbook, the Dashboard' {
    BeforeAll {
        $script:FindRow = {
            param($Book, [string]$Text, [int]$Column = 2)
            @($Book.Sheets['Dashboard'].Cells.Values | Where-Object { $_.Column -eq $Column -and $_.Value -ceq $Text })[0].Row
        }
        $script:Tile = {
            param($Book, [string]$Label)
            $cell = @($Book.Sheets['Dashboard'].Cells.Values | Where-Object { $_.Value -ceq $Label })[0]
            @($Book.Sheets['Dashboard'].Cells.Values | Where-Object { $_.Row -eq $cell.Row + 1 -and $_.Column -eq $cell.Column })[0].Value
        }
        $script:Line = {
            param($Book, [int]$Row)
            $line = @{}
            foreach ($cell in $Book.Sheets['Dashboard'].Cells.Values) { if ($cell.Row -eq $Row) { $line[$cell.Column] = $cell.Value } }
            $line
        }
    }

    It 'counts open blockers, items, decisions and settings as the plan does' {
        foreach ($count in 1, 2, 3) {
            $plan = $script:Plans[$count]
            & $script:Tile $script:Books[$count] 'Open blockers' | Should -Be ([string]@($plan['actions'] | Where-Object { $_['blocking'] }).Count)
            & $script:Tile $script:Books[$count] 'Items done' | Should -BeExactly "0 / $(@($plan['actions']).Count + @($plan['tasks']).Count)"
            & $script:Tile $script:Books[$count] 'Open decisions' | Should -Be ([string]@($plan['decisions']).Count)
            & $script:Tile $script:Books[$count] 'Settings applied' | Should -BeExactly "0 / $(@($plan['targetConfigurations']).Count)"
            & $script:Tile $script:Books[$count] 'Unconfirmed tasks' | Should -Be '0'
        }
    }

    It 'counts the accounts to validate as the matrix does' {
        $expected = @(Get-TcXlsxRow -Book $script:Books[2] -Table 'IdentityMatrix' | Where-Object { $_['Proposed decision'] -eq 'To review' })
        $expected.Count | Should -BeGreaterThan 0
        & $script:Tile $script:Books[2] 'Accounts to validate' | Should -Be ([string]$expected.Count)
    }

    It 'counts per tenant what no COUNTIFS of three conditions could: open blockers and accounts to validate' {
        $book = $script:Books[2]
        $cells = @($book.Sheets['Dashboard'].Cells.Values)
        $header = @($cells | Where-Object { $_.Value -ceq 'Open blockers' -and $_.Row -gt 20 })[0]
        $accounts = @($cells | Where-Object { $_.Row -eq $header.Row -and $_.Value -ceq 'Accounts to validate' })[0].Column
        $row = @($cells | Where-Object { $_.Row -gt $header.Row -and $_.Column -eq 2 -and $_.Value -ceq 'S2' })[0].Row
        $items = @(Get-TcXlsxRow -Book $book -Table 'ActionPlan' | Where-Object { $_['Role'] -eq 'S2' -and $_['Blocking'] -eq 'Yes' })
        $review = @(Get-TcXlsxRow -Book $book -Table 'IdentityMatrix' | Where-Object { $_['Role'] -eq 'S2' -and $_['Proposed decision'] -eq 'To review' })
        [int]@($cells | Where-Object { $_.Row -eq $row -and $_.Column -eq $header.Column })[0].Value | Should -Be $items.Count
        [int]@($cells | Where-Object { $_.Row -eq $row -and $_.Column -eq $accounts })[0].Value | Should -Be $review.Count
    }

    It 'takes a validated account off the count' {
        $book = $script:Light
        $row = @(Get-TcXlsxRow -Book $book -Table 'IdentityMatrix' | Where-Object { $_['Proposed decision'] -eq 'To review' })[0]['#Row']
        $letter = Get-TcXlsxColumnLetter -Book $book -Table 'IdentityMatrix' -Column 'Validated decision'
        $tile = @($book.Sheets['Dashboard'].Cells.Values | Where-Object { $_.Value -ceq 'Accounts to validate' })[0]
        $address = @($book.Sheets['Dashboard'].Cells.Values | Where-Object { $_.Row -eq $tile.Row + 1 -and $_.Column -eq $tile.Column })[0].Address
        $before = [int](& $script:Tile $book 'Accounts to validate')
        $after = Invoke-TcXlsxRecalculation -Path $book.Path -Change @(@{ Sheet = 'Identity matrix'; Address = "$letter$row"; Value = 'Create' }) -Read @(@{ Sheet = 'Dashboard'; Address = $address })
        [int]$after[0] | Should -Be ($before - 1)
    }

    It 'follows a status changed in the action plan' {
        $book = $script:Light
        $action = @($script:LightPlan['actions'] | Where-Object { $_['blocking'] })[0]
        $row = @(Get-TcXlsxRow -Book $book -Table 'ActionPlan' | Where-Object { $_['ID'] -eq $action['id'] })[0]['#Row']
        $status = Get-TcXlsxColumnLetter -Book $book -Table 'ActionPlan' -Column 'Status'
        $tile = @($book.Sheets['Dashboard'].Cells.Values | Where-Object { $_.Value -ceq 'Open blockers' })[0]
        $address = @($book.Sheets['Dashboard'].Cells.Values | Where-Object { $_.Row -eq $tile.Row + 1 -and $_.Column -eq $tile.Column })[0].Address
        $before = [int](& $script:Tile $book 'Open blockers')
        $after = Invoke-TcXlsxRecalculation -Path $book.Path -Change @(@{ Sheet = 'Action plan'; Address = "$status$row"; Value = 'Done' }) -Read @(@{ Sheet = 'Dashboard'; Address = $address })
        [int]$after[0] | Should -Be ($before - 1)
    }

    It 'shows Score and Collected score for each tenant, and says what the difference means' {
        $book = $script:Books[3]
        $rows = Get-TcReadiness -Snapshot $script:Fake[3] -RuleSet $script:Sets[3]
        $alpine = & $script:FindRow $book 'S1'
        $line = & $script:Line $book $alpine
        $expected = $rows | Where-Object Role -EQ 'S1'
        [int]$line[5] | Should -Be $expected.Score
        [int]$line[6] | Should -Be $expected.CollectedScore
        [int]$line[7] | Should -Be ($expected.CollectedScore - $expected.Score)
        $line[15] | Should -Match 'Power Platform \(not collected\)'
        $line[15] | Should -Match 'unknown, not a result'
        @($book.Sheets['Dashboard'].Cells.Values | Where-Object { $_.Value -match 'Score is the one to report' }).Count | Should -Be 1
    }

    It 'says when rules stopped on a workload' {
        InModuleScope TenantConverge {
            $line = [pscustomobject]@{ Workloads = @(
                    [pscustomobject]@{ Workload = 'Intune'; State = 'Passed'; Applicable = $true; Complete = $false; Coverage = 'OK'; RulesStopped = 2 }
                    [pscustomobject]@{ Workload = 'Teams'; State = 'Passed'; Applicable = $true; Complete = $true; Coverage = 'OK'; RulesStopped = 0 }
                )
            }
            Get-TcWorkbookScoreNote -Readiness $line | Should -Match 'Intune \(rules stopped\)'
        }
    }

    It 'says when both scores agree because everything was read' {
        $book = $script:Books[3]
        $target = & $script:FindRow $book 'Target'
        (& $script:Line $book $target)[15] | Should -Match 'Everything was read'
    }

    It 'says that nothing was read, and shows no collected score of zero' {
        $book = $script:NothingBook
        $line = & $script:Line $book (& $script:FindRow $book 'S2')
        $line[6] | Should -BeExactly 'Not read'
        $line[15] | Should -Match 'Nothing could be read'
    }

    It 'has one row and one column per tenant, and none for a tenant that does not exist' {
        foreach ($count in 1, 2, 3) {
            $cells = @($script:Books[$count].Sheets['Dashboard'].Cells.Values)
            $roles = @('S1', 'S2', 'S3')[0..($count - 1)]
            foreach ($role in 'S1', 'S2', 'S3') {
                $found = @($cells | Where-Object { $_.Value -ceq $role }).Count
                if ($role -in $roles) { $found | Should -BeGreaterThan 0 } else { $found | Should -Be 0 -Because "$role in $count source(s)" }
            }
            $cells | Where-Object { $_.Value -match 'Birch|Cedar' -and $count -eq 1 } | Should -BeNullOrEmpty
        }
    }

    It 'keeps not collected, not used, no service and partly read apart' {
        $snapshot = $script:Fake[2] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        foreach ($table in @($snapshot['tenants']['S2']['tables'].Keys)) { if ($table -in 'phoneNumbers', 'resourceAccounts', 'autoAttendants', 'callQueues', 'pstnGateways', 'voiceRoutes', 'voiceRoutingPolicies', 'dialPlans', 'translationRules', 'emergencyAddresses', 'conferenceBridges', 'userCallingSettings', 'phoneSchedules', 'phoneNetworkTopology') { $snapshot['tenants']['S2']['tables'][$table] = @() } }
        foreach ($line in @($snapshot['coverage'])) { if ($line['role'] -eq 'S1' -and $line['workload'] -eq 'Intune') { $line['status'] = 'License or service missing'; $line['tables'] = @() } }
        foreach ($table in 'managedDevices', 'autopilotDevices', 'autopilotProfiles', 'intunePolicies', 'intuneApps', 'appProtectionPolicies', 'intuneConnectors') { [void]$snapshot['tenants']['S1']['tables'].Remove($table) }
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject -SourceCount 2) -Snapshot $snapshot -OutputPath (Join-Path $TestDrive 'states.xlsx'))
        $cells = @($book.Sheets['Dashboard'].Cells.Values)
        $header = @($cells | Where-Object { $_.Value -ceq 'Workload' })[0].Row
        $column = @{}
        foreach ($cell in @($cells | Where-Object { $_.Row -eq $header -and $_.Value })) { $column[$cell.Value] = $cell.Column }
        $state = { param([string]$Workload, [string]$Role)
            $row = @($cells | Where-Object { $_.Value -ceq $Workload -and $_.Row -gt $header })[0].Row
            @($cells | Where-Object { $_.Row -eq $row -and $_.Column -eq $column[$Role] })[0].Value
        }
        & $state 'Power Platform' 'S1' | Should -BeExactly 'Not collected'
        & $state 'Intune' 'S1' | Should -BeExactly 'No service'
        & $state 'Teams Phone' 'S2' | Should -BeExactly 'Not used'
    }

    It 'says when a state rests on part of the data' {
        $cells = @($script:Books[3].Sheets['Dashboard'].Cells.Values)
        $header = @($cells | Where-Object { $_.Value -ceq 'Workload' })[0].Row
        $column = @($cells | Where-Object { $_.Row -eq $header -and $_.Value -ceq 'S3' })[0].Column
        $row = @($cells | Where-Object { $_.Value -ceq 'Teams' -and $_.Row -gt $header })[0].Row
        @($cells | Where-Object { $_.Row -eq $row -and $_.Column -eq $column })[0].Value | Should -BeExactly 'To address, partly read'
    }

    It 'names each tenant under its role' {
        $cells = @($script:Books[2].Sheets['Dashboard'].Cells.Values)
        $header = @($cells | Where-Object { $_.Value -ceq 'Workload' })[0].Row
        @($cells | Where-Object { $_.Row -eq $header + 1 -and $_.Value -ceq 'Birch Partners' }).Count | Should -Be 1
    }

    It 'has a bar chart and a doughnut chart' {
        $book = $script:Books[2]
        $charts = @($book.Sheets['Dashboard'].Charts | ForEach-Object { $book.Parts[$_] })
        @($charts | Where-Object { $_ -match '<c:barChart>' }).Count | Should -Be 2
        @($charts | Where-Object { $_ -match '<c:doughnutChart>' }).Count | Should -Be 1
    }

    It 'gives the doughnut no ghost series, and each slice a color' {
        $book = $script:Books[2]
        $text = @($book.Sheets['Dashboard'].Charts | ForEach-Object { $book.Parts[$_] } | Where-Object { $_ -match '<c:doughnutChart>' })[0]
        ([regex]::Matches($text, '<c:dPt>')).Count | Should -Be 5
    }

    Context 'the Readiness chart' {
        BeforeAll {
            $script:ReadinessChart = {
                param($Book)
                @($Book.Sheets['Dashboard'].Charts | ForEach-Object { $Book.Parts[$_] } | Where-Object { $_ -match 'Readiness by tenant' })[0]
            }
            # The cell of a row that a part of each series reads: c:val for its bars, c:cat for its labels.
            $script:SeriesCell = {
                param($Book, [string]$Part, [int]$Row)
                foreach ($match in [regex]::Matches((& $script:ReadinessChart $Book), "(?s)<c:$Part>.*?<c:f>'Dashboard'!\`$([A-Z]+)\`$")) {
                    $Book.Sheets['Dashboard'].Cells["$($match.Groups[1].Value)$Row"]
                }
            }
        }

        It 'draws no bar for a tenant that was not read' {
            $book = $script:NothingBook
            $cells = @(& $script:SeriesCell $book 'val' (& $script:FindRow $book 'S2'))
            $cells.Count | Should -Be 2
            foreach ($cell in $cells) { $cell | Where-Object { [string]$_.Value } | Should -BeNullOrEmpty -Because 'a 0 or a text draws as a bar at zero, the same as a tenant that scores 0' }
        }

        It 'says on the chart that a tenant was not read' {
            $book = $script:NothingBook
            $label = @(& $script:SeriesCell $book 'cat' (& $script:FindRow $book 'S2'))[0]
            $label.Value | Should -BeExactly 'Birch Partners (not read)'
        }

        It 'draws both scores of a tenant that was read, under its name' {
            $book = $script:NothingBook
            $row = & $script:FindRow $book 'S1'
            $line = & $script:Line $book $row
            $bars = @(& $script:SeriesCell $book 'val' $row)
            $bars[0].Value | Should -Be $line[5]
            $bars[1].Value | Should -Be $line[6]
            @(& $script:SeriesCell $book 'cat' $row)[0].Value | Should -BeExactly 'Alpine Group'
        }

        It 'leaves a gap for an empty cell, and reads cells that are hidden' {
            $chart = & $script:ReadinessChart $script:NothingBook
            $chart | Should -Match '<c:dispBlanksAs val="gap"'
            $chart | Should -Match '<c:plotVisOnly val="0"'
        }

        It 'keeps the parts of the chart in the order Excel requires' {
            $chart = & $script:ReadinessChart $script:NothingBook
            $chart | Should -Match '(?s)</c:plotArea>\s*<c:legend>.*</c:legend>\s*<c:plotVisOnly [^>]*/>\s*<c:dispBlanksAs [^>]*/>\s*</c:chart>'
        }

        It 'names its series as the table does' {
            $book = $script:NothingBook
            $names = @([regex]::Matches((& $script:ReadinessChart $book), "(?s)<c:tx>.*?<c:f>'Dashboard'!\`$([A-Z]+)\`$(\d+)</c:f>") | ForEach-Object { $book.Sheets['Dashboard'].Cells["$($_.Groups[1].Value)$($_.Groups[2].Value)"].Value })
            $names | Should -Be @('Score', 'Collected score')
        }

        It 'keeps what the chart reads out of sight' {
            $book = $script:NothingBook
            foreach ($cell in @(& $script:SeriesCell $book 'val' (& $script:FindRow $book 'S1')) + @(& $script:SeriesCell $book 'cat' (& $script:FindRow $book 'S1'))) {
                $book.Sheets['Dashboard'].HiddenColumns | Should -Contain $cell.Column
            }
        }

        It 'shows the table as it was: a score, and Not read for what was not read' {
            $book = $script:NothingBook
            $line = & $script:Line $book (& $script:FindRow $book 'S2')
            $line[5] | Should -Be '0'
            $line[6] | Should -BeExactly 'Not read'
            $line[7] | Should -BeExactly 'Not read'
        }
    }

    It 'draws no chart of items for a plan with nothing in it' {
        $book = $script:EmptyBook
        @($book.Sheets['Dashboard'].Charts | ForEach-Object { $book.Parts[$_] } | Where-Object { $_ -match '<c:doughnutChart>' }).Count | Should -Be 0
        @($book.Sheets['Tenant view'].Charts).Count | Should -Be 0
    }

    It 'links only to the tabs that exist' {
        foreach ($link in $script:Books[1].Sheets['Dashboard'].Links) { $link.Location | Should -Not -Match 'Remediations' }
    }
}

Describe 'New-TcWorkbook, the Tenant view' {
    BeforeAll {
        $script:View = @{}
        foreach ($cell in $script:Books[2].Sheets['Tenant view'].Cells.Values) { $script:View[$cell.Address] = $cell }
        $script:ListCell = {
            param([int]$Row, [string]$Column)
            $script:View["$Column$Row"].Value
        }
    }

    It 'opens on what is still open' {
        $script:View['C6'].Value | Should -BeExactly 'All'
        $script:View['F6'].Value | Should -BeExactly 'Open'
    }

    It 'counts what its boxes select' {
        [int]$script:View['C9'].Value | Should -Be (@($script:Plans[2]['actions']).Count + @($script:Plans[2]['tasks']).Count)
    }

    It 'lists the first items, with their own values' {
        $first = @(Get-TcXlsxRow -Book $script:Books[2] -Table 'ActionPlan')[0]
        $script:View['C23'].Value | Should -BeExactly $first['What to do']
        $script:View['D23'].Value | Should -BeExactly $first['Tenant']
        $script:View['K23'].Value | Should -BeExactly $first['ID']
        $script:View['B23'].Value | Should -BeExactly 'Open'
    }

    It 'follows a box: one tenant, blockers only' {
        $book = $script:Light
        $expected = @(Get-TcXlsxRow -Book $book -Table 'ActionPlan' | Where-Object { $_['Tenant'] -eq 'Birch Partners' -and $_['Blocking'] -eq 'Yes' })
        $result = Invoke-TcXlsxRecalculation -Path $book.Path -Change @(
            @{ Sheet = 'Tenant view'; Address = 'C6'; Value = 'Birch Partners' }, @{ Sheet = 'Tenant view'; Address = 'G6'; Value = 'Blocking' }
        ) -Read @(@{ Sheet = 'Tenant view'; Address = 'C9' }, @{ Sheet = 'Tenant view'; Address = 'C23' }, @{ Sheet = 'Tenant view'; Address = 'D23' })
        [int]$result[0] | Should -Be $expected.Count
        $result[1] | Should -BeExactly $expected[0]['What to do']
        $result[2] | Should -BeExactly 'Birch Partners'
    }

    It 'hides the helper columns of the action plan' {
        $book = $script:Books[2]
        $last = $book.Tables['ActionPlan'].Columns.Count
        foreach ($column in 2..5) { $book.Sheets['Action plan'].HiddenColumns | Should -Contain ($last + $column) }
    }

    It 'counts items, closed items and blockers by moment' {
        $rows = @(Get-TcXlsxRow -Book $script:Books[2] -Table 'ActionPlan')
        foreach ($row in 14..19) {
            $moment = $script:View["C$row"].Value
            $items = @($rows | Where-Object { $_['Moment'] -eq $moment })
            [int]$script:View["D$row"].Value | Should -Be $items.Count -Because $moment
            [int]$script:View["E$row"].Value | Should -Be 0 -Because $moment
            [int]$script:View["F$row"].Value | Should -Be $items.Count -Because $moment
            [int]$script:View["G$row"].Value | Should -Be @($items | Where-Object { $_['Blocking'] -eq 'Yes' }).Count -Because $moment
        }
    }

    It 'has a bar chart' {
        $book = $script:Books[2]
        @($book.Sheets['Tenant view'].Charts | ForEach-Object { $book.Parts[$_] } | Where-Object { $_ -match '<c:barChart>' }).Count | Should -Be 1
    }

    Context 'measures' {
        BeforeAll {
            $script:Cells = @($script:Books[2].Sheets['Tenant view'].Cells.Values)
            $script:Header = @($script:Cells | Where-Object { $_.Value -ceq 'Measure' })[0].Row
            $script:Columns = @{}
            foreach ($cell in @($script:Cells | Where-Object { $_.Row -eq $script:Header -and $_.Value })) { $script:Columns[$cell.Value] = $cell.Column }
            $script:Value = {
                param($Cells, [int]$Row, [int]$Column)
                @($Cells | Where-Object { $_.Row -eq $Row -and $_.Column -eq $Column })[0].Value
            }
        }

        It 'has one column per tenant, and none for a tenant that does not exist' {
            @($script:Columns.Keys | Sort-Object) | Should -Be @('After consolidation', 'Measure', 'Not read', 'S1', 'S2', 'Sources total', 'Target', 'Workload')
        }

        It 'has one row per measure, with its values' {
            $measure = @($script:Sets[2]['measures'] | Where-Object { $_['label'] -eq 'Active member accounts' })[0]
            $row = @($script:Cells | Where-Object { $_.Value -ceq 'Active member accounts' })[0].Row
            [int](& $script:Value $script:Cells $row $script:Columns['Target']) | Should -Be $measure['values']['Target']
            [int](& $script:Value $script:Cells $row $script:Columns['S1']) | Should -Be $measure['values']['S1']
            [int](& $script:Value $script:Cells $row $script:Columns['Sources total']) | Should -Be $measure['sources']
            [int](& $script:Value $script:Cells $row $script:Columns['After consolidation']) | Should -Be $measure['after']
        }

        It 'shows a value that was not read as such, never as zero' {
            $sheet = $script:NothingBook.Sheets['Tenant view']
            $cells = @($sheet.Cells.Values)
            $header = @($cells | Where-Object { $_.Value -ceq 'Measure' })[0].Row
            $columns = @{}
            foreach ($cell in @($cells | Where-Object { $_.Row -eq $header -and $_.Value })) { $columns[$cell.Value] = $cell.Column }
            $row = @($cells | Where-Object { $_.Value -ceq 'Active member accounts' })[0].Row
            & $script:Value $cells $row $columns['S2'] | Should -BeExactly 'Not collected'
        }

        It 'shows a total that misses a source as a minimum, and names the source' {
            $sheet = $script:NothingBook.Sheets['Tenant view']
            $cells = @($sheet.Cells.Values)
            $header = @($cells | Where-Object { $_.Value -ceq 'Measure' })[0].Row
            $columns = @{}
            foreach ($cell in @($cells | Where-Object { $_.Row -eq $header -and $_.Value })) { $columns[$cell.Value] = $cell.Column }
            $row = @($cells | Where-Object { $_.Value -ceq 'Active member accounts' })[0].Row
            & $script:Value $cells $row $columns['Sources total'] | Should -Match '^at least \d+'
            & $script:Value $cells $row $columns['After consolidation'] | Should -Match '^at least \d+'
            & $script:Value $cells $row $columns['Not read'] | Should -BeExactly 'Birch Partners'
        }
    }

    It 'lists what could not be read, with the status of the collector' {
        $cells = @($script:Books[2].Sheets['Tenant view'].Cells.Values)
        $line = @($script:Fake[2]['coverage'] | Where-Object { $_['status'] -eq 'Insufficient access' })[0]
        $row = @($cells | Where-Object { $_.Value -match [regex]::Escape($line['remedy']) })[0].Row
        @($cells | Where-Object { $_.Row -eq $row -and $_.Value -ceq 'Insufficient access' }).Count | Should -Be 1
        @($cells | Where-Object { $_.Row -eq $row -and $_.Value -ceq 'Alpine Group' }).Count | Should -Be 1
    }
}

Describe 'New-TcWorkbook, the tracking file' {
    BeforeAll {
        $script:Folder = Join-Path $TestDrive 'tracking'
        New-Item -ItemType Directory -Path $script:Folder | Out-Null
        $script:Plan1 = $script:Small
        $script:ActionId = @($script:Plan1['actions'] | Where-Object { $_['blocking'] })[0]['id']
        $script:TaskId = @($script:Plan1['tasks'])[0]['id']
        $script:DecisionId = @($script:Plan1['decisions'])[0]['id']
        $script:Write = {
            param([string]$Name, [string[]]$Lines)
            $path = Join-Path $script:Folder $Name
            Set-Content -LiteralPath $path -Value $Lines -Encoding utf8BOM
            $path
        }
        $path = & $script:Write 'long.csv' @(
            'Type,Id,Label,Field,Value,Author,Date,Replaces'
            "action,$($script:ActionId),Some title,status,Done,Pat,2026-11-01,"
            "action,$($script:ActionId),Some title,assignee,Pat,Pat,2026-11-01,"
            "action,$($script:ActionId),Some title,note,'=1+1,Pat,2026-11-01,"
            "task,$($script:TaskId),,status,doing,Sam,2026-11-01,"
            "action,OLD-ITEM.S3,Work from an older plan,status,Blocked,Sam,2026-10-01,"
            "action,OLD-ITEM.S3,Work from an older plan,note,kept on purpose,Sam,2026-10-01,"
            "decision,$($script:DecisionId),Some question,answer,Keep the provider,Sam,2026-11-01,"
            "decision,$($script:DecisionId),Some question,status,decided,Sam,2026-11-01,"
            "decision,OLD-QUESTION,A question that left,answer,Gone,Sam,2026-10-01,"
            "configuration,Some key,,applied,Yes,Sam,2026-11-01,"
        )
        $script:LongBook = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Plan1 -RuleSet $script:Sets[1] -TrackingPath $path -OutputPath (Join-Path $script:Folder 'long.xlsx'))
        $script:LongRows = @(Get-TcXlsxRow -Book $script:LongBook -Table 'ActionPlan')
        $script:LongDecisions = @(Get-TcXlsxRow -Book $script:LongBook -Table 'Decisions')

        # What the report writes for a setting: a key of role|setting, quoted, and Yes or No.
        $script:SettingLine = {
            param($Setting, [string]$Value)
            $quote = { param([string]$Text) '"{0}"' -f ($Text -replace '"', '""') }
            'configuration,{0},{1},applied,{2},Sam,2026-11-01T10:00:00.000Z,' -f (& $quote "$($Setting['role'])|$($Setting['setting'])"), (& $quote $Setting['setting']), $Value
        }
        $script:ReadSettings = {
            param([string]$Name, [string[]]$Lines, $Plan = $script:Plan1)
            $path = & $script:Write "$Name.csv" (@('Type,Id,Label,Field,Value,Author,Date,Replaces') + $Lines)
            Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $Plan -RuleSet $script:Sets[1] -TrackingPath $path -OutputPath (Join-Path $script:Folder "$Name.xlsx"))
        }
        $script:TileValue = {
            param($Book, [string]$Label)
            $cells = @($Book.Sheets['Dashboard'].Cells.Values)
            $cell = @($cells | Where-Object { $_.Value -ceq $Label })[0]
            @($cells | Where-Object { $_.Row -eq $cell.Row + 1 -and $_.Column -eq $cell.Column })[0].Value
        }
    }

    It 'shows what the team recorded on an action' {
        $row = @($script:LongRows | Where-Object { $_['ID'] -eq $script:ActionId })[0]
        $row['Status'] | Should -BeExactly 'Done'
        $row['Assigned to'] | Should -BeExactly 'Pat'
        $row['Owner'] | Should -Not -BeExactly 'Pat' -Because 'the side that owns an item is not the person assigned'
        $row['Kind'] | Should -BeExactly 'Action'
    }

    It 'shows the status of a task' {
        (@($script:LongRows | Where-Object { $_['ID'] -eq $script:TaskId })[0])['Status'] | Should -BeExactly 'In progress'
    }

    It 'removes the apostrophe that protected a value in the file, and keeps the value as text' {
        $row = @($script:LongRows | Where-Object { $_['ID'] -eq $script:ActionId })[0]
        $row['Note'] | Should -BeExactly '=1+1'
        @($script:LongBook.Sheets['Action plan'].Cells.Values | Where-Object { $_.Value -ceq '=1+1' }) | ForEach-Object { $_.Type | Should -Be 's'; $_.Formula | Should -BeNullOrEmpty }
    }

    It 'keeps an orphan row visible, with what it held' {
        $orphan = @($script:LongRows | Where-Object { $_['ID'] -eq 'OLD-ITEM.S3' })
        $orphan.Count | Should -Be 1
        $orphan[0]['Kind'] | Should -BeExactly 'Orphan'
        $orphan[0]['What to do'] | Should -BeExactly 'Work from an older plan'
        $orphan[0]['Status'] | Should -BeExactly 'Blocked'
        $orphan[0]['Note'] | Should -BeExactly 'kept on purpose'
        $orphan[0]['Finding'] | Should -Match 'matches nothing in this plan'
    }

    It 'counts an orphan row as no action of the plan' {
        @($script:LongRows | Where-Object { $_['Kind'] -eq 'Action' }).Count | Should -Be @($script:Plan1['actions']).Count
    }

    It 'shows the answer to a question' {
        $row = @($script:LongDecisions | Where-Object { $_['ID'] -eq $script:DecisionId })[0]
        $row['Status'] | Should -BeExactly 'Decided'
        $row['Answer'] | Should -BeExactly 'Keep the provider'
    }

    It 'keeps a question that left the plan visible' {
        $orphan = @($script:LongDecisions | Where-Object { $_['ID'] -eq 'OLD-QUESTION' })
        $orphan.Count | Should -Be 1
        $orphan[0]['Origin'] | Should -BeExactly 'Orphan'
        $orphan[0]['Question'] | Should -BeExactly 'A question that left'
        $orphan[0]['Answer'] | Should -BeExactly 'Gone'
    }

    It 'joins the notes of two people' {
        $path = & $script:Write 'notes.csv' @('Type,Id,Label,Field,Value,Author,Date,Replaces', "action,$($script:ActionId),,note,First note,Pat,2026-11-01,", "action,$($script:ActionId),,note,Second note,Sam,2026-11-02,")
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Plan1 -RuleSet $script:Sets[1] -TrackingPath $path -OutputPath (Join-Path $script:Folder 'notes.xlsx'))
        (@(Get-TcXlsxRow -Book $book -Table 'ActionPlan' | Where-Object { $_['ID'] -eq $script:ActionId })[0])['Note'] | Should -BeExactly 'First note; Second note'
    }

    It 'keeps a line about a setting out of the action plan' {
        $script:LongRows | Where-Object { $_['ID'] -eq 'Some key' } | Should -BeNullOrEmpty
    }

    It 'shows a setting the team applied in the report, on its row and on no other' {
        $settings = @($script:Plan1['targetConfigurations'])
        $settings.Count | Should -BeGreaterThan 1 -Because 'a row must stay unapplied beside it'
        $book = & $script:ReadSettings 'applied' @(& $script:SettingLine $settings[0] 'Yes')
        $rows = @(Get-TcXlsxRow -Book $book -Table 'TargetConfigurations')
        $yes = @($rows | Where-Object { $_['Applied'] -eq 'Yes' })
        $yes.Count | Should -BeGreaterThan 0
        foreach ($row in $yes) {
            $row['Role'] | Should -BeExactly $settings[0]['role']
            $row['Setting'] | Should -BeExactly $settings[0]['setting']
        }
        @($rows | Where-Object { $_['Applied'] -eq 'No' }).Count | Should -Be ($rows.Count - $yes.Count)
        @($rows | Where-Object { $_['Origin'] -eq 'Orphan' }).Count | Should -Be 0
    }

    It 'counts a setting the team applied in the tile and on the row of its tenant' {
        $settings = @($script:Plan1['targetConfigurations'])
        $book = & $script:ReadSettings 'counted' @(& $script:SettingLine $settings[0] 'Yes')
        $expected = @($settings | Where-Object { $_['role'] -eq $settings[0]['role'] -and $_['setting'] -ceq $settings[0]['setting'] }).Count
        & $script:TileValue $book 'Settings applied' | Should -BeExactly "$expected / $($settings.Count)"
        $cells = @($book.Sheets['Dashboard'].Cells.Values)
        $header = @($cells | Where-Object { $_.Value -ceq 'Settings applied' })[1]
        $tenant = @($cells | Where-Object { $_.Row -gt $header.Row -and $_.Column -eq 2 -and $_.Value -ceq $settings[0]['role'] })[0].Row
        [int]@($cells | Where-Object { $_.Row -eq $tenant -and $_.Column -eq $header.Column })[0].Value | Should -Be $expected
    }

    It 'ticks every row of a setting that stands under two actions, as the report does' {
        $plan = $script:Plan1 | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        $first = @($plan['targetConfigurations'])[0]
        $twin = $first | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        $plan['targetConfigurations'] = @(@($plan['targetConfigurations']) + $twin)
        $book = & $script:ReadSettings 'twin' @(& $script:SettingLine $first 'Yes') $plan
        $rows = @(Get-TcXlsxRow -Book $book -Table 'TargetConfigurations' | Where-Object { $_['Role'] -eq $first['role'] -and $_['Setting'] -ceq $first['setting'] })
        $rows.Count | Should -BeGreaterOrEqual 2
        @($rows | ForEach-Object { $_['Applied'] } | Sort-Object -Unique) | Should -Be @('Yes')
    }

    It 'reads as applied only what the report reads as applied' {
        $settings = @($script:Plan1['targetConfigurations'])
        $book = & $script:ReadSettings 'words' @((& $script:SettingLine $settings[0] 'No'), (& $script:SettingLine $settings[1] 'yes'))
        @(Get-TcXlsxRow -Book $book -Table 'TargetConfigurations' | Where-Object { $_['Applied'] -ne 'No' }).Count | Should -Be 0
    }

    It 'takes the last line for a setting, as the report does' {
        $setting = @($script:Plan1['targetConfigurations'])[0]
        $book = & $script:ReadSettings 'lastline' @((& $script:SettingLine $setting 'Yes'), (& $script:SettingLine $setting 'No'))
        @(Get-TcXlsxRow -Book $book -Table 'TargetConfigurations' | Where-Object { $_['Applied'] -eq 'Yes' }).Count | Should -Be 0
    }

    It 'keeps a setting that left the plan visible, as an orphan, and counts it nowhere' {
        $rows = @(Get-TcXlsxRow -Book $script:LongBook -Table 'TargetConfigurations')
        $orphan = @($rows | Where-Object { $_['Setting'] -ceq 'Some key' })
        $orphan.Count | Should -Be 1
        $orphan[0]['Origin'] | Should -BeExactly 'Orphan'
        $orphan[0]['Applied'] | Should -BeExactly 'Yes'
        $orphan[0]['Target'] | Should -Match 'matches nothing in this plan'
        $orphan[0]['Open'] | Should -BeNullOrEmpty
        $rows.Count | Should -Be (@($script:Plan1['targetConfigurations']).Count + 1)
        & $script:TileValue $script:LongBook 'Settings applied' | Should -BeExactly "0 / $(@($script:Plan1['targetConfigurations']).Count)"
        @($script:LongBook.Sheets['Dashboard'].Cells.Values | Where-Object { $_.Value -ceq 'Orphan' }).Count | Should -Be 0 -Because 'an orphan has no tenant row'
    }

    It 'reads a file with one row per item, and its own delimiter' {
        $path = & $script:Write 'wide.csv' @('Id;Status;Owner;Note', "$($script:ActionId);Blocked;Sam;Waiting for the vendor", 'GONE-01;Done;Sam;')
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Plan1 -RuleSet $script:Sets[1] -TrackingPath $path -OutputPath (Join-Path $script:Folder 'wide.xlsx'))
        $rows = @(Get-TcXlsxRow -Book $book -Table 'ActionPlan')
        (@($rows | Where-Object { $_['ID'] -eq $script:ActionId })[0])['Status'] | Should -BeExactly 'Blocked'
        (@($rows | Where-Object { $_['ID'] -eq 'GONE-01' })[0])['Kind'] | Should -BeExactly 'Orphan'
    }

    It 'shows a status it does not know as it was typed, and does not count it as done' {
        $path = & $script:Write 'unknown-status.csv' @(
            'Type,Id,Label,Field,Value,Author,Date,Replaces'
            "action,$($script:ActionId),,status,Finished,Pat,2026-11-01,"
        )
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Plan1 -RuleSet $script:Sets[1] -TrackingPath $path -OutputPath (Join-Path $script:Folder 'unknown-status.xlsx'))
        $rows = @(Get-TcXlsxRow -Book $book -Table 'ActionPlan')
        (@($rows | Where-Object { $_['ID'] -eq $script:ActionId })[0])['Status'] | Should -BeExactly 'Finished'
        @($rows | Where-Object { $_['Kind'] -eq 'Orphan' }).Count | Should -Be 0
        & $script:TileValue $book 'Items done' | Should -Match '^0 / '
    }

    It 'lets a later row win over one the report kept at the top of the file' {
        $path = & $script:Write 'kept-first.csv' @(
            'Type,Id,Label,Field,Value,Author,Date,Replaces'
            "action,$($script:ActionId),,status,Finished,Pat,2026-11-01,"
            "action,$($script:ActionId),,status,blocked,Sam,2026-11-02,"
        )
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Plan1 -RuleSet $script:Sets[1] -TrackingPath $path -OutputPath (Join-Path $script:Folder 'kept-first.xlsx'))
        (@(Get-TcXlsxRow -Book $book -Table 'ActionPlan' | Where-Object { $_['ID'] -eq $script:ActionId })[0])['Status'] | Should -BeExactly 'Blocked'
    }

    It 'finds team-tracking.csv next to the workbook on its own' {
        $folder = Join-Path $script:Folder 'beside'
        New-Item -ItemType Directory -Path $folder | Out-Null
        Set-Content -LiteralPath (Join-Path $folder 'team-tracking.csv') -Value @('Id,Status', "$($script:ActionId),Blocked") -Encoding utf8BOM
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Plan1 -RuleSet $script:Sets[1] -OutputPath $folder)
        (@(Get-TcXlsxRow -Book $book -Table 'ActionPlan' | Where-Object { $_['ID'] -eq $script:ActionId })[0])['Status'] | Should -BeExactly 'Blocked'
    }

    It 'reads a tracking file that is open elsewhere' {
        $path = & $script:Write 'open.csv' @('Id,Status', "$($script:ActionId),Blocked")
        $lock = [System.IO.File]::Open($path, 'Open', 'ReadWrite', 'ReadWrite')
        try {
            $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Plan1 -RuleSet $script:Sets[1] -TrackingPath $path -OutputPath (Join-Path $script:Folder 'open.xlsx'))
        }
        finally { $lock.Dispose() }
        (@(Get-TcXlsxRow -Book $book -Table 'ActionPlan' | Where-Object { $_['ID'] -eq $script:ActionId })[0])['Status'] | Should -BeExactly 'Blocked'
    }

    It 'keeps the accents of a file that Excel saved in an old code page' {
        $path = Join-Path $script:Folder 'old-code-page.csv'
        $text = "Type;Id;Label;Field;Value;Author;Date;Replaces`r`naction;$($script:ActionId);;note;d$([char]0xE9)j$([char]0xE0) fait;Pat;2026-11-01;`r`n"
        [System.IO.File]::WriteAllBytes($path, [System.Text.Encoding]::GetEncoding(1252).GetBytes($text))
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Plan1 -RuleSet $script:Sets[1] -TrackingPath $path -OutputPath (Join-Path $script:Folder 'old-code-page.xlsx'))
        (@(Get-TcXlsxRow -Book $book -Table 'ActionPlan' | Where-Object { $_['ID'] -eq $script:ActionId })[0])['Note'] | Should -BeExactly "d$([char]0xE9)j$([char]0xE0) fait"
    }

    It 'says so when a file is not a tracking file, and still writes the workbook' {
        $path = & $script:Write 'other.csv' @('Name,Value', 'a,b')
        Mock Write-TcMessage -ModuleName TenantConverge
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Plan1 -RuleSet $script:Sets[1] -TrackingPath $path -OutputPath (Join-Path $script:Folder 'other.xlsx'))
        @(Get-TcXlsxRow -Book $book -Table 'ActionPlan' | Where-Object { $_['Kind'] -eq 'Orphan' }).Count | Should -Be 0
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'no Id column' }
    }
}

Describe 'New-TcWorkbook, opening the file' {
    It 'selects the Dashboard and only the Dashboard' {
        foreach ($count in 1, 3) {
            $book = $script:Books[$count]
            $selected = @($book.Sheets.Values | Where-Object { $_.Xml -match '<sheetView [^>]*tabSelected="(1|true)"' } | ForEach-Object { $_.Name })
            $selected | Should -Be @('Dashboard')
            $book.Workbook | Should -Not -Match 'activeTab="[1-9]'
        }
    }

    It 'keeps rows 5 to 8 of a table tab hidden, for the slicers of -AddSlicers' {
        $script:Books[1].Sheets['Action plan'].HiddenRows | Should -Be @(5, 6, 7, 8)
    }

    It 'prints each tab one page wide, in landscape' {
        foreach ($sheet in $script:Books[1].Sheets.Values) { $sheet.Xml | Should -Match 'orientation="landscape"' -Because $sheet.Name }
    }
}

Describe 'New-TcWorkbook -AddSlicers' {
    It 'says so when Excel is not there, and still writes the workbook' {
        Mock New-TcExcelApplication -ModuleName TenantConverge { throw [System.Runtime.InteropServices.COMException]::new('Class not registered') }
        Mock Write-TcMessage -ModuleName TenantConverge
        $path = New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1] -OutputPath (Join-Path $TestDrive 'noexcel.xlsx') -AddSlicers
        Test-Path -LiteralPath $path | Should -BeTrue
        (Read-TcXlsx -Path $path).Properties['creator'] | Should -BeExactly 'TenantConverge'
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'Excel' -and $Message -match 'filter buttons' }
    }

    It 'never quits an Excel that was already open' {
        $script:Quit = 0
        Mock New-TcExcelApplication -ModuleName TenantConverge { [pscustomobject]@{ Hwnd = 42 } | Add-Member -MemberType ScriptMethod -Name Quit -Value { $script:Quit++ } -PassThru }
        Mock Get-TcExcelProcessId -ModuleName TenantConverge { 4242 }
        Mock Get-TcRunningExcel -ModuleName TenantConverge { @(4242) }
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Stop-Process -ModuleName TenantConverge
        $path = New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1] -OutputPath (Join-Path $TestDrive 'attached.xlsx') -AddSlicers
        Test-Path -LiteralPath $path | Should -BeTrue
        $script:Quit | Should -Be 0
        Should -Invoke Stop-Process -ModuleName TenantConverge -Times 0 -Exactly
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'already open' }
    }

    Context 'when Excel fails' {
        BeforeAll {
            $script:WriteWithSlicers = {
                param([string]$Name)
                New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1] -OutputPath (Join-Path $TestDrive "$Name.xlsx") -AddSlicers
            }
            $script:ShouldBeWithoutSlicers = {
                param([string]$Path)
                $book = Read-TcXlsx -Path $Path
                @($book.Parts.Keys | Where-Object { $_ -match 'slicer' }) | Should -BeNullOrEmpty
                $book.Sheets['Action plan'].HiddenRows | Should -Be @(5, 6, 7, 8)
                $book.Properties['creator'] | Should -BeExactly 'TenantConverge'
                @(Get-ChildItem -LiteralPath (Split-Path -Path $Path -Parent) -Force -Filter '*.tmp*').Count | Should -Be 0
            }
        }

        BeforeEach {
            Mock New-TcExcelApplication -ModuleName TenantConverge { $script:Excel }
            Mock Get-TcExcelProcessId -ModuleName TenantConverge { 4242 }
            Mock Get-TcRunningExcel -ModuleName TenantConverge { @() }
            Mock Wait-Process -ModuleName TenantConverge
            Mock Stop-Process -ModuleName TenantConverge
            Mock Get-Process -ModuleName TenantConverge
            Mock Write-TcMessage -ModuleName TenantConverge
        }

        It 'keeps the finished workbook, without slicers, with a message, when Excel cannot open it' {
            $script:Excel = New-TcFakeExcel -Fail Open
            $path = & $script:WriteWithSlicers 'cannotopen'
            & $script:ShouldBeWithoutSlicers $path
            $script:Excel.Quits | Should -Be 1
            Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'no slicers' -and $Message -match 'filter buttons' -and $Message -match 'could not be opened' }
        }

        It 'keeps the finished workbook, unsaved by Excel, when Excel stops halfway' {
            $script:Excel = New-TcFakeExcel -Fail Work
            $path = & $script:WriteWithSlicers 'halfway'
            & $script:ShouldBeWithoutSlicers $path
            $script:Excel.Workbooks.Workbook.Closes | Should -Be 1
            $script:Excel.Workbooks.Workbook.Saves | Should -Be 0
            $script:Excel.Quits | Should -Be 1
        }

        It 'quits its instance when the process cannot be read and no Excel was open before' {
            Mock Get-TcExcelProcessId -ModuleName TenantConverge { throw 'Hwnd unavailable' }
            $script:Excel = New-TcFakeExcel -Fail Work
            & $script:ShouldBeWithoutSlicers (& $script:WriteWithSlicers 'noprocess')
            $script:Excel.Quits | Should -Be 1
        }

        It 'quits the instance that appeared when the process cannot be read, and stops only that process' {
            $script:Listed = 0
            Mock Get-TcRunningExcel -ModuleName TenantConverge { $script:Listed++; if ($script:Listed -gt 1) { @(1, 77) } else { @(1) } }
            Mock Get-TcExcelProcessId -ModuleName TenantConverge { throw 'Hwnd unavailable' }
            Mock Get-Process -ModuleName TenantConverge { [pscustomobject]@{ ProcessName = 'EXCEL' } }
            $script:Excel = New-TcFakeExcel -Fail Work
            & $script:ShouldBeWithoutSlicers (& $script:WriteWithSlicers 'appeared')
            $script:Excel.Quits | Should -Be 1
            Should -Invoke Stop-Process -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter { $Id -contains 77 }
            Should -Invoke Stop-Process -ModuleName TenantConverge -Times 0 -Exactly -ParameterFilter { $Id -contains 1 }
        }

        It 'never quits an Excel that was already open, even when the process cannot be read' {
            Mock Get-TcRunningExcel -ModuleName TenantConverge { @(1) }
            Mock Get-TcExcelProcessId -ModuleName TenantConverge { throw 'Hwnd unavailable' }
            Mock Get-Process -ModuleName TenantConverge { [pscustomobject]@{ ProcessName = 'EXCEL' } }
            $script:Excel = New-TcFakeExcel
            $path = & $script:WriteWithSlicers 'wasopen'
            & $script:ShouldBeWithoutSlicers $path
            $script:Excel.Quits | Should -Be 0
            Should -Invoke Stop-Process -ModuleName TenantConverge -Times 0 -Exactly
            Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'already open' }
        }

        It 'never quits an Excel that was already open when its window gives no process' {
            Mock Get-TcRunningExcel -ModuleName TenantConverge { @(1) }
            Mock Get-TcExcelProcessId -ModuleName TenantConverge { 0 }
            Mock Get-Process -ModuleName TenantConverge { [pscustomobject]@{ ProcessName = 'EXCEL' } }
            $script:Excel = New-TcFakeExcel
            & $script:ShouldBeWithoutSlicers (& $script:WriteWithSlicers 'nowindow')
            $script:Excel.Quits | Should -Be 0
            Should -Invoke Stop-Process -ModuleName TenantConverge -Times 0 -Exactly
            Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'already open' }
        }

        It 'still quits, and stops what stays, when Close throws' {
            Mock Get-Process -ModuleName TenantConverge { [pscustomobject]@{ ProcessName = 'EXCEL' } }
            $script:Excel = New-TcFakeExcel -Fail Work, Close
            & $script:ShouldBeWithoutSlicers (& $script:WriteWithSlicers 'closefails')
            $script:Excel.Quits | Should -Be 1
            Should -Invoke Stop-Process -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter { $Id -contains 4242 }
        }

        It 'still stops what stays when Quit throws' {
            Mock Get-Process -ModuleName TenantConverge { [pscustomobject]@{ ProcessName = 'EXCEL' } }
            $script:Excel = New-TcFakeExcel -Fail Open, Quit
            & $script:ShouldBeWithoutSlicers (& $script:WriteWithSlicers 'quitfails')
            Should -Invoke Stop-Process -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter { $Id -contains 4242 }
        }

        It 'stops nothing that is not Excel' {
            Mock Get-Process -ModuleName TenantConverge { [pscustomobject]@{ ProcessName = 'notepad' } }
            $script:Excel = New-TcFakeExcel -Fail Open
            & $script:ShouldBeWithoutSlicers (& $script:WriteWithSlicers 'otherprocess')
            Should -Invoke Stop-Process -ModuleName TenantConverge -Times 0 -Exactly
        }

        It 'keeps slicers already saved when only Close throws, and still quits' {
            $script:Excel = New-TcFakeExcel -Fail Close
            InModuleScope TenantConverge { Add-TcWorkbookSlicer -Path 'book.xlsx' -Book @{ Tables = @{} } } | Should -BeTrue
            $script:Excel.Workbooks.Workbook.Saves | Should -Be 1
            $script:Excel.Quits | Should -Be 1
        }
    }

    It 'reads a window that does not exist as no process, and throws nothing' -Skip:(-not $IsWindows) {
        InModuleScope TenantConverge { Get-TcExcelProcessId -Excel ([pscustomobject]@{ Hwnd = 0 }) } | Should -Be 0
    }

    It 'says in the help that a call to Excel has no time limit' {
        $help = ((Get-Help New-TcWorkbook -Parameter AddSlicers).description.Text -join ' ') -replace '\s+', ' '
        $help | Should -Match 'no time limit'
        $help | Should -Match 'when Excel fails'
    }

    It 'writes the author back after Excel has saved, and takes the folder of the file out' {
        InModuleScope TenantConverge -Parameters @{ Folder = $TestDrive } {
            param($Folder)
            $path = Join-Path $Folder 'finished.xlsx'
            $archive = [System.IO.Compression.ZipFile]::Open($path, 'Create')
            $parts = @{
                'docProps/core.xml' = '<?xml version="1.0"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>TenantConverge</dc:creator><cp:lastModifiedBy>Some Person</cp:lastModifiedBy></cp:coreProperties>'
                'docProps/app.xml'  = '<?xml version="1.0"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Company>Their Company</Company><Manager>Their Boss</Manager></Properties>'
                'xl/workbook.xml'   = '<?xml version="1.0"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:x15ac="http://schemas.microsoft.com/office/spreadsheetml/2010/11/ac"><mc:AlternateContent xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"><mc:Choice Requires="x15"><x15ac:absPath url="C:\Users\someone\Documents\" xmlns:x15ac="http://schemas.microsoft.com/office/spreadsheetml/2010/11/ac"/></mc:Choice></mc:AlternateContent><sheets/></workbook>'
            }
            foreach ($name in $parts.Keys) {
                $writer = [System.IO.StreamWriter]::new($archive.CreateEntry($name).Open())
                $writer.Write($parts[$name])
                $writer.Dispose()
            }
            $archive.Dispose()

            Repair-TcWorkbookProperty -Path $path

            $archive = [System.IO.Compression.ZipFile]::OpenRead($path)
            $read = {
                param([string]$Name)
                $reader = [System.IO.StreamReader]::new($archive.GetEntry($Name).Open())
                $text = $reader.ReadToEnd()
                $reader.Dispose()
                $text
            }
            $core = & $read 'docProps/core.xml'
            $app = & $read 'docProps/app.xml'
            $workbook = & $read 'xl/workbook.xml'
            $archive.Dispose()
            $core | Should -Match '<cp:lastModifiedBy>TenantConverge</cp:lastModifiedBy>'
            $core | Should -Not -Match 'Some Person'
            $app | Should -Match '<Company>TenantConverge</Company>'
            $app | Should -Not -Match 'Their'
            $workbook | Should -Not -Match 'someone|absPath'
            [xml]$workbook | Should -Not -BeNullOrEmpty
        }
    }

    It 'adds slicers with a real Excel, in its own instance' -Skip:(-not $env:TC_TEST_EXCEL) {
        $before = @(Get-Process EXCEL -ErrorAction SilentlyContinue | ForEach-Object Id)
        $path = New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $script:Fake[1] -Plan $script:Small -RuleSet $script:Sets[1] -OutputPath (Join-Path $TestDrive 'slicers.xlsx') -AddSlicers
        $book = Read-TcXlsx -Path $path
        @($book.Parts.Keys | Where-Object { $_ -match 'slicers/slicer' }).Count | Should -BeGreaterThan 0
        $book.Sheets['Action plan'].HiddenRows | Should -BeNullOrEmpty
        $book.Properties['lastModifiedBy'] | Should -BeExactly 'TenantConverge'
        $book.Properties['creator'] | Should -BeExactly 'TenantConverge'
        foreach ($name in @($book.Parts.Keys | Where-Object { $book.Parts[$_] })) { $book.Parts[$name] | Should -Not -Match ([regex]::Escape("\Users\$env:USERNAME")) -Because $name }
        @(Get-TcXlsxAllCell -Book $book | Where-Object { $_.Type -eq 'e' }).Count | Should -Be 0
        @(Get-Process EXCEL -ErrorAction SilentlyContinue | ForEach-Object Id | Where-Object { $_ -notin $before }) | Should -BeNullOrEmpty -Because 'the instance of the run is closed'
        foreach ($id in $before) { Get-Process -Id $id -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because 'an Excel that was open stays open' }
    }
}

Describe 'New-TcWorkbook, tenant names that look like something else' {
    BeforeAll {
        $script:Odd = @{ Target = '=1+1'; S1 = '>5'; S2 = 'Al*' }
        $project = New-TcWorkbookProject -SourceCount 2
        $project.target.displayName = $script:Odd['Target']
        $project.sources[0].displayName = $script:Odd['S1']
        $project.sources[1].displayName = $script:Odd['S2']
        $plan = Get-TcSmallPlan -Plan (New-TcPlan -Project $project -Snapshot $script:Fake[2] -RuleSet $script:Sets[2]) -Actions 80 -Tasks 30
        $script:OddBook = Read-TcXlsx -Path (New-TcWorkbook -Project $project -Snapshot $script:Fake[2] -Plan $plan -RuleSet $script:Sets[2] -OutputPath (Join-Path $TestDrive 'odd.xlsx'))
        $script:OddRows = @(Get-TcXlsxRow -Book $script:OddBook -Table 'ActionPlan')
    }

    It 'keeps the names as text in the list of the Tenant view' {
        $cells = @($script:OddBook.Sheets['Settings'].Cells.Values | Where-Object { $_.Value -ceq '=1+1' })
        $cells.Count | Should -BeGreaterThan 0
        foreach ($cell in $cells) { $cell.Type | Should -Be 's' }
    }

    It 'counts the items of a tenant by role, whatever its name' {
        $cells = @($script:OddBook.Sheets['Dashboard'].Cells.Values)
        $header = @($cells | Where-Object { $_.Value -ceq 'Items' })[0]
        $row = @($cells | Where-Object { $_.Row -gt $header.Row -and $_.Column -eq 2 -and $_.Value -ceq 'S2' })[0].Row
        $count = @($cells | Where-Object { $_.Row -eq $row -and $_.Column -eq $header.Column })[0].Value
        [int]$count | Should -Be @($script:OddRows | Where-Object { $_['Role'] -eq 'S2' }).Count
    }

    It 'filters on a name with a wildcard as on any other name' {
        $expected = @($script:OddRows | Where-Object { $_['Tenant'] -ceq 'Al*' })
        $result = Invoke-TcXlsxRecalculation -Path $script:OddBook.Path -Change @(@{ Sheet = 'Tenant view'; Address = 'C6'; Value = 'Al*' }) -Read @(@{ Sheet = 'Tenant view'; Address = 'C9' })
        [int]$result[0] | Should -Be $expected.Count
    }

    It 'filters on a name that reads as a comparison as on any other name' {
        $expected = @($script:OddRows | Where-Object { $_['Tenant'] -ceq '>5' })
        $result = Invoke-TcXlsxRecalculation -Path $script:OddBook.Path -Change @(@{ Sheet = 'Tenant view'; Address = 'C6'; Value = '>5' }) -Read @(@{ Sheet = 'Tenant view'; Address = 'C9' })
        [int]$result[0] | Should -Be $expected.Count
    }

    It 'takes two tenants with the same name, and tabs keep their names' {
        $project = New-TcWorkbookProject -SourceCount 2
        $project.sources[1].displayName = $project.sources[0].displayName
        $plan = Get-TcSmallPlan -Plan (New-TcPlan -Project $project -Snapshot $script:Fake[2] -RuleSet $script:Sets[2])
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project $project -Snapshot $script:Fake[2] -Plan $plan -RuleSet $script:Sets[2] -OutputPath (Join-Path $TestDrive 'same.xlsx'))
        @($book.Sheets.Keys) | Should -Contain 'Dashboard'
        @(Get-TcXlsxAllCell -Book $book | Where-Object { $_.Type -eq 'e' }).Count | Should -Be 0
    }

    It 'takes a very long tenant name without changing a tab or a column' {
        $project = New-TcWorkbookProject
        $project.sources[0].displayName = 'x' * 64
        $plan = Remove-TcPlanRemediation -Plan (Get-TcSmallPlan -Plan (New-TcPlan -Project $project -Snapshot $script:Fake[1] -RuleSet $script:Sets[1]))
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project $project -Snapshot $script:Fake[1] -Plan $plan -RuleSet $script:Sets[1] -OutputPath (Join-Path $TestDrive 'longname.xlsx'))
        @($book.Sheets.Keys).Count | Should -Be 8
        foreach ($name in $book.Sheets.Keys) { $name | Should -Not -Match 'xxx' }
    }
}

Describe 'New-TcWorkbook, the measures of a run that knows their table' {
    It 'says Not collected or Not fully read, by the state of the table' {
        $snapshot = $script:Fake[1] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        Clear-TcWorkbookTenant -Snapshot $snapshot -Role 'S1'
        $snapshot['tenants']['S1']['tables']['groups'] = @()
        foreach ($line in @($snapshot['coverage'])) { if ($line['role'] -eq 'S1') { $line['status'] = 'Partial' } }
        $ruleSet = Invoke-TcRuleSet -Snapshot $snapshot
        foreach ($measure in @($ruleSet['measures'])) {
            if ($measure['label'] -eq 'Groups') { $measure['table'] = 'groups' }
            if ($measure['label'] -eq 'Licensed accounts') { $measure['table'] = 'users' }
        }
        $book = Read-TcXlsx -Path (New-TcWorkbook -Project (New-TcWorkbookProject) -Snapshot $snapshot -RuleSet $ruleSet -OutputPath (Join-Path $TestDrive 'states2.xlsx'))
        $cells = @($book.Sheets['Tenant view'].Cells.Values)
        $header = @($cells | Where-Object { $_.Value -ceq 'Measure' })[0].Row
        $column = @($cells | Where-Object { $_.Row -eq $header -and $_.Value -ceq 'S1' })[0].Column
        $value = { param([string]$Label)
            $row = @($cells | Where-Object { $_.Value -ceq $Label })[0].Row
            @($cells | Where-Object { $_.Row -eq $row -and $_.Column -eq $column })[0].Value
        }
        & $value 'Groups' | Should -BeExactly 'Not fully read'
        & $value 'Licensed accounts' | Should -BeExactly 'Not collected'
    }
}

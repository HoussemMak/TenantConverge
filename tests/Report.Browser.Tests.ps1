BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'Support/BrowserDriver.ps1')
    $script:Available = [bool](Find-TcBrowser)
    $script:Counts = @(@{ Count = 1 }, @{ Count = 2 }, @{ Count = 3 })
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')
    . (Join-Path $PSScriptRoot 'Support/ReportFixtures.ps1')
    . (Join-Path $PSScriptRoot 'Support/BrowserDriver.ps1')

    $script:Walk = Get-Content (Join-Path $PSScriptRoot 'Support/report-walk.js') -Raw

    function New-TcBrowserReport {
        <# Writes a report and returns its path. #>
        param([hashtable]$Fixture, [string]$Tracking)
        $folder = (New-Item -ItemType Directory -Path (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))).FullName
        if ($Tracking) { [System.IO.File]::WriteAllText((Join-Path $folder 'team-tracking.csv'), $Tracking, [System.Text.UTF8Encoding]::new($true)) }
        (New-TcReport -Project $Fixture['Project'] -Snapshot $Fixture['Snapshot'] -Plan $Fixture['Plan'] -RuleSet $Fixture['RuleSet'] -OutputPath $folder -WarningAction SilentlyContinue).Path
    }

    function Open-TcReport {
        <# Opens a report on a clean slate, with the walk loaded. #>
        param([string]$Path)
        Open-TcBrowserPage -Browser $script:Browser -Path $Path
        Invoke-TcPageScript -Browser $script:Browser -Script 'try { localStorage.clear(); sessionStorage.clear(); indexedDB.deleteDatabase("tenantconverge"); } catch (e) {} 1' | Out-Null
        Open-TcBrowserPage -Browser $script:Browser -Path $Path
        Invoke-TcPageScript -Browser $script:Browser -Script 'const whoDialog = document.getElementById("who"); if (whoDialog.open) whoDialog.close(); 1' | Out-Null
        Invoke-TcPageScript -Browser $script:Browser -Script $script:Walk | Out-Null
    }

    function Invoke-TcWalk {
        param([hashtable]$Options = @{})
        $json = $Options | ConvertTo-Json -Compress -Depth 5
        Invoke-TcPageScript -Browser $script:Browser -Script "window.reportWalk($json)"
    }

    function Invoke-Js { param([string]$Script) Invoke-TcPageScript -Browser $script:Browser -Script $Script }

    function Add-TcHostileText {
        <# Puts hostile text wherever a person of a tenant can write. It adds to each value, so the rules still fire. #>
        param([hashtable]$Fixture)

        $payloads = @('<img src=x onerror=alert(1)>', '</script><script>alert(2)</script>', '"><svg onload=window.__xss=3>', "' onmouseover='window.__xss=4", '<!-- open', '/*__SCRIPT__*/', '$& $1', '=cmd|'' /C calc''!A0', '<a href="javascript:alert(5)">x</a>', '`${alert(6)}`')
        $next = { $script:HostileIndex++; $payloads[$script:HostileIndex % $payloads.Count] }
        $script:HostileIndex = 0
        $snapshot = $Fixture['Snapshot']
        foreach ($role in @($snapshot['tenants'].Keys)) {
            $tenant = $snapshot['tenants'][$role]
            $tenant['displayName'] = '{0} {1}' -f $tenant['displayName'], (& $next)
            foreach ($table in @($tenant['tables'].Keys)) {
                foreach ($row in @($tenant['tables'][$table])) {
                    foreach ($key in @($row.Keys)) {
                        if ($key -match '^(Name|Title|Url|Group|Plan|Publisher|Value|Team|Owner|Record|Product|Inventory|Application|Display name|Message)$' -and $row[$key] -is [string]) { $row[$key] = '{0} {1}' -f $row[$key], (& $next) }
                    }
                }
            }
        }
        # A formula only runs from the start of a cell: some values are nothing but the formula.
        foreach ($row in @($snapshot['tenants']['Target']['tables']['servicePrincipals'])) { $row['Publisher'] = '=cmd|'' /C calc''!A0' }
        foreach ($line in @($snapshot['coverage'])) { $line['message'] = 'Refused ' + (& $next); $line['title'] = '{0} {1}' -f $line['title'], (& $next) }
        $Fixture['Project'].name = 'Summit <img src=x onerror=alert(1)>'
        $Fixture['Project'].target.displayName = 'Summit <img src=x onerror=alert(1)>'
        foreach ($source in $Fixture['Project'].sources) { $source.displayName = '{0} </script><b>x' -f $source.displayName }
        $Fixture['Project'].team = @('Pat <img src=x onerror=alert(1)>', "Sam ' onclick='alert(2)")
        $Fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $snapshot
        $Fixture['Plan'] = New-TcPlan -Project $Fixture['Project'] -Snapshot $snapshot -RuleSet $Fixture['RuleSet']
    }

    $script:Reports = @{}
    if (Find-TcBrowser) {
        foreach ($count in 1, 2, 3) { $script:Reports[$count] = New-TcBrowserReport -Fixture (Get-TcReportFixture -SourceCount $count -Folder $TestDrive) }
        $script:Browser = Start-TcBrowser -Path (Find-TcBrowser) -Folder $TestDrive
        Invoke-TcBrowser -Browser $script:Browser -Method 'Page.addScriptToEvaluateOnNewDocument' -Parameters @{ source = "window.alert = window.confirm = window.prompt = () => { window.__xss = 'dialog'; };" } | Out-Null
    }
}

AfterAll {
    if ($script:Browser) { Stop-TcBrowser -Browser $script:Browser }
}

Describe 'Every view, at <Count> source(s)' -ForEach $script:Counts -Skip:(-not $script:Available) {
    BeforeAll {
        Set-TcBrowserSize -Browser $script:Browser
        Open-TcReport -Path $script:Reports[$Count]
        $script:Found = Invoke-TcWalk -Options @{ deep = $true; keepText = $true; searches = @('account', 'mfa') }
    }

    It 'opens every view with no page error' {
        @($script:Found['views']).Count | Should -BeGreaterThan 15
        Get-TcPageProblem -Browser $script:Browser | Should -BeNullOrEmpty
    }

    It 'leaves no view blank' {
        $script:Found['blank'] | Should -BeNullOrEmpty
    }

    It 'has no empty column' {
        $script:Found['emptyColumns'] | Should -BeNullOrEmpty
    }

    It 'never mentions a tenant that does not exist' {
        $absent = @(@(@('S2', 'Birch Partners'), @('S3', 'Cedar Services')) | Where-Object { [int]$_[0].Substring(1) -gt $Count })
        foreach ($name in $absent) {
            $script:Found['text'] | Should -Not -Match ([regex]::Escape($name[1]))
            (Invoke-Js "document.querySelectorAll('.tab[href=`"#/$($name[0])`"],[style*=`"--$($name[0])`"]').length") | Should -Be 0
        }
    }

    It 'draws one band per source in the ledger' {
        Invoke-Js "go('summary'); route(); drawLedger(); document.querySelectorAll('#flow-svg path.stream').length" | Should -Be $Count
    }

    It 'has no page wider than a phone' {
        Set-TcBrowserSize -Browser $script:Browser -Phone
        Open-TcReport -Path $script:Reports[$Count]
        $phone = Invoke-TcWalk
        Set-TcBrowserSize -Browser $script:Browser
        $phone['wide'] | Should -BeNullOrEmpty
        Get-TcPageProblem -Browser $script:Browser | Should -BeNullOrEmpty
    }

    It 'prints with the bars hidden' {
        Invoke-TcBrowser -Browser $script:Browser -Method 'Emulation.setEmulatedMedia' -Parameters @{ media = 'print' } | Out-Null
        foreach ($view in 'summary', 'S1/plan', 'analysis/findings', 'solutions/products') {
            Invoke-Js "location.hash = '#/$view'; route(); 1" | Out-Null
            Invoke-Js "getComputedStyle(document.querySelector('.topbar')).display" | Should -Be 'none'
            $pdf = Invoke-TcBrowser -Browser $script:Browser -Method 'Page.printToPDF' -Parameters @{ printBackground = $true }
            $pdf['data'].Length | Should -BeGreaterThan 2000 -Because $view
        }
        Invoke-TcBrowser -Browser $script:Browser -Method 'Emulation.setEmulatedMedia' -Parameters @{ media = '' } | Out-Null
        Get-TcPageProblem -Browser $script:Browser | Should -BeNullOrEmpty
    }
}

Describe 'Hostile names' -Skip:(-not $script:Available) {
    BeforeAll {
        $fixture = Get-TcReportFixture -SourceCount 3 -Folder $TestDrive
        Add-TcHostileText -Fixture $fixture
        $tracking = "Type,Id,Label,Field,Value,Author,Date,Replaces`r`n" +
        'task,OLD-01.S3,"<img src=x onerror=alert(7)>",note,"</script><script>alert(8)</script>","<b>Sam</b>",2026-01-15T09:00:00.000Z,' + "`r`n" +
        'action,S3-GONE,"=HYPERLINK(""http://example.invalid"")",assignee,"<svg onload=alert(9)>",Sam,2026-01-15T09:00:00.000Z,' + "`r`n" +
        'action,"<img src=x onerror=alert(10)>",x,"<svg onload=alert(11)>","</script><script>alert(12)</script>","<b>Sam</b>",2026-01-15T09:00:00.000Z,' + "`r`n"
        $script:Hostile = New-TcBrowserReport -Fixture $fixture -Tracking $tracking
        Set-TcBrowserSize -Browser $script:Browser
        Open-TcReport -Path $script:Hostile
    }

    It 'stays text in every view, in <Theme>' -ForEach @(@{ Theme = 'light' }, @{ Theme = 'dark' }) {
        Invoke-Js "document.documentElement.dataset.theme = '$Theme'; 1" | Out-Null
        $found = Invoke-TcWalk -Options @{ deep = $true; keepText = $true; searches = @('<img', 'onerror', '</script') }
        $found['injected'] | Should -BeNullOrEmpty
        Invoke-Js 'window.__xss || ""' | Should -BeNullOrEmpty
        Get-TcPageProblem -Browser $script:Browser | Should -BeNullOrEmpty
        $found['text'] | Should -Match ([regex]::Escape('<img src=x onerror=alert(1)>'))
        $found['tips'] | Should -BeGreaterThan 50
    }

    It 'stays text in the title of the page' {
        Invoke-Js 'document.title' | Should -Match ([regex]::Escape('<img src=x onerror=alert(1)>'))
    }

    It 'stays text in filters, with the filter on' {
        Invoke-Js "go('S1', 'plan'); route(); const i = document.querySelector('[data-in=plan-q]'); i.value = '<img src=x'; i.dispatchEvent(new Event('input', { bubbles: true })); document.querySelector('[data-in=plan-q]').value" | Should -Be '<img src=x'
        Invoke-Js "document.querySelectorAll('#page img').length" | Should -Be 0
    }

    It 'stays text in the assignee menus' {
        Invoke-Js "document.querySelectorAll('#me option').length" | Should -Be 3
        Invoke-Js "document.querySelectorAll('#who-names img').length + document.querySelectorAll('#me img').length" | Should -Be 0
    }

    It 'keeps a hostile value as a value when it is typed back' {
        Invoke-Js "chooseMe('<img src=x onerror=alert(3)>'); render(); document.querySelectorAll('#me img, #page img').length" | Should -Be 0
        Invoke-Js "chooseMe(''); 1" | Out-Null
    }

    It 'cannot become a formula in any export' {
        Invoke-Js 'reportCapture(); 1' | Out-Null
        $files = @(Invoke-Js 'reportExportAll()')
        $files.Count | Should -BeGreaterThan 20
        $seen = 0
        foreach ($file in $files) {
            $file[0] | Should -Be ([char]0xFEFF)
            foreach ($row in ($file.TrimStart([char]0xFEFF) | ConvertFrom-Csv -Delimiter ',')) {
                foreach ($property in $row.PSObject.Properties) {
                    if ($property.Value -match '^\s*[=+@\-＝＋＠－]' -and $property.Value -notmatch '^\s*[+-]?\d+([.,]\d+)?\s*$') { throw "A cell of an export can run: $($property.Value)" }
                    if ($property.Value -match "^'=cmd") { $seen++ }
                }
            }
        }
        $seen | Should -BeGreaterThan 0 -Because 'the hostile text must reach an export, or this test proves nothing'
    }

    It 'cannot pollute the page through the tracking file' {
        Invoke-Js @'
adopt('Type,Id,Label,Field,Value,Author,Date,Replaces\r\naction,__proto__,x,status,Done,Pat,2026-01-15T09:00:00.000Z,\r\naction,constructor,x,assignee,Pat,Pat,2026-01-15T09:00:00.000Z,\r\naction,S1-X,x,note,hello,__proto__,2026-01-15T09:00:00.000Z,\r\n');
[({}).status, ({}).assignee, ({}).text].filter(Boolean).length
'@ | Should -Be 0
    }
}

Describe 'The policy of the page' -Skip:(-not $script:Available) {
    BeforeAll {
        Set-TcBrowserSize -Browser $script:Browser
        Open-TcReport -Path $script:Reports[3]
        Invoke-TcWalk -Options @{ deep = $true } | Out-Null
        $script:Requests = @(Get-TcPageRequest -Browser $script:Browser)
        Invoke-Js "window.violations = []; document.addEventListener('securitypolicyviolation', e => window.violations.push(e.blockedURI + ' ' + e.effectiveDirective)); 1" | Out-Null
    }

    It 'makes no outbound connection in any view' {
        $script:Requests | Should -Not -BeNullOrEmpty
        $script:Requests | Where-Object { $_ -notmatch '^file:' } | Should -BeNullOrEmpty
    }

    # An address that cannot resolve fails with or without a policy, so only the report of the browser counts.
    It 'blocks <Name>, by the policy of the page' -ForEach @(
        @{ Name = 'fetch'; Address = 'example.invalid/a'; Directive = 'connect-src'; Code = "fetch('https://example.invalid/a').then(() => 'open', () => 'blocked')" }
        @{ Name = 'XMLHttpRequest'; Address = 'example.invalid/b'; Directive = 'connect-src'; Code = "new Promise(ok => { const x = new XMLHttpRequest(); x.onload = () => ok('open'); x.onerror = () => ok('blocked'); try { x.open('GET', 'https://example.invalid/b'); x.send(); } catch (e) { ok('blocked'); } })" }
        @{ Name = 'an image'; Address = 'example.invalid/c.png'; Directive = 'img-src'; Code = "new Promise(ok => { const i = new Image(); i.onload = () => ok('open'); i.onerror = () => ok('blocked'); i.src = 'https://example.invalid/c.png'; })" }
        @{ Name = 'a web socket'; Address = 'example.invalid/d'; Directive = 'connect-src'; Code = "new Promise(ok => { try { const w = new WebSocket('wss://example.invalid/d'); w.onopen = () => ok('open'); w.onerror = () => ok('blocked'); } catch (e) { ok('blocked'); } })" }
        @{ Name = 'a beacon'; Address = 'example.invalid/e'; Directive = 'connect-src'; Code = "new Promise(ok => { document.addEventListener('securitypolicyviolation', () => ok('blocked'), { once: true }); try { navigator.sendBeacon('https://example.invalid/e', 'x'); } catch (e) { ok('blocked'); } })" }
        @{ Name = 'a style sheet'; Address = 'example.invalid/f.css'; Directive = 'style-src'; Code = "new Promise(ok => { const l = document.createElement('link'); l.rel = 'stylesheet'; l.href = 'https://example.invalid/f.css'; l.onload = () => ok('open'); l.onerror = () => ok('blocked'); document.head.append(l); })" }
        @{ Name = 'a remote script'; Address = 'example.invalid/g.js'; Directive = 'script-src'; Code = "new Promise(ok => { const s = document.createElement('script'); s.src = 'https://example.invalid/g.js'; s.onload = () => ok('open'); s.onerror = () => ok('blocked'); document.head.append(s); })" }
        @{ Name = 'a remote font'; Address = 'example.invalid/h.woff2'; Directive = 'font-src'; Code = "new FontFace('Remote', 'url(https://example.invalid/h.woff2)').load().then(() => 'open', () => 'blocked')" }
    ) {
        Invoke-Js $Code | Should -Be 'blocked'
        Start-Sleep -Milliseconds 100
        (Invoke-Js "window.violations.join(' | ')") | Should -Match ([regex]::Escape($Address))
        (Invoke-Js "window.violations.join(' | ')") | Should -Match $Directive
    }

    It 'sends no blocked request to the network' {
        $reached = foreach ($message in $script:Browser.Events) {
            if ($message['method'] -eq 'Network.responseReceived' -and $message['params']['response']['url'] -match '^https?:') { $message['params']['response']['url'] }
        }
        $reached | Should -BeNullOrEmpty
    }

    It 'runs no script that gets into the page, even past the escaping' {
        Invoke-Js @'
new Promise(ok => {
  document.getElementById('page').insertAdjacentHTML('beforeend', '<img src=x onerror="window.__ran = 1">');
  const s = document.createElement('script'); s.textContent = 'window.__ran = 2'; document.body.append(s);
  setTimeout(() => ok(String(window.__ran || 'nothing ran')), 100);
})
'@ | Should -Be 'nothing ran'
    }
}

Describe 'The palette, by role' -Skip:(-not $script:Available) {
    It 'gives <Mode> its colors' -ForEach @(
        @{ Mode = 'light'; Expected = '#2E62C0,#0E8F7E,#8A52D8,#D0457F' }
        @{ Mode = 'dark'; Expected = '#4F86EE,#10A88A,#AA6CEA,#E65F90' }
    ) {
        Open-TcReport -Path $script:Reports[3]
        $found = Invoke-Js "document.documentElement.dataset.theme = '$Mode'; const s = getComputedStyle(document.documentElement); ['Target', 'S1', 'S2', 'S3'].map(r => s.getPropertyValue('--' + r).trim().toUpperCase()).join(',')"
        $found | Should -BeExactly $Expected
    }
}

Describe 'Names' -Skip:(-not $script:Available) {
    It 'offers the team of the project, then a free name' {
        Open-TcReport -Path $script:Reports[1]
        Invoke-Js 'document.querySelectorAll("#who-names button").length' | Should -Be 2
        Invoke-Js 'askWho(); document.getElementById("who-input").value = "Noor Example"; document.getElementById("who-free").requestSubmit(); ME' | Should -Be 'Noor Example'
        Invoke-Js 'document.getElementById("who").open' | Should -BeFalse
        Invoke-Js 'document.getElementById("me").value' | Should -Be 'Noor Example'
    }

    It 'takes a free name when the project has no team' {
        $fixture = Get-TcReportFixture -SourceCount 1 -Folder $TestDrive -Team @()
        Open-TcReport -Path (New-TcBrowserReport -Fixture $fixture)
        Invoke-Js 'document.querySelectorAll("#who-names button").length' | Should -Be 0
        Invoke-Js 'askWho(); document.getElementById("who-input").value = "Noor Example"; document.getElementById("who-free").requestSubmit(); ME' | Should -Be 'Noor Example'
    }

    It 'keeps long and accented names inside a phone, and readable' {
        $fixture = Get-TcReportFixture -SourceCount 3 -Folder $TestDrive
        $long = 'Société Générale de Réassurance et de Développement du Québec Nord'.Substring(0, 64)
        $unbroken = 'Ñ' * 64
        $fixture['Project'].sources[0].displayName = $long
        $fixture['Project'].sources[1].displayName = $unbroken
        $fixture['Project'].target.displayName = $long
        foreach ($row in @($fixture['Snapshot']['tenants']['S1']['tables']['users'])) { $row['Name'] = 'É' * 300 }
        foreach ($row in @($fixture['Snapshot']['tenants']['S1']['tables']['sites'])) { $row['Url'] = 'https://alpine.example/sites/' + ('très-long-' * 40) }
        $fixture['Snapshot']['tenants']['S1']['displayName'] = $long
        $fixture['Snapshot']['tenants']['S2']['displayName'] = $unbroken
        $fixture['Snapshot']['tenants']['Target']['displayName'] = $long
        $fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $fixture['Snapshot']
        $fixture['Plan'] = New-TcPlan -Project $fixture['Project'] -Snapshot $fixture['Snapshot'] -RuleSet $fixture['RuleSet']
        $path = New-TcBrowserReport -Fixture $fixture

        Set-TcBrowserSize -Browser $script:Browser -Phone
        Open-TcReport -Path $path
        $found = Invoke-TcWalk -Options @{ keepText = $true }
        Set-TcBrowserSize -Browser $script:Browser

        $found['wide'] | Should -BeNullOrEmpty
        $found['text'] | Should -Match 'Société Générale'
        Get-TcPageProblem -Browser $script:Browser | Should -BeNullOrEmpty
    }
}

Describe 'What must stay visible' -Skip:(-not $script:Available) {
    BeforeAll {
        $fixture = Get-TcReportFixture -SourceCount 2 -Folder $TestDrive
        Remove-TcReportTable -Snapshot $fixture['Snapshot'] -Role 'S2' -Table 'mailboxUsage'
        Clear-TcReportTable -Snapshot $fixture['Snapshot'] -Role 'S2' -Table 'sites'
        $fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $fixture['Snapshot']
        $fixture['Plan'] = New-TcPlan -Project $fixture['Project'] -Snapshot $fixture['Snapshot'] -RuleSet $fixture['RuleSet']
        $script:Unconfirmed = @($fixture['Plan']['tasks'] | Where-Object { $_['confirmation'] -eq 'Unconfirmed' })
        $tracking = "Type,Id,Label,Field,Value,Author,Date,Replaces`r`ntask,OLD-01.S3,A task that left,status,Done,Sam,2026-01-15T09:00:00.000Z,`r`n"
        $script:Path = New-TcBrowserReport -Fixture $fixture -Tracking $tracking
        Set-TcBrowserSize -Browser $script:Browser
        Open-TcReport -Path $script:Path
    }

    It 'shows an unread measure as a gap, not a zero' {
        $row = Invoke-Js "go('summary'); route(); drawLedger(); [...document.querySelectorAll('.sheet tbody tr')].find(r => r.textContent.startsWith('Mailbox volume')).innerText"
        $row | Should -Match 'Not collected'
    }

    It 'calls a total that misses a source a minimum' {
        $row = Invoke-Js "[...document.querySelectorAll('.sheet tbody tr')].find(r => r.textContent.startsWith('Mailbox volume')).innerText"
        $row | Should -Match 'at least'
    }

    It 'tells a partly read table from a table that was not collected' {
        Invoke-Js "[...document.querySelectorAll('.sheet tbody tr')].find(r => r.textContent.startsWith('Site volume')).innerText" | Should -Match 'Not fully read'
    }

    It 'names the sources behind the gap in its tooltip' {
        Invoke-Js "[...document.querySelectorAll('.sheet tbody tr')].find(r => r.textContent.startsWith('Mailbox volume')).querySelector('.minimum').dataset.tip" | Should -Match 'Birch Partners'
    }

    It 'shows both scores, and what the difference means' {
        $text = Invoke-Js "document.querySelector('.scores').innerText + document.querySelector('#page').innerText"
        $text | Should -Match 'Score of what was read'
        $text | Should -Match 'points lost to what could not be read'
    }

    It 'keeps an unconfirmed task visible with its reason' {
        $script:Unconfirmed.Count | Should -BeGreaterThan 0
        $text = Invoke-Js "go('steering', 'tasks'); route(); document.querySelector('#page').innerText"
        $text | Should -Match 'Unconfirmed'
        $text | Should -Match ([regex]::Escape($script:Unconfirmed[0]['reason']))
    }

    It 'keeps an orphan tracking row visible, with its label' {
        $text = Invoke-Js "go('steering', 'team'); route(); document.querySelector('.orphans').innerText"
        $text | Should -Match 'OLD-01.S3'
        $text | Should -Match 'A task that left'
    }

    It 'writes an orphan row back with its label' {
        Invoke-Js 'stateToCsv()' | Should -Match 'task,OLD-01\.S3,A task that left,status,Done,Sam'
    }

    It 'shows a table that was not collected as a gap in the data tab' {
        Invoke-Js "go('S2', 'data'); route(); 1" | Out-Null
        Start-Sleep -Milliseconds 150
        $text = Invoke-Js "TV.S2.table = 'mailboxUsage'; showTable('S2'); document.querySelector('#table').innerText"
        $text | Should -Match 'Not collected'
        $text | Should -Not -Match 'nothing of this kind'
    }
}

Describe 'The flow chart beside the sheet' -Skip:(-not $script:Available) {
    BeforeAll {
        $fixture = Get-TcReportFixture -SourceCount 3 -Folder $TestDrive
        foreach ($table in 'users', 'mailboxUsage') { Remove-TcReportTable -Snapshot $fixture['Snapshot'] -Role 'Target' -Table $table }
        foreach ($role in 'S1', 'S2', 'S3') { Remove-TcReportTable -Snapshot $fixture['Snapshot'] -Role $role -Table 'teams' }
        foreach ($role in 'S1', 'S2', 'S3', 'Target') { Remove-TcReportTable -Snapshot $fixture['Snapshot'] -Role $role -Table 'sites' }
        $fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $fixture['Snapshot']
        $fixture['Plan'] = New-TcPlan -Project $fixture['Project'] -Snapshot $fixture['Snapshot'] -RuleSet $fixture['RuleSet']
        Set-TcBrowserSize -Browser $script:Browser
        Open-TcReport -Path (New-TcBrowserReport -Fixture $fixture)

        function Get-TcLedgerAfter {
            <# Returns the big figure of the chart and the last cell of the sheet, for one line. #>
            param([string]$Line)
            Invoke-Js "go('summary'); route(); chosenLine = '$Line'; drawLedger(); JSON.stringify({ chart: [...document.querySelectorAll('#flow-svg text')].pop().textContent, sheet: [...document.querySelectorAll('.sheet tbody tr')].find(r => r.textContent.startsWith('$($Line -replace ' \(GB\)', '')')).querySelector('.total').innerText })" | ConvertFrom-Json
        }
    }

    It 'calls the total a minimum when the target was not read: <Line>' -ForEach @(@{ Line = 'Active member accounts' }, @{ Line = 'Mailbox volume (GB)' }) {
        $after = Get-TcLedgerAfter -Line $Line
        $after.sheet | Should -Match '^at least \d'
        $after.chart | Should -BeExactly $after.sheet
    }

    It 'says not read when no source was read, even with the target read' {
        $after = Get-TcLedgerAfter -Line 'Teams'
        $after.sheet | Should -Be 'Not read'
        $after.chart | Should -Be 'not read'
    }

    It 'says not read when nothing was read at all' {
        $after = Get-TcLedgerAfter -Line 'Sites'
        $after.sheet | Should -Be 'Not read'
        $after.chart | Should -Be 'not read'
    }

    It 'keeps a plain total when everything was read' {
        $after = Get-TcLedgerAfter -Line 'User mailboxes'
        $after.sheet | Should -Match '^\d'
        $after.chart | Should -BeExactly $after.sheet
    }
}

Describe 'Product traces, where a tenant was not read' -Skip:(-not $script:Available) {
    BeforeAll {
        function Get-TcProductExport {
            <# Runs the products export of the open report and returns its rows. #>
            $text = Invoke-Js 'reportCapture(); reportExports.length = 0; DO["csv-products"](); reportExports[0].text()'
            $text.TrimStart([char]0xFEFF) | ConvertFrom-Csv -Delimiter ','
        }

        $fixture = Get-TcReportFixture -SourceCount 3 -Folder $TestDrive
        $fixture['Snapshot']['tenants'].Remove('S3')
        $fixture['Snapshot']['coverage'] = @($fixture['Snapshot']['coverage'] | Where-Object { $_['role'] -ne 'S3' })
        Remove-TcReportTable -Snapshot $fixture['Snapshot'] -Role 'Target' -Table 'servicePrincipals'
        $fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $fixture['Snapshot']
        $fixture['Plan'] = New-TcPlan -Project $fixture['Project'] -Snapshot $fixture['Snapshot'] -RuleSet $fixture['RuleSet']
        Set-TcBrowserSize -Browser $script:Browser
        Open-TcReport -Path (New-TcBrowserReport -Fixture $fixture)
        $script:Products = @(Get-TcProductExport)
    }

    It 'writes the export with a line per product' {
        $script:Products.Count | Should -Be (Invoke-Js 'SOL.products.length')
    }

    It 'writes no zero for a source the snapshot has not reached' {
        @($script:Products.'Cedar Services' | Sort-Object -Unique) | Should -Not -Contain '0'
        @($script:Products.'Cedar Services' | Where-Object { $_ -eq 'Not collected' }).Count | Should -BeGreaterThan 0
    }

    It 'writes no zero for a tenant whose technical tables were not read' {
        @($script:Products.'Summit Holdings' | Sort-Object -Unique) | Should -Not -Contain '0'
        @($script:Products.'Summit Holdings' | Where-Object { $_ -eq 'Not fully read' }).Count | Should -BeGreaterThan 0
    }

    It 'writes no zero for a product that was not searched' {
        $name = Invoke-Js 'SOL.products.find(p => !p.searched).name'
        $line = $script:Products | Where-Object { $_.Product -eq $name }
        foreach ($tenant in 'Alpine Group', 'Birch Partners', 'Cedar Services', 'Summit Holdings') { $line.$tenant | Should -Be 'Not searched' }
    }

    It 'keeps a true zero where every technical table was read' {
        # The fictional snapshot leaves a few tables unread everywhere: this tenant is the one that read them all.
        Invoke-Js 'SOL.traceCoverage.S1.unread = []; 1' | Out-Null
        @(Get-TcProductExport | Where-Object { $_.'Alpine Group' -eq '0' }).Count | Should -BeGreaterThan 0
    }

    It 'prints a gap on the sheet, not a zero, on <Name>' -ForEach @(
        @{ Name = 'Summit Holdings'; Role = 'Target'; Label = 'Not fully read'; Small = '1 table not read' }
        @{ Name = 'Cedar Services'; Role = 'S3'; Label = 'Not collected'; Small = '' }
    ) {
        $cell = Invoke-Js "const id = SOL.products.find(p => p.searched && !p.traces.$Role).id; go('solutions', 'products', id); route(); [...document.querySelectorAll('.trace > div')].find(d => d.querySelector('.tab-name').textContent === '$Name').innerText"
        $cell | Should -Match ([regex]::Escape($Label))
        $cell | Should -Not -Match '(?m)^0$'
        if ($Small) { $cell | Should -Match ([regex]::Escape($Small)) }
    }

    It 'prints a true zero on the sheet' {
        Invoke-Js "SOL.traceCoverage.S1.unread = []; const id = SOL.products.find(p => p.searched && !p.traces.S1).id; go('solutions', 'products', id); route(); [...document.querySelectorAll('.trace > div')].find(d => d.querySelector('.tab-name').textContent === 'Alpine Group').querySelector('b').innerText" | Should -Be '0'
    }
}

Describe 'Reports with little to show' -Skip:(-not $script:Available) {
    It 'renders a tenant with nothing collected, and says so' {
        $fixture = Get-TcReportFixture -SourceCount 2 -Folder $TestDrive
        Clear-TcReportTenant -Snapshot $fixture['Snapshot'] -Role 'S2'
        $fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $fixture['Snapshot']
        $fixture['Plan'] = New-TcPlan -Project $fixture['Project'] -Snapshot $fixture['Snapshot'] -RuleSet $fixture['RuleSet']
        Open-TcReport -Path (New-TcBrowserReport -Fixture $fixture)
        $found = Invoke-TcWalk -Options @{ deep = $true }
        Get-TcPageProblem -Browser $script:Browser | Should -BeNullOrEmpty
        $found['blank'] | Should -BeNullOrEmpty
        Invoke-Js "go('S2', 'plan'); route(); document.querySelector('#page').innerText" | Should -Match 'Nothing was collected for this tenant'
        Invoke-Js "go('summary'); route(); document.querySelector('#page').innerText" | Should -Match 'nothing was collected'
    }

    It 'renders a source the snapshot has not reached, and says so' {
        $fixture = Get-TcReportFixture -SourceCount 2 -Folder $TestDrive
        $fixture['Snapshot']['tenants'].Remove('S2')
        $fixture['Snapshot']['coverage'] = @($fixture['Snapshot']['coverage'] | Where-Object { $_['role'] -ne 'S2' })
        $fixture['RuleSet'] = Invoke-TcRuleSet -Snapshot $fixture['Snapshot']
        $fixture['Plan'] = New-TcPlan -Project $fixture['Project'] -Snapshot $fixture['Snapshot'] -RuleSet $fixture['RuleSet']
        Open-TcReport -Path (New-TcBrowserReport -Fixture $fixture)
        Invoke-TcWalk -Options @{ deep = $true } | Out-Null
        Get-TcPageProblem -Browser $script:Browser | Should -BeNullOrEmpty
        Invoke-Js "go('S2', 'plan'); route(); document.querySelector('#page').innerText" | Should -Match 'not in the snapshot'
    }

    It 'renders an empty plan, and says so' {
        $fixture = Get-TcReportFixture -SourceCount 1 -Folder $TestDrive
        $fixture['Plan'] = New-TcEmptyPlan
        Open-TcReport -Path (New-TcBrowserReport -Fixture $fixture)
        $found = Invoke-TcWalk -Options @{ deep = $true }
        Get-TcPageProblem -Browser $script:Browser | Should -BeNullOrEmpty
        $found['blank'] | Should -BeNullOrEmpty
        Invoke-Js "go('S1', 'plan'); route(); document.querySelector('#page').innerText" | Should -Match 'The plan has no action for this tenant'
        Invoke-Js "go('summary'); route(); document.querySelector('#page').innerText" | Should -Match 'The plan has no action yet'
    }
}

Describe 'Remediations in the page' -Skip:(-not $script:Available) {
    It 'shows the list, and the mention, when there are some' {
        $fixture = Get-TcReportFixture -SourceCount 1 -Folder $TestDrive
        $fixture['Plan']['remediations'] = Get-TcSyntheticRemediation
        $fixture['Plan']['actions'][0]['remediations'] = @('REM-001', 'REM-999')
        Open-TcReport -Path (New-TcBrowserReport -Fixture $fixture)
        Invoke-TcWalk -Options @{ deep = $true } | Out-Null
        Get-TcPageProblem -Browser $script:Browser | Should -BeNullOrEmpty
        $text = Invoke-Js "go('steering', 'remediations'); route(); document.querySelector('#page').innerText"
        $text | Should -Match ([regex]::Escape('UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.'))
        $text | Should -Match 'Untested'
        $text | Should -Match 'Tested'
        Invoke-Js "const a = D.actions[0]; opened.add(a.id); go(tabOf(a.role), 'plan'); route(); document.getElementById('a-' + a.id).innerText" | Should -Match 'Untested'
    }

    It 'shows no tab and no mark when the list is empty' {
        $fixture = Get-TcReportFixture -SourceCount 1 -Folder $TestDrive
        Remove-TcPlanRemediation -Plan $fixture['Plan'] | Out-Null
        Open-TcReport -Path (New-TcBrowserReport -Fixture $fixture)
        Invoke-Js "go('steering'); route(); document.querySelector('.subnav').innerText" | Should -Not -Match 'Remediations'
        Invoke-Js "D.actions.slice(0, 5).forEach(a => opened.add(a.id)); go('S1', 'plan'); route(); document.querySelector('#page').innerText" | Should -Not -Match 'Untested'
    }
}

Describe 'The tracking file, in the page' -Skip:(-not $script:Available) {
    BeforeAll {
        Set-TcBrowserSize -Browser $script:Browser
        Open-TcReport -Path $script:Reports[2]
    }

    It 'writes what Excel can read: comma, BOM, CRLF, English columns' {
        $text = Invoke-Js "chooseMe('Pat Example'); const a = D.actions[0]; write(record('a', a.id), 'status', 'done'); stateToCsv()"
        $text[0] | Should -Be ([char]0xFEFF)
        ($text.TrimStart([char]0xFEFF) -split "`r`n")[0] | Should -Be 'Type,Id,Label,Field,Value,Author,Date,Replaces'
        $text | Should -Match ',status,Done,Pat Example,'
    }

    It 'guards what a person types, exactly as the module guards a CSV: <Value>' -ForEach @(
        @{ Value = '=1+1' }, @{ Value = '+1+1' }, @{ Value = '-1+1' }, @{ Value = '@SUM(A1)' }, @{ Value = '  =1' }, @{ Value = '-1' }, @{ Value = '+15145550100' }, @{ Value = '3.14' }, @{ Value = 'plain' }, @{ Value = "＝1+1" }, @{ Value = '' }
    ) {
        $expected = InModuleScope TenantConverge -Parameters @{ Value = $Value } { param($Value) ConvertTo-TcCsvCell $Value }
        Invoke-Js "safeCell($(ConvertTo-Json -InputObject $Value))" | Should -BeExactly $expected
    }

    It 'gives a typed formula back unchanged after a round trip' {
        $back = Invoke-Js @'
const a = D.actions[1]; const r = record('a', a.id); (r.notes = r.notes || box())['Pat Example'] = { text: '=HYPERLINK("http://example.invalid","a, b")\nsecond line', at: '2026-01-15T09:00:00.000Z' };
const text = stateToCsv(), st = csvToState(text);
JSON.stringify({ raw: text.includes(`"'=HYPERLINK`), value: st.actions[a.id].notes['Pat Example'].text })
'@ | ConvertFrom-Json
        $back.raw | Should -BeTrue
        $back.value | Should -BeExactly "=HYPERLINK(`"http://example.invalid`",`"a, b`")`nsecond line"
    }

    It 'reads a file Excel saved with semicolons' {
        Invoke-Js "JSON.stringify(csvToState('Type;Id;Label;Field;Value;Author;Date;Replaces\r\ntask;X.S1;Title, with a comma;status;Done;Pat;2026-01-15T09:00:00.000Z;\r\n').tasks['X.S1'].status)" | Should -Be '"done"'
    }

    It 'refuses a file with no columns' {
        Invoke-Js "try { csvToState('nothing here\r\n1,2\r\n'); 'read'; } catch (e) { e.message; }" | Should -Be 'format'
    }

    It 'follows the file: a row removed by hand leaves, and a copy stays' {
        $result = Invoke-Js @'
const id = D.actions[2].id, row = `action,${id},T,status,Done,Pat,2026-01-15T09:00:00.000Z,\r\n`, head = 'Type,Id,Label,Field,Value,Author,Date,Replaces\r\n';
P.pending = box(); adopt(head + row); const first = statusOf(id);
const r = adopt(head); JSON.stringify({ first, after: statusOf(id), removed: r.removed, copy: !!readJson(KEY_COPY) })
'@ | ConvertFrom-Json
        $result.first | Should -Be 'done'
        $result.after | Should -Be 'todo'
        $result.removed | Should -BeGreaterThan 0
        $result.copy | Should -BeTrue
    }

    It 'keeps what is not written yet when the file changes under it' {
        $result = Invoke-Js @'
const id = D.actions[3].id, head = 'Type,Id,Label,Field,Value,Author,Date,Replaces\r\n';
P.pending = box(); adopt(head); write(record('a', id), 'status', 'doing'); const r = adopt(head);
JSON.stringify({ status: statusOf(id), toWrite: r.toWrite })
'@ | ConvertFrom-Json
        $result.status | Should -Be 'doing'
        $result.toWrite | Should -BeTrue
    }

    It 'keeps both notes of two people on one action' {
        Invoke-Js @'
const id = D.actions[4].id, head = 'Type,Id,Label,Field,Value,Author,Date,Replaces\r\n';
P.pending = box(); adopt(head + `action,${id},T,note,mine,Pat,2026-01-15T09:00:00.000Z,\r\naction,${id},T,note,yours,Sam,2026-01-15T09:01:00.000Z,\r\n`);
Object.keys(P.actions[id].notes).sort().join(',')
'@ | Should -Be 'Pat,Sam'
    }

    It 'keeps the latest of two values that ignored each other, and shows the conflict' {
        $result = Invoke-Js @'
const id = D.actions[5].id, res = { changed: 0, conflicts: 0 }; P.conflicts.length = 0;
const dst = { status: 'doing', t: { status: { at: '2026-01-15T09:00:00.000Z', by: 'Pat', prev: '' } } }, src = { status: 'done', t: { status: { at: '2026-01-15T09:05:00.000Z', by: 'Sam', prev: '' } } };
mergeFields(dst, src, ['status'], id, res); JSON.stringify({ kept: dst.status, conflicts: P.conflicts.length })
'@ | ConvertFrom-Json
        $result.kept | Should -Be 'done'
        $result.conflicts | Should -Be 1
    }

    It 'sees no conflict when someone follows a colleague' {
        Invoke-Js @'
const id = D.actions[5].id, res = { changed: 0, conflicts: 0 }; P.conflicts.length = 0;
const dst = { status: 'doing', t: { status: { at: '2026-01-15T09:00:00.000Z', by: 'Pat', prev: '' } } }, src = { status: 'done', t: { status: { at: '2026-01-15T09:05:00.000Z', by: 'Sam', prev: '2026-01-15T09:00:00.000Z' } } };
mergeFields(dst, src, ['status'], id, res); P.conflicts.length
'@ | Should -Be 0
    }

    It 'starts from the file in a new browser, and keeps the file link per project' {
        Invoke-Js 'PROJECT' | Should -Match 'summit\.example'
        Invoke-Js 'KEY' | Should -Match ([regex]::Escape('summit.example'))
    }
}

Describe 'A file typed by hand, read at generation' -Skip:(-not $script:Available) {
    It 'keeps every row a person typed, before any link to the file' {
        $fixture = Get-TcReportFixture -SourceCount 2 -Folder $TestDrive
        $ids = @($fixture['Plan']['actions'] | Select-Object -First 2 | ForEach-Object { $_['id'] })
        $tracking = "Type,Id,Label,Field,Value,Author,Date,Replaces`r`n" +
        "action,$($ids[0]),A title,status,Finished,Sam,2026-01-15T09:00:00.000Z,`r`n" +
        "action,$($ids[1]),A title,Status,Done,Sam,2026-01-15T09:00:00.000Z,`r`n" +
        "configuration,S1|A setting,,applied,yes,Sam,2026-01-15T09:00:00.000Z,`r`n"
        Set-TcBrowserSize -Browser $script:Browser
        Open-TcReport -Path (New-TcBrowserReport -Fixture $fixture -Tracking $tracking)
        Invoke-Js 'countRows()' | Should -Be 3
        Invoke-Js "statusOf('$($ids[0])')" | Should -Be 'todo'
        Invoke-Js "statusOf('$($ids[1])')" | Should -Be 'done'
        Invoke-Js "applied('S1|A setting')" | Should -BeTrue
        Invoke-Js 'stateToCsv()' | Should -Match ',A title,status,Finished,Sam,'
        Invoke-Js "go('steering', 'team'); route(); document.querySelector('.unrecognised').innerText" | Should -Match 'Finished'
        Get-TcPageProblem -Browser $script:Browser | Should -BeNullOrEmpty
    }
}

Describe 'Two tabs of one report' -Skip:(-not $script:Available) {
    # Both tabs are real pages of one browser. Each is open before either of them saves anything. A tab can miss a write
    # made a few milliseconds earlier in the other one, and the tabs then repair that between them: a person is slower
    # than that, so a test that closes a tab first waits for the store to hold everything, and fails if it never does.
    BeforeAll {
        function Invoke-Second { param([string]$Script) Invoke-TcPageScript -Browser $script:Second -Script $Script }

        function Wait-TcStore {
            <# Waits for the store, as one tab reads it, to hold this many updates. Returns how many it holds. #>
            param($Tab, [int]$Count)
            Invoke-TcPageScript -Browser $Tab -Script "new Promise(ok => { const end = Date.now() + 5000; const n = () => Object.keys((readJson(KEY) || {}).pending || {}).length; (function f() { if (n() >= $Count || Date.now() > end) ok(n()); else setTimeout(f, 10); })(); })"
        }

        function Save-TcStatus {
            <# Records a status as a person does, in one tab, and stops the timer that would look for a file. #>
            param($Tab, [int]$Action, [string]$Status)
            Invoke-TcPageScript -Browser $Tab -Script "write(record('a', D.actions[$Action].id), 'status', '$Status'); clearTimeout(LINK.timer); 1" | Out-Null
        }
    }

    BeforeEach {
        Set-TcBrowserSize -Browser $script:Browser
        Open-TcReport -Path $script:Reports[2]
        Invoke-Js "chooseMe('Pat Example'); 1" | Out-Null
        $script:Second = Open-TcBrowserTab -Browser $script:Browser -Path $script:Reports[2]
        Invoke-Second "chooseMe('Pat Example'); document.getElementById('who').close(); 1" | Out-Null
    }

    AfterEach {
        if ($script:Second) { Close-TcBrowserTab -Tab $script:Second; $script:Second = $null }
    }

    It 'keeps the updates of a tab that was closed, when the other one types last' {
        Save-TcStatus -Tab $script:Browser -Action 0 -Status 'done'
        Save-TcStatus -Tab $script:Second -Action 1 -Status 'doing'
        Save-TcStatus -Tab $script:Browser -Action 2 -Status 'blocked'
        Wait-TcStore -Tab $script:Browser -Count 3 | Should -Be 3
        Close-TcBrowserTab -Tab $script:Second; $script:Second = $null
        Open-TcBrowserPage -Browser $script:Browser -Path $script:Reports[2]
        Invoke-Js 'JSON.stringify([0, 1, 2].map(i => statusOf(D.actions[i].id)))' | Should -Be '["done","doing","blocked"]'
    }

    It 'keeps the updates of both after a reload of each' {
        Save-TcStatus -Tab $script:Browser -Action 0 -Status 'done'
        Save-TcStatus -Tab $script:Second -Action 1 -Status 'doing'
        Save-TcStatus -Tab $script:Browser -Action 2 -Status 'blocked'
        Save-TcStatus -Tab $script:Second -Action 3 -Status 'na'
        Wait-TcStore -Tab $script:Second -Count 4 | Should -Be 4
        Open-TcBrowserPage -Browser $script:Browser -Path $script:Reports[2]
        Open-TcBrowserPage -Browser $script:Second -Path $script:Reports[2]
        Invoke-Js 'JSON.stringify([0, 1, 2, 3].map(i => statusOf(D.actions[i].id)))' | Should -Be '["done","doing","blocked","na"]'
        Invoke-Second 'JSON.stringify([0, 1, 2, 3].map(i => statusOf(D.actions[i].id)))' | Should -Be '["done","doing","blocked","na"]'
    }

    It 'keeps what still has to reach the file, so nothing waits in vain' {
        Save-TcStatus -Tab $script:Browser -Action 0 -Status 'done'
        Save-TcStatus -Tab $script:Second -Action 1 -Status 'doing'
        Save-TcStatus -Tab $script:Browser -Action 2 -Status 'blocked'
        Wait-TcStore -Tab $script:Browser -Count 3 | Should -Be 3
    }

    It 'puts back what a tab wrote over, when it missed a write by a few milliseconds' {
        # A read of the store can miss a write made in another tab just before: this is what that write looks like.
        Save-TcStatus -Tab $script:Second -Action 1 -Status 'doing'
        Wait-TcStore -Tab $script:Browser -Count 1 | Should -Be 1
        Invoke-Js 'const s = readJson(KEY); s.pending = {}; delete s.actions[D.actions[1].id]; localStorage.setItem(KEY, JSON.stringify(s)); 1' | Out-Null
        Wait-TcStore -Tab $script:Browser -Count 1 | Should -Be 1
        Invoke-Js 'readJson(KEY).actions[D.actions[1].id].status' | Should -Be 'doing'
    }

    It 'stops writing once the tabs agree' {
        Invoke-Js 'window.heard = 0; window.addEventListener("storage", e => { if (e.key === KEY) window.heard++; }); 1' | Out-Null
        Invoke-Second 'window.heard = 0; window.addEventListener("storage", e => { if (e.key === KEY) window.heard++; }); 1' | Out-Null
        Save-TcStatus -Tab $script:Browser -Action 0 -Status 'done'
        Save-TcStatus -Tab $script:Second -Action 1 -Status 'doing'
        Invoke-Js 'const s = readJson(KEY); s.pending = {}; delete s.actions[D.actions[1].id]; delete s.actions[D.actions[0].id]; localStorage.setItem(KEY, JSON.stringify(s)); 1' | Out-Null
        Wait-TcStore -Tab $script:Browser -Count 2 | Should -Be 2
        Start-Sleep -Milliseconds 300
        $before = (Invoke-Js 'window.heard') + (Invoke-Second 'window.heard')
        Start-Sleep -Milliseconds 700
        (Invoke-Js 'window.heard') + (Invoke-Second 'window.heard') | Should -Be $before
    }

    It 'stops waiting for what another tab took to the file' {
        Save-TcStatus -Tab $script:Second -Action 1 -Status 'doing'
        Wait-TcStore -Tab $script:Browser -Count 1 | Should -Be 1
        # The first tab reads the file, finds the row and stops waiting: the record stays, the pending key goes.
        Invoke-Js 'takeOtherTabs(); P.pending = box(); persist(); 1' | Out-Null
        Invoke-Second 'new Promise(ok => { const end = Date.now() + 5000; (function f() { if (!Object.keys(P.pending).length || Date.now() > end) ok(Object.keys(P.pending).length); else setTimeout(f, 10); })(); })' | Should -Be 0
    }

    It 'keeps a value the other tab has only in an older form' {
        Save-TcStatus -Tab $script:Second -Action 1 -Status 'doing'
        Wait-TcStore -Tab $script:Browser -Count 1 | Should -Be 1
        Start-Sleep -Milliseconds 20
        Save-TcStatus -Tab $script:Second -Action 1 -Status 'blocked'
        # A write that holds the older value of the field, as a tab that missed the second save would leave it.
        Invoke-Js "new Promise(ok => { const end = Date.now() + 5000; (function f() { if ((readJson(KEY).actions[D.actions[1].id] || {}).status === 'blocked' || Date.now() > end) ok(1); else setTimeout(f, 10); })(); })" | Out-Null
        Invoke-Js "const s = readJson(KEY), r = s.actions[D.actions[1].id]; r.status = 'doing'; r.t.status.at = '2026-01-15T09:00:00.000Z'; localStorage.setItem(KEY, JSON.stringify(s)); 1" | Out-Null
        Invoke-Js "new Promise(ok => { const end = Date.now() + 5000; (function f() { const v = (readJson(KEY).actions[D.actions[1].id] || {}).status; if (v === 'blocked' || Date.now() > end) ok(v); else setTimeout(f, 10); })(); })" | Should -Be 'blocked'
    }

    It 'keeps a note, an answer, an assignee and a tick from the other tab' {
        Invoke-Second @'
const a = D.actions[0], r = record('a', a.id); (r.notes = r.notes || box())['Pat Example'] = { text: 'From the other tab', at: new Date().toISOString() }; P.pending[`a|${a.id}|note|Pat Example`] = {};
write(record('a', a.id), 'assignee', 'Sam Example');
write(record('d', 'D-ONE'), 'answer', 'An answer');
P.config['S1|A setting'] = { val: 1, ...stamp(), prev: '' }; P.pending['c|S1|A setting'] = {}; keep(); clearTimeout(LINK.timer); 1
'@ | Out-Null
        Save-TcStatus -Tab $script:Browser -Action 3 -Status 'done'
        Wait-TcStore -Tab $script:Browser -Count 5 | Should -Be 5
        Close-TcBrowserTab -Tab $script:Second; $script:Second = $null
        Open-TcBrowserPage -Browser $script:Browser -Path $script:Reports[2]
        $result = Invoke-Js "const a = P.actions[D.actions[0].id]; JSON.stringify({ note: a.notes['Pat Example'].text, assignee: a.assignee, answer: P.decisions['D-ONE'].answer, tick: applied('S1|A setting') })" | ConvertFrom-Json
        $result.note | Should -Be 'From the other tab'
        $result.assignee | Should -Be 'Sam Example'
        $result.answer | Should -Be 'An answer'
        $result.tick | Should -BeTrue
    }

    It 'keeps the latest value when both tabs change one field' {
        Save-TcStatus -Tab $script:Browser -Action 0 -Status 'done'
        Start-Sleep -Milliseconds 20
        Save-TcStatus -Tab $script:Second -Action 0 -Status 'blocked'
        Save-TcStatus -Tab $script:Browser -Action 2 -Status 'doing'
        Wait-TcStore -Tab $script:Browser -Count 2 | Should -Be 2
        Invoke-Js "new Promise(ok => { const end = Date.now() + 5000; (function f() { const v = statusOf(D.actions[0].id); if (v === 'blocked' || Date.now() > end) ok(v); else setTimeout(f, 10); })(); })" | Should -Be 'blocked'
        Invoke-Js "new Promise(ok => { const end = Date.now() + 5000; (function f() { const v = readJson(KEY).actions[D.actions[0].id].status; if (v === 'blocked' || Date.now() > end) ok(v); else setTimeout(f, 10); })(); })" | Should -Be 'blocked'
    }

    It 'shows a tab what the other one did, with nothing to do' {
        Invoke-Js "go('S1', 'plan'); route(); 1" | Out-Null
        Save-TcStatus -Tab $script:Second -Action 1 -Status 'done'
        Invoke-Js "new Promise(ok => { const end = Date.now() + 5000; (function f() { const v = statusOf(D.actions[1].id); if (v === 'done' || Date.now() > end) ok(v); else setTimeout(f, 10); })(); })" | Should -Be 'done'
    }
}

Describe 'The link to the file, with a stand-in for the file' -Skip:(-not $script:Available) {
    # A browser test cannot answer the file picker, so a stand-in takes the place of the handle it returns.
    BeforeAll {
        $script:Head = 'Type,Id,Label,Field,Value,Author,Date,Replaces\r\n'
        $script:Standin = @'
window.fakeFile = { text: FIRST, modified: 1, writes: 0, busy: false };
LINK.h = {
  name: 'team-tracking.csv',
  getFile: async () => ({ lastModified: fakeFile.modified, arrayBuffer: async () => new TextEncoder().encode(fakeFile.text).buffer }),
  createWritable: async () => { if (fakeFile.busy) throw new Error('locked'); return { write: async t => { fakeFile.text = t; }, close: async () => { fakeFile.writes++; fakeFile.modified++; } }; }
};
P.pending = box(); chooseMe('Pat Example'); linkState('linked'); LINK.dirty = true;
'@
    }

    BeforeEach {
        Set-TcBrowserSize -Browser $script:Browser
        Open-TcReport -Path $script:Reports[2]
        Invoke-Js ($script:Standin.Replace('FIRST', "'$script:Head'") + 'sync()') | Out-Null
    }

    It 'writes a change to the file' {
        $text = Invoke-Js "const a = D.actions[0]; write(record('a', a.id), 'status', 'done'); clearTimeout(LINK.timer); LINK.dirty = true; sync().then(() => fakeFile.text)"
        $text[0] | Should -Be ([char]0xFEFF)
        $text | Should -Match ',status,Done,Pat Example,'
        Invoke-Js 'LINK.state' | Should -Be 'linked'
    }

    It 'does not rewrite the file when nothing waits' {
        Invoke-Js 'fakeFile.modified++; LINK.dirty = true; sync().then(() => fakeFile.writes)' | Should -Be 0
    }

    It 'says the file is busy, keeps the update, and writes it once the file is free' {
        $state = Invoke-Js "fakeFile.busy = true; const a = D.actions[1]; write(record('a', a.id), 'status', 'doing'); clearTimeout(LINK.timer); LINK.dirty = true; sync().then(() => LINK.state)"
        $state | Should -Be 'busy'
        Invoke-Js 'statusOf(D.actions[1].id)' | Should -Be 'doing'
        Invoke-Js 'fakeFile.busy = false; LINK.dirty = true; sync().then(() => fakeFile.text)' | Should -Match ',status,In progress,Pat Example,'
    }

    It 'leaves a damaged file alone, and says so' {
        $result = Invoke-Js "fakeFile.text = 'not the header\r\n1,2\r\n'; fakeFile.modified++; const a = D.actions[2]; write(record('a', a.id), 'status', 'done'); clearTimeout(LINK.timer); LINK.dirty = true; sync().then(() => JSON.stringify({ state: LINK.state, text: fakeFile.text, writes: fakeFile.writes }))" | ConvertFrom-Json
        $result.state | Should -Be 'unreadable'
        $result.text | Should -Be "not the header`r`n1,2`r`n"
        $result.writes | Should -Be 0
    }

    It 'follows a row a colleague changed in the file' {
        Invoke-Js "const id = D.actions[3].id; fakeFile.text = '$script:Head' + 'action,' + id + ',T,status,Blocked,Sam,2026-01-15T09:00:00.000Z,\r\n'; fakeFile.modified++; sync().then(() => statusOf(id))" | Should -Be 'blocked'
    }

    It 'keeps an orphan row in the file when it writes' {
        $text = Invoke-Js "const a = D.actions[4]; fakeFile.text = '$script:Head' + 'task,OLD-01.S3,A task that left,status,Done,Sam,2026-01-15T09:00:00.000Z,\r\n'; fakeFile.modified++; sync().then(() => { write(record('a', a.id), 'status', 'done'); clearTimeout(LINK.timer); LINK.dirty = true; return sync(); }).then(() => fakeFile.text)"
        $text | Should -Match 'task,OLD-01\.S3,A task that left,status,Done,Sam'
        $text | Should -Match ',status,Done,Pat Example,'
    }

    It 'writes what another tab left, even when nothing changed here' {
        $second = Open-TcBrowserTab -Browser $script:Browser -Path $script:Reports[2]
        try {
            Invoke-TcPageScript -Browser $second -Script "chooseMe('Sam Example'); write(record('a', D.actions[1].id), 'status', 'doing'); clearTimeout(LINK.timer); 1" | Out-Null
        }
        finally { Close-TcBrowserTab -Tab $second }
        Invoke-Js 'sync().then(() => fakeFile.text)' | Should -Match ',status,In progress,Sam Example,'
    }

    It 'lets a row removed by hand leave, whatever the store still held' {
        $id = Invoke-Js "const a = D.actions[8]; write(record('a', a.id), 'status', 'done'); clearTimeout(LINK.timer); LINK.dirty = true; sync().then(() => a.id)"
        # The page reads the file again to confirm the write, and only then stops waiting.
        Invoke-Js "fakeFile.modified++; LINK.dirty = true; sync().then(() => Object.keys(P.pending).length)" | Should -Be 0
        Invoke-Js "fakeFile.text = fakeFile.text.split('\r\n').filter(l => !l.includes('$id')).join('\r\n'); fakeFile.modified++; sync().then(() => statusOf('$id'))" | Should -Be 'todo'
        Invoke-Js "const a = D.actions[9]; write(record('a', a.id), 'status', 'done'); clearTimeout(LINK.timer); LINK.dirty = true; sync().then(() => fakeFile.text)" | Should -Not -Match ([regex]::Escape($id))
    }

    Context 'A row the page does not recognise' {
        BeforeAll {
            function Set-TcFakeFile {
                <# Puts rows in the stand-in as a person would, and lets the page read them. A row may name the id of action N as {N}. #>
                param([string[]]$Row, [string]$Header = 'Type,Id,Label,Field,Value,Author,Date,Replaces')
                $json = ConvertTo-Json -InputObject (@($Header) + $Row) -Compress
                Invoke-Js "fakeFile.text = '﻿' + $json.map(l => l.replace(/\{(\d+)\}/g, (x, n) => D.actions[n].id)).join('\r\n') + '\r\n'; fakeFile.modified++; sync().then(() => 1)" | Out-Null
            }

            function Save-TcOtherChange {
                <# Records a change somewhere else, so the page writes the whole file again. #>
                param([int]$Action = 20, [string]$Status = 'done')
                Invoke-Js "const a = D.actions[$Action]; write(record('a', a.id), 'status', '$Status'); clearTimeout(LINK.timer); LINK.dirty = true; sync().then(() => fakeFile.text)"
            }

            $script:When = '2026-01-15T09:00:00.000Z'
        }

        It 'keeps it verbatim at each write' {
            $row = "action,{5},Some title,status,Finished,Sam,$script:When,"
            Set-TcFakeFile -Row $row
            $verbatim = Invoke-Js "'action,' + D.actions[5].id + ',Some title,status,Finished,Sam,$script:When,'"
            (Save-TcOtherChange -Action 20).Split("`r`n") | Should -Contain $verbatim
            (Save-TcOtherChange -Action 21).Split("`r`n") | Should -Contain $verbatim
            (Save-TcOtherChange -Action 22).Split("`r`n") | Should -Contain $verbatim
        }

        It 'counts it for nothing in the report' {
            Set-TcFakeFile -Row "action,{5},Some title,status,Finished,Sam,$script:When,"
            Invoke-Js 'statusOf(D.actions[5].id)' | Should -Be 'todo'
            Invoke-Js 'orphans().length' | Should -Be 0
        }

        It 'is never counted as a removal' {
            Set-TcFakeFile -Row "action,{6},Some title,status,Done,Sam,$script:When,"
            Invoke-Js 'statusOf(D.actions[6].id)' | Should -Be 'done'
            Set-TcFakeFile -Row "action,{6},Some title,status,Finished,Sam,$script:When,"
            $result = Invoke-Js "JSON.stringify({ toast: document.getElementById('toast').textContent, copy: !!readJson(KEY_COPY), rows: countRows() })" | ConvertFrom-Json
            $result.toast | Should -Not -Match 'removed'
            $result.toast | Should -Match '1 row not recognised'
            $result.copy | Should -BeFalse
            $result.rows | Should -Be 1
        }

        It 'shows it to the team as unrecognised, and says why' {
            Set-TcFakeFile -Row "action,{5},Some title,status,Finished,Sam,$script:When,"
            $text = Invoke-Js "go('steering', 'team'); route(); document.querySelector('.unrecognised').innerText"
            $text | Should -Match 'Finished'
            $text | Should -Match 'Sam'
            $text | Should -Match 'Not a status the report knows'
            Invoke-Js "document.querySelector('#page').innerText" | Should -Match 'does not recognise'
        }

        It 'shows no such section when every row is read' {
            Set-TcFakeFile -Row "action,{5},Some title,status,Done,Sam,$script:When,"
            Invoke-Js "go('steering', 'team'); route(); document.querySelectorAll('.unrecognised').length" | Should -Be 0
        }

        It 'stays when a person restores the state of the page from storage' {
            Set-TcFakeFile -Row "action,{5},Some title,status,Finished,Sam,$script:When,"
            Invoke-Js 'JSON.stringify(loadState().unknown[0].cells[4])' | Should -Be '"Finished"'
        }

        It 'leaves when a person deletes it, with a way back' {
            Set-TcFakeFile -Row "action,{5},Some title,status,Finished,Sam,$script:When,"
            Set-TcFakeFile -Row @()
            $result = Invoke-Js "JSON.stringify({ left: P.unknown.length, toast: document.getElementById('toast').textContent, copy: (readJson(KEY_COPY) || {}).text })" | ConvertFrom-Json
            $result.left | Should -Be 0
            $result.toast | Should -Match '1 row removed'
            $result.copy | Should -Match 'Finished'
        }

        It 'reads a field whatever its case: <Field>' -ForEach @(
            @{ Field = 'Status'; Value = 'Done'; Check = 'statusOf(D.actions[7].id)'; Expected = 'done' }
            @{ Field = 'STATUS'; Value = 'Blocked'; Check = 'statusOf(D.actions[7].id)'; Expected = 'blocked' }
            @{ Field = 'Assignee'; Value = 'Sam'; Check = 'P.actions[D.actions[7].id].assignee'; Expected = 'Sam' }
            @{ Field = 'Note'; Value = 'A remark'; Check = 'P.actions[D.actions[7].id].notes.Sam.text'; Expected = 'A remark' }
        ) {
            Set-TcFakeFile -Row "action,{7},Some title,$Field,$Value,Sam,$script:When,"
            Invoke-Js $Check | Should -Be $Expected
            Invoke-Js 'P.unknown.length' | Should -Be 0
        }

        It 'reads a status and a type whatever their case' {
            Set-TcFakeFile -Row "Action,{7},Some title,status,in progress,Sam,$script:When,"
            Invoke-Js 'statusOf(D.actions[7].id)' | Should -Be 'doing'
            Invoke-Js 'P.unknown.length' | Should -Be 0
        }

        It 'reads column names whatever their case' {
            Set-TcFakeFile -Header 'type,id,label,field,value,author,date,replaces' -Row "action,{7},Some title,status,Done,Sam,$script:When,"
            Invoke-Js 'statusOf(D.actions[7].id)' | Should -Be 'done'
            Invoke-Js 'LINK.state' | Should -Be 'linked'
        }

        It 'reads yes and no on a configuration, and takes nothing else for a no' {
            Set-TcFakeFile -Row "configuration,S1|First,,applied,yes,Sam,$script:When,", "configuration,S1|Second,,applied,NO,Sam,$script:When,", "configuration,S1|Third,,applied,maybe,Sam,$script:When,", "configuration,S1|Fourth,,comment,Yes,Sam,$script:When,"
            Invoke-Js "applied('S1|First')" | Should -BeTrue
            Invoke-Js "applied('S1|Second')" | Should -BeFalse
            Invoke-Js "JSON.stringify(Object.keys(P.config).sort())" | Should -Be '["S1|First","S1|Second"]'
            Invoke-Js 'JSON.stringify(P.unknown.map(x => x.why))' | Should -Be '["Expected Yes or No","Not a field the report knows"]'
        }

        It 'does not take another field of a decision for its status' {
            Set-TcFakeFile -Row "decision,D-1,A question,status,decided,Sam,$script:When,", "decision,D-1,A question,remark,my remark,Sam,$script:When,"
            Invoke-Js "P.decisions['D-1'].status" | Should -Be 'decided'
            (Save-TcOtherChange) | Should -Match 'decision,D-1,A question,remark,my remark,Sam'
        }

        It 'keeps a status of a decision it does not know, instead of reading it as open' {
            Set-TcFakeFile -Row "decision,D-1,A question,status,Maybe later,Sam,$script:When,"
            Invoke-Js "JSON.stringify(P.decisions['D-1'] || null)" | Should -Be 'null'
            (Save-TcOtherChange) | Should -Match 'decision,D-1,A question,status,Maybe later,Sam'
        }

        It 'keeps a line with text in one cell only, and drops an empty line' {
            Set-TcFakeFile -Row 'Call Sam about the phone numbers', ',,,,,,,', ''
            Invoke-Js 'JSON.stringify(P.unknown.map(x => x.cells[0]))' | Should -Be '["Call Sam about the phone numbers"]'
            (Save-TcOtherChange) | Should -Match 'Call Sam about the phone numbers'
        }

        It 'keeps a column a person added, and the rows that use it' {
            $header = 'Type,Id,Label,Field,Value,Author,Date,Replaces,Comment'
            Set-TcFakeFile -Header $header -Row "action,{5},Some title,status,Done,Sam,$script:When,,Ask Pat", "action,{6},Other title,status,Done,Sam,$script:When,,"
            Invoke-Js 'statusOf(D.actions[6].id)' | Should -Be 'done'
            Invoke-Js 'P.unknown[0].why' | Should -Be 'Text in a column the report does not know: Comment'
            $text = Save-TcOtherChange
            ($text.TrimStart([char]0xFEFF) -split "`r`n")[0] | Should -Be $header
            $text | Should -Match ',status,Done,Sam,2026-01-15T09:00:00\.000Z,,Ask Pat'
        }

        It 'keeps text past the last column' {
            Set-TcFakeFile -Row "action,{5},Some title,status,Done,Sam,$script:When,,,Ask Pat"
            Invoke-Js 'P.unknown[0].why' | Should -Be 'Text in a column the report does not know: no name'
            (Save-TcOtherChange) | Should -Match ',Ask Pat'
        }

        It 'keeps the columns in their place when a person moved them' {
            Set-TcFakeFile -Header 'Id,Type,Value,Field,Label,Author,Date,Replaces' -Row "{5},action,Finished,status,Some title,Sam,$script:When,"
            Invoke-Js 'P.unknown[0].cells[0]' | Should -Be 'action'
            $line = Invoke-Js "'action,' + D.actions[5].id + ',Some title,status,Finished,Sam,$script:When,'"
            (Save-TcOtherChange).Split("`r`n") | Should -Contain $line
        }

        It 'keeps a row with a name the page refuses, as text' {
            Set-TcFakeFile -Row "action,__proto__,x,status,Done,Pat,$script:When,", "action,{5},x,note,hello,__proto__,$script:When,"
            Invoke-Js 'P.unknown.length' | Should -Be 2
            $text = Save-TcOtherChange
            $text | Should -Match 'action,__proto__,x,status,Done,Pat'
            $text | Should -Match ',x,note,hello,__proto__,'
            Invoke-Js '({}).status === undefined' | Should -BeTrue
        }

        It 'guards a kept formula once, and only once' {
            Set-TcFakeFile -Row "action,{5},=cmd|calc,status,=1+1,Sam,$script:When,"
            $first = Save-TcOtherChange -Action 20
            $first | Should -Match ",'=cmd\|calc,status,'=1\+1,Sam,"
            (Save-TcOtherChange -Action 21) | Should -Match ",'=cmd\|calc,status,'=1\+1,Sam,"
        }

        Context 'two rows that give one field a value' {
            BeforeAll {
                function Set-TcTwoRows { Set-TcFakeFile -Row "action,{5},T,status,Done,Pat,$script:When,", "action,{5},T,status,Blocked,Sam,2026-01-15T08:00:00.000Z," }
            }

            It 'keeps the last row, as it always did' {
                Set-TcTwoRows
                Invoke-Js 'statusOf(D.actions[5].id)' | Should -Be 'blocked'
            }

            It 'keeps the other row in the file, and says so' {
                Set-TcTwoRows
                Invoke-Js 'P.unknown[0].why' | Should -Be 'A later row gives this field a new value'
                $text = Save-TcOtherChange
                $text | Should -Match ',status,Done,Pat,'
                $text | Should -Match ',status,Blocked,Sam,'
            }

            It 'gives the same answer after each write' {
                Set-TcTwoRows
                foreach ($action in 20, 21, 22) {
                    Save-TcOtherChange -Action $action | Out-Null
                    Invoke-Js 'fakeFile.modified++; LINK.dirty = true; sync().then(() => statusOf(D.actions[5].id))' | Should -Be 'blocked'
                }
            }

            It 'keeps both notes of one person on one item' {
                Set-TcFakeFile -Row "action,{5},T,note,First thought,Sam,$script:When,", "action,{5},T,note,Second thought,Sam,$script:When,"
                $text = Save-TcOtherChange
                $text | Should -Match 'First thought'
                $text | Should -Match 'Second thought'
            }

            It 'gives the field to the other row once a person deletes the last one' {
                Set-TcTwoRows
                Save-TcOtherChange | Out-Null
                $text = (Invoke-Js 'fakeFile.text') -replace '(?m)^.*,status,Blocked,Sam,.*\r?\n', ''
                Invoke-Js "fakeFile.text = $(ConvertTo-Json -InputObject $text); fakeFile.modified++; sync().then(() => statusOf(D.actions[5].id))" | Should -Be 'done'
                Invoke-Js 'P.unknown.length' | Should -Be 0
            }
        }

        It 'stays in the file through a file written with semicolons' {
            Set-TcFakeFile -Header 'Type;Id;Label;Field;Value;Author;Date;Replaces' -Row "action;{5};A label, with a comma;status;Finished;Sam;$script:When;"
            (Save-TcOtherChange) | Should -Match '"A label, with a comma",status,Finished,Sam'
        }

        It 'keeps the replaced date of a note' {
            Set-TcFakeFile -Row "action,{5},T,note,A remark,Sam,$script:When,2026-01-14T09:00:00.000Z"
            (Save-TcOtherChange) | Should -Match ',note,A remark,Sam,2026-01-15T09:00:00\.000Z,2026-01-14T09:00:00\.000Z'
        }

        It 'is left out of an imported file, and says so' {
            $result = Invoke-Js @'
const file = new File(['Type,Id,Label,Field,Value,Author,Date,Replaces\r\naction,X,T,status,Finished,Sam,2026-01-15T09:00:00.000Z,\r\n'], 'other.csv'), input = document.getElementById('file'), list = new DataTransfer(); list.items.add(file); input.files = list.files; input.dispatchEvent(new Event('change'));
new Promise(ok => setTimeout(ok, 200)).then(() => JSON.stringify({ toast: document.getElementById('toast').textContent, kept: P.unknown.length }))
'@ | ConvertFrom-Json
            $result.toast | Should -Match '1 row not recognised'
            $result.kept | Should -Be 0
        }
    }
}

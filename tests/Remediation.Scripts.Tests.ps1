BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Notice = 'UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.'
    Import-Module (Join-Path $Root 'src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RemediationStubs.ps1')
    . (Join-Path $PSScriptRoot 'Support/RemediationBench.ps1')
    . (Join-Path $PSScriptRoot 'Support/RemediationRules.ps1')
    . (Join-Path $PSScriptRoot 'Support/RemediationColumns.ps1')

    $script:Folder = Join-Path $Root 'src/TenantConverge/Remediation'
    $moduleFolder = Join-Path $Root 'src/TenantConverge'
    $script:Manifest = Get-Content -LiteralPath (Join-Path $moduleFolder 'Data/remediations.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    $script:Entries = @($Manifest['remediations'])
    $script:Files = @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter '*.ps1')
    $script:Texts = @{}
    foreach ($file in $Files) { $Texts[$file.BaseName] = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 }
    $script:PrivateFunction = @(Get-ChildItem -LiteralPath (Join-Path $moduleFolder 'Private'), (Join-Path $moduleFolder 'Public') -Recurse -Filter '*.ps1' | ForEach-Object {
            [regex]::Matches((Get-Content -LiteralPath $_.FullName -Raw -Encoding utf8), '(?m)^function ([\w-]+)') | ForEach-Object { $_.Groups[1].Value }
        })
    $script:Rules = @((Get-Content -LiteralPath (Join-Path $moduleFolder 'Data/rules.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)['rules'])
    $script:Procedures = (Get-Content -LiteralPath (Join-Path $moduleFolder 'Data/procedures.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)['procedures']
    $script:Tables = @((Get-Content -LiteralPath (Join-Path $moduleFolder 'Data/tables.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)['tables'])
}

Describe 'Remediation manifest' {
    It 'lists the 111 scripts, one to one with the files' {
        $Entries.Count | Should -Be 111
        @($Entries | ForEach-Object { $_['id'] } | Sort-Object) | Should -Be @($Files | ForEach-Object BaseName | Sort-Object)
        foreach ($entry in $Entries) { Join-Path $Folder $entry['path'] | Should -Exist }
    }

    It 'keeps the natures of the scripts' {
        $counts = @{}
        foreach ($entry in $Entries) { $counts[$entry['nature']]++ }
        $counts['Decision'] | Should -Be 62
        $counts['Partial'] | Should -Be 27
        $counts['Report'] | Should -Be 19
        $counts['Automated'] | Should -Be 3
    }

    It 'has no defect in any entry' {
        @($Entries | ForEach-Object { Get-TcManifestDefect -Entry $_ }) | Should -BeNullOrEmpty
    }

    It 'refuses an entry marked as tested with no evidence' {
        $entry = [ordered]@{}
        foreach ($key in $Entries[0].Keys) { $entry[$key] = $Entries[0][$key] }
        $entry['testedOnRealTenant'] = $true
        $entry['testedEvidence'] = $null
        @(Get-TcManifestDefect -Entry $entry) -join ' ' | Should -Match 'no evidence'
        $entry['testedEvidence'] = 'Run on a test tenant, journal kept.'
        @(Get-TcManifestDefect -Entry $entry) | Should -BeNullOrEmpty
    }

    It 'says that no script ran on a real tenant' {
        @($Entries | Where-Object { $_['testedOnRealTenant'] -or $null -ne $_['testedEvidence'] }) | Should -BeNullOrEmpty
    }

    It 'holds the delegated column of the Graph permissions reference' {
        $delegated = Get-TcDelegatedPermission
        $delegated.Count | Should -BeGreaterThan 500
        $delegated | Should -Contain 'User.Read.All'
        foreach ($application in 'Device.ReadWrite.All', 'Group.Create') { $delegated | Should -Not -Contain $application }
    }

    It 'asks for no Graph permission a delegated sign-in cannot request' {
        $delegated = Get-TcDelegatedPermission
        @($Entries | ForEach-Object { $id = $_['id']; @($_['permissions']) | Where-Object { $_ -cnotin $delegated } | ForEach-Object { "$id`: $_" } }) | Should -BeNullOrEmpty
    }

    It 'gives a Graph permission to each script that reaches Graph' {
        $callers = Get-TcGraphCaller -Folder (Join-Path $Root 'src/TenantConverge/Private/Remediation')
        $callers | Should -Contain 'Test-TcTenantDomain'
        @($Entries | ForEach-Object { Get-TcGraphPermissionBreak -Text $Texts[$_['id']] -Entry $_ -GraphCaller $callers }) | Should -BeNullOrEmpty
    }

    It 'sees a script that reaches Graph with no permission, in its forms' {
        $entry = @{ id = 'X'; permissions = @() }
        $callers = Get-TcGraphCaller -Folder (Join-Path $Root 'src/TenantConverge/Private/Remediation')
        foreach ($text in 'Invoke-TcGraph -Tenant Target -Uri x', 'Add-TcGraphAction -Tenant Target -Method POST -Uri x', 'Test-TcTenantDomain Target x', 'Add-TcBlockAction -Tenant Target -Service Graph -Block { }') {
            Get-TcGraphPermissionBreak -Text $text -Entry $entry -GraphCaller $callers | Should -Match 'no Graph permission'
        }
        Get-TcGraphPermissionBreak -Text 'Invoke-TcServiceCommand -Tenant Target -Service Exo -Command Get-Mailbox' -Entry $entry -GraphCaller $callers | Should -BeNullOrEmpty
    }

    It 'names the role a pass for a Global Administrator needs' {
        @($Entries | Where-Object { $_['id'] -eq 'EMERGENCY-ACCESS' })[0]['roles'] | Should -Contain 'Privileged Authentication Administrator'
    }

    It 'names only rules and procedures that exist' {
        $known = @($Rules | ForEach-Object { $_['id'] }) + @($Procedures.Keys)
        @($Entries | ForEach-Object { $_['ruleIds'] } | Where-Object { $_ -notin $known }) | Should -BeNullOrEmpty
    }

    It 'flags each script whose code removes objects' {
        $removal = '-Method\s+''?DELETE|''(Remove|Clear)-[A-Z]|-Action\s+Remove|action = ''Remove'''
        @($Entries | Where-Object { -not $_['removesObjects'] -and $Texts[$_['id']] -match $removal } | ForEach-Object { $_['id'] }) | Should -BeNullOrEmpty
    }

    It 'gives every script the exact notice as its first line' {
        foreach ($id in $Texts.Keys) { ($Texts[$id] -split "`r?`n")[0] | Should -BeExactly "# $Notice" -Because $id }
    }
}

Describe 'Remediation code rules' {
    It 'keeps every rule in every script' {
        @($Texts.Keys | ForEach-Object { Get-TcScriptRuleBreak -Text $Texts[$_] -Name $_ -ModuleFunction $PrivateFunction }) | Should -BeNullOrEmpty
    }

    It 'resolves every command and every named parameter' {
        @($Texts.Keys | ForEach-Object { Get-TcScriptCommandBreak -Text $Texts[$_] -Name $_ }) | Should -BeNullOrEmpty
    }

    It 'says in each header what its code does' {
        @($Texts.Keys | ForEach-Object { Get-TcScriptHeaderBreak -Text $Texts[$_] -Name $_ }) | Should -BeNullOrEmpty
    }

    It 'writes only to a tenant the action declared, in all 111 scripts' {
        $Texts.Keys.Count | Should -Be 111
        @($Texts.Keys | ForEach-Object { Get-TcScriptTenantBreak -Text $Texts[$_] -Name $_ }) | Should -BeNullOrEmpty
    }

    It 'names the second tenant of INT-AUTOPILOT, and reaches it only that way' {
        $Texts['INT-AUTOPILOT'] | Should -Match '-AlsoWrites \$t\b'
        $Texts['INT-AUTOPILOT'] | Should -Match '-Tenant \$a\.alsoWrites\[0\] -Method DELETE'
    }

    It 'asks the plan for a procedure that exists' {
        $known = @($Rules | ForEach-Object { $_['id'] }) + @($Procedures.Keys)
        $wrong = foreach ($id in $Texts.Keys) {
            foreach ($match in [regex]::Matches($Texts[$id], "(-Procedure|-RuleId) '([^']+)'")) { if ($match.Groups[2].Value -notin $known) { "$id`: $($match.Value)" } }
        }
        @($wrong) | Should -BeNullOrEmpty
    }

    It 'reads tables that exist' {
        $known = @($Tables | ForEach-Object { $_['key'] })
        $wrong = foreach ($id in $Texts.Keys) {
            foreach ($match in [regex]::Matches($Texts[$id], "Get-TcRemediationTable \S+ '([^']+)'")) { if ($match.Groups[1].Value -notin $known) { "$id`: $($match.Groups[1].Value)" } }
        }
        @($wrong) | Should -BeNullOrEmpty
    }

    It 'reads, from a table, only its columns' {
        $columns = @{}
        foreach ($table in $Tables) { $columns[$table['key']] = @($table['columns']) }
        @($Texts.Keys | ForEach-Object { Get-TcScriptColumnBreak -Text $Texts[$_] -Name $_ -Columns $columns }) | Should -BeNullOrEmpty
    }

    It 'sees a column the table does not have, in a loop and in a pipeline' {
        $columns = @{ sites = @('Url') }
        @(Get-TcScriptColumnBreak -Columns $columns -Text 'foreach ($s in Get-TcRemediationTable $t ''sites'') { $s[''Model''] }') -join ' ' | Should -Match 'no column ''Model'''
        @(Get-TcScriptColumnBreak -Columns $columns -Text 'Get-TcRemediationTable $t ''sites'' | Where-Object { $_[''Model''] }') -join ' ' | Should -Match 'no column ''Model'''
        @(Get-TcScriptColumnBreak -Columns $columns -Text '$rows = @(Get-TcRemediationTable $t ''sites''); foreach ($s in $rows) { $s[''Model''] }') -join ' ' | Should -Match 'no column ''Model'''
        @(Get-TcScriptColumnBreak -Columns $columns -Text 'foreach ($s in Get-TcRemediationTable $t ''sites'') { $s[''Url''] }') | Should -BeNullOrEmpty
    }

    It 'reads options that exist' {
        $known = @((& (Get-Module TenantConverge) { Get-TcRemediationDefault }).Keys)
        $wrong = foreach ($id in $Texts.Keys) {
            foreach ($match in [regex]::Matches($Texts[$id], "Get-TcRemediationOption '([^']+)'")) { if ($match.Groups[1].Value -notin $known) { "$id`: $($match.Groups[1].Value)" } }
        }
        @($wrong) | Should -BeNullOrEmpty
    }

    It 'holds none of the protected terms' -Skip:(-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot '../../prive/forbidden-terms.txt'))) {
        $terms = Join-Path $Root '../prive/forbidden-terms.txt'
        & pwsh -NoProfile -File (Join-Path $Root 'tools/Test-TcForbiddenTerm.ps1') -TermsPath $terms -Path $Folder *> $null
        $LASTEXITCODE | Should -Be 0
    }

    It 'takes out what stops Normalize before it reads a name from a tenant' {
        $bare = foreach ($id in $Texts.Keys) {
            foreach ($line in ($Texts[$id] -split "`r?`n")) {
                if ($line -match '\.Normalize\(' -and $line -notmatch '\[\\p\{Cs\}\\p\{Cn\}\]') { "$id`: $($line.Trim())" }
            }
        }
        @($bare) | Should -BeNullOrEmpty
    }

    It 'is written in English' {
        @($Texts.Keys | ForEach-Object { Get-TcScriptFrenchBreak -Text $Texts[$_] -Name $_ }) | Should -BeNullOrEmpty
    }

    It 'sees French in every place it hid' {
        foreach ($text in '$n = "$Prefix-Groupe"', '$c = ''Audit-Entrant'', ''Audit-Sortant''', '$t = "Replace {{DONNEES}}"', ('$h = @''' + "`n{{DONNEES}}`n" + '''@'), '$t = "Groupe: x"') {
            @(Get-TcScriptFrenchBreak -Text $text) | Should -Not -BeNullOrEmpty -Because $text
        }
        Get-TcScriptFrenchBreak -Text '$n = "$Prefix-Group"; $c = ''Audit-Inbound'', ''Audit-Outbound''; $t = "{{DATA}}"' | Should -BeNullOrEmpty
    }

    Context 'A planted defect is seen' {
        It '<Name>' -ForEach @(
            @{ Name = 'a direct sign-in'; Text = 'Connect-MgGraph -Scopes x'; Expected = 'DIRECT Connect-MgGraph' }
            @{ Name = 'a prompt outside the engine'; Text = '$x = Read-Host "y"'; Expected = 'DIRECT Read-Host' }
            @{ Name = 'an exit'; Text = 'exit 1'; Expected = 'EXIT' }
            @{ Name = 'a variable in the module scope'; Text = '$script:Mine = 1'; Expected = 'SCOPE' }
            @{ Name = 'a function of the module redefined'; Text = 'function Get-TcMember { }'; Expected = 'DUPLICATE' }
            @{ Name = 'a comma that splits a method call'; Text = '[uri]::EscapeDataString($x -replace ''a'', ''b'')'; Expected = 'COMMA' }
            @{ Name = 'an engine variable assigned'; Text = '$tcRun = 1'; Expected = 'RESERVED' }
            @{ Name = 'a loop variable read later'; Text = 'foreach ($d in $l) { Add-TcManualAction -Tenant T -Object $d -Description x -WaitUntil { $d } }'; Expected = 'LOOP' }
            @{ Name = 'a write outside the plan'; Text = 'Invoke-TcGraph -Tenant T -Method POST -Uri x'; Expected = 'WRITE' }
            @{ Name = 'a DNS record built by hand'; Text = 'Add-TcBlockAction -Block { param($a) Invoke-TcDnsAction $a }'; Expected = 'DNSRECORD' }
            @{ Name = 'a path of one computer'; Text = '$f = ''C:\Tools\x'''; Expected = 'PATH' }
            @{ Name = 'a certificate subject'; Text = '$s = ''CN=Someone'''; Expected = 'PATH' }
        ) {
            @(Get-TcScriptRuleBreak -Text $Text -ModuleFunction $PrivateFunction) -join ' ' | Should -Match $Expected
        }

        It 'a header that says <Name>' -ForEach @(
            @{ Name = 'nothing of a decisions file'; Text = "<# Help. #>`nGet-TcDecision -Name 'ONE' -Key k -Choice c" }
            @{ Name = 'that it does not wait'; Text = "<# Created without waiting for a decision. #>`n`$c = 1" }
            @{ Name = 'that a policy is created everywhere'; Text = "<# The policy is created in report-only in each tenant of the plan. #>`n`$c = 1" }
            @{ Name = 'secrets while the code writes elsewhere'; Text = "<# In secrets. #>`n`$d = Join-Path `$f 'SecretItems'" }
            @{ Name = 'application mode where a person signs in'; Text = "<# Limits: in application mode, Graph can only disable. #>`n`$c = 1" }
        ) {
            @(Get-TcScriptHeaderBreak -Text $Text) -join ' ' | Should -Match 'HEADER'
        }

        It 'a header that names its file is no break' {
            Get-TcScriptHeaderBreak -Text "<# Decision: decisions\ONE.csv. #>`nGet-TcDecision -Name 'ONE' -Key k -Choice c" | Should -BeNullOrEmpty
        }

        It 'a block that writes to <Name>' -ForEach @(
            @{ Name = 'a tenant it read from its data'; Text = 'Add-TcBlockAction -Tenant ''Target'' -Service Graph -Object x -Description x -Data @{ Source = $t } -Block { param($a) Invoke-TcGraph -Tenant $a.data.Source -Method DELETE -Uri x }' }
            @{ Name = 'a literal role'; Text = 'Add-TcBlockAction -Tenant ''Target'' -Service Graph -Object x -Description x -Block { param($a) Invoke-TcGraph -Tenant ''S1'' -Method POST -Uri x }' }
            @{ Name = 'a loop variable'; Text = 'Add-TcBlockAction -Tenant $t -Service Graph -Object x -Description x -Block { param($a) Invoke-TcGraph -Tenant $t -Method POST -Uri x }' }
            @{ Name = 'a tenant through a command'; Text = 'Add-TcBlockAction -Tenant ''Target'' -Service Exo -Object x -Description x -Block { param($a) Invoke-TcServiceCommand -Tenant $s -Service Exo -Command ''Set-Mailbox'' }' }
            @{ Name = 'a tenant through a command held in a variable'; Text = 'Add-TcBlockAction -Tenant ''Target'' -Service Exo -Object x -Description x -Block { param($a) $k = ''Set-Mailbox''; Invoke-TcServiceCommand -Tenant $s -Service Exo -Command $k }' }
            @{ Name = 'a second tenant with no declaration'; Text = 'Add-TcBlockAction -Tenant ''Target'' -Service Graph -Object x -Description x -Block { param($a) Invoke-TcGraph -Tenant $a.alsoWrites[0] -Method POST -Uri x }' }
            @{ Name = 'a tenant through a local function'; Text = 'function Copy-One { Invoke-TcGraph -Tenant ''S1'' -Method POST -Uri x }; Add-TcBlockAction -Tenant ''Target'' -Service Graph -Object x -Description x -Block { param($a) Copy-One }' }
            @{ Name = 'a DNS zone with no tenant'; Text = 'Add-TcBlockAction -Tenant ''Target'' -Service Exo -Object x -Description x -Block { param($a) Invoke-TcDnsAction @{ id = $a.id; dns = @{} } }' }
            @{ Name = 'Cloudflare on another tenant'; Text = 'Add-TcBlockAction -Tenant ''Target'' -Service Graph -Object x -Description x -Block { param($a) Set-TcCloudflareRecord -Tenant ''S1'' -Zone z -Name z -Type TXT -Action Add }' }
            @{ Name = 'a DNS record for another action'; Text = 'Add-TcBlockAction -Tenant ''Target'' -Service Graph -Object x -Description x -Block { param($a) Invoke-TcDnsRecord -Action $b -Zone z -Name z -Type TXT -Value v }' }
        ) {
            @(Get-TcScriptTenantBreak -Text $Text) -join ' ' | Should -Match 'TENANT write'
        }

        It 'a check that writes, a write outside any action' {
            @(Get-TcScriptTenantBreak -Text 'Invoke-TcRemediationPlan -Verify { param($t) Invoke-TcGraph -Tenant $t -Method POST -Uri x }') -join ' ' | Should -Match 'TENANT write in a check'
            @(Get-TcScriptTenantBreak -Text 'function Set-One { Invoke-TcGraph -Tenant ''Target'' -Method POST -Uri x }; Set-One') -join ' ' | Should -Match 'TENANT write through Set-One outside an action'
        }

        It 'a read, and a write the action declared, are not breaks' {
            Get-TcScriptTenantBreak -Text 'Add-TcBlockAction -Tenant ''Target'' -Service Graph -Object x -Description x -Block { param($a) Invoke-TcGraph -Tenant ''S1'' -Uri x }' | Should -BeNullOrEmpty
            Get-TcScriptTenantBreak -Text 'Add-TcBlockAction -Tenant ''Target'' -Service Pnp -Object x -Description x -Block { param($a) Invoke-TcServiceCommand -Tenant $a.data.Source -Service Pnp -Command ''Export-PnPTermGroupToXml'' }' | Should -BeNullOrEmpty
            Get-TcScriptTenantBreak -Text 'Add-TcBlockAction -Tenant ''Target'' -AlsoWrites $t -Service Graph -Object x -Description x -Block { param($a) Invoke-TcGraph -Tenant $a.alsoWrites[0] -Method DELETE -Uri x }' | Should -BeNullOrEmpty
            Get-TcScriptTenantBreak -Text 'function Copy-One { Invoke-TcGraph -Tenant ''Target'' -Method POST -Uri x }; Add-TcBlockAction -Tenant ''Target'' -Service Graph -Object x -Description x -Block { param($a) Copy-One }' | Should -BeNullOrEmpty
            Get-TcScriptTenantBreak -Text 'function Test-One { param([string]$Command) Invoke-TcServiceCommand -Tenant ''Target'' -Service Exo -Command $Command }; Invoke-TcRemediationPlan -Verify { Test-One ''Get-Mailbox'' }' | Should -BeNullOrEmpty
        }

        It 'sees an unknown command and an unknown parameter' {
            @(Get-TcScriptCommandBreak -Text 'Get-TcNothing -Any 1') -join ' ' | Should -Match 'UNKNOWN Get-TcNothing'
            @(Get-TcScriptCommandBreak -Text 'Get-TcDecision -Proposals 1') -join ' ' | Should -Match 'PARAMETER Get-TcDecision -Proposals'
        }
    }
}

Describe 'Remediation bench, on offline stubs' {
    BeforeAll {
        function Invoke-TcBenchPass {
            <# Runs every script once. Gives one record per script. #>
            param($Snapshot, $Project, $Plan, [switch]$Apply)
            foreach ($entry in $Entries) {
                Reset-TcStub -AutoConfirm
                $outcome = Invoke-TcRemediation -Id $entry['id'] -Project $Project -Snapshot $Snapshot -Plan $Plan -AcknowledgeUntested -Apply:$Apply -WarningAction SilentlyContinue 6>$null
                [pscustomobject]@{
                    Id = $entry['id']; Nature = $entry['nature']; Outcome = $outcome; Writes = @(Get-TcStubWrite); Connections = @(Get-TcStubRecord -Name 'Connections'); Prompts = @(Get-TcStubRecord -Name 'Prompts')
                    Failures = @(Get-TcBenchFailure -Outcome $outcome)
                }
            }
        }

        function New-TcBenchFixture {
            param([int]$SourceCount, [string]$Name = "$SourceCount")
            $snapshot = & (Join-Path $Root 'tools/New-TcFakeSnapshot.ps1') -SourceCount $SourceCount -Seed 3
            $snapshot['meta']['finished'] = (Get-Date).ToString('o')
            $output = Join-Path $TestDrive "bench-$Name"
            $project = New-TcBenchProject -Snapshot $snapshot -Output $output
            Set-TcBenchLicense -Snapshot $snapshot -Output $output
            @{ Snapshot = $snapshot; Output = $output; Project = $project; Plan = (New-TcPlan -Project $project -Snapshot $snapshot) }
        }

        $two = New-TcBenchFixture -SourceCount 2
        Install-TcRemediationStub -Mode Echo
        $script:ApplyNoFile = @(Invoke-TcBenchPass -Snapshot $two['Snapshot'] -Project $two['Project'] -Plan $two['Plan'] -Apply)
        Install-TcRemediationStub -Mode Empty
        $script:PreviewEmptyReads = @(Invoke-TcBenchPass -Snapshot $two['Snapshot'] -Project $two['Project'] -Plan $two['Plan'])
        Install-TcRemediationStub -Mode Echo
        Set-TcBenchDecision -Output $two['Output']
        $script:PreviewDecided = @(Invoke-TcBenchPass -Snapshot $two['Snapshot'] -Project $two['Project'] -Plan $two['Plan'])
        Set-TcBenchDecision -Output $two['Output']
        $script:ApplyDecided = @(Invoke-TcBenchPass -Snapshot $two['Snapshot'] -Project $two['Project'] -Plan $two['Plan'] -Apply)
        $script:Two = $two

        $script:OtherCounts = @{}
        foreach ($count in 1, 3) {
            $fixture = New-TcBenchFixture -SourceCount $count
            Install-TcRemediationStub -Mode Echo
            $preview = @(Invoke-TcBenchPass -Snapshot $fixture['Snapshot'] -Project $fixture['Project'] -Plan $fixture['Plan'])
            Set-TcBenchDecision -Output $fixture['Output']
            $applied = @(Invoke-TcBenchPass -Snapshot $fixture['Snapshot'] -Project $fixture['Project'] -Plan $fixture['Plan'] -Apply)
            $OtherCounts[$count] = @{ Preview = $preview; Apply = $applied; Fixture = $fixture }
        }

        # The second and the third allowed value of each decision take the branches the proposals leave out.
        $script:OtherChoices = @{}
        foreach ($choice in 1, 2) {
            $fixture = New-TcBenchFixture -SourceCount 2 -Name "choice-$choice"
            Install-TcRemediationStub -Mode Echo
            [void](Invoke-TcBenchPass -Snapshot $fixture['Snapshot'] -Project $fixture['Project'] -Plan $fixture['Plan'])
            Set-TcBenchDecision -Output $fixture['Output'] -Choice $choice
            $OtherChoices[$choice] = @(Invoke-TcBenchPass -Snapshot $fixture['Snapshot'] -Project $fixture['Project'] -Plan $fixture['Plan'] -Apply)
        }
    }

    It 'runs all 111 scripts in each pass' {
        foreach ($pass in $ApplyNoFile, $PreviewEmptyReads, $PreviewDecided, $ApplyDecided) { $pass.Count | Should -Be 111 }
    }

    It 'records no write in a preview, on empty reads' {
        @($PreviewEmptyReads | Where-Object { $_.Writes.Count } | ForEach-Object Id) | Should -BeNullOrEmpty
    }

    It 'records no write in a preview, with every decision taken' {
        @($PreviewDecided | Where-Object { $_.Writes.Count } | ForEach-Object Id) | Should -BeNullOrEmpty
    }

    It 'neither signs in nor asks anything in a preview' {
        @($PreviewDecided + $PreviewEmptyReads | Where-Object { $_.Connections.Count -or $_.Prompts.Count } | ForEach-Object Id) | Should -BeNullOrEmpty
    }

    It 'says in the documentation how many scripts reached a write' {
        $passes = $ApplyNoFile + $ApplyDecided + $OtherCounts[1]['Apply'] + $OtherCounts[3]['Apply'] + $OtherChoices[1] + $OtherChoices[2]
        $reached = @($passes | Where-Object { $_.Writes.Count } | ForEach-Object Id | Sort-Object -Unique)
        Get-Content (Join-Path $Root 'docs/remediations.md') -Raw -Encoding utf8 | Should -Match ('{0} in the runs over all scripts' -f $reached.Count)
    }

    It 'changes nothing from a decision that nobody took' {
        @($ApplyNoFile | Where-Object { ($_.Nature -eq 'Decision' -or $Texts[$_.Id] -match 'Get-TcDecision|Read-TcDecisionRow') -and $_.Writes.Count } | ForEach-Object Id) | Should -BeNullOrEmpty
    }

    It '<Id> waits for a decision: it plans no write without one' -ForEach @(
        @{ Id = 'CMP-CROSS-TENANT' }, @{ Id = 'ENT-AUTHORIZATION' }, @{ Id = 'EXO-LARGE-MAILBOXES' }, @{ Id = 'EMERGENCY-ACCESS' }, @{ Id = 'EXO-DKIM' }
    ) {
        $run = @($ApplyNoFile | Where-Object Id -EQ $Id)[0]
        $run.Nature | Should -Be 'Decision'
        $Texts[$Id] | Should -Match 'Get-TcDecision'
        $planned = @(Get-Content -LiteralPath (Join-Path $run.Outcome.Folder 'plan.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)
        @($planned | Where-Object { $_ -and $_['type'] -ne 'Manual' -and $_['object'] -ne 'Measure' } | ForEach-Object { $_['description'] }) | Should -BeNullOrEmpty
    }

    It '<Id> plans its writes once a person decided' -ForEach @(
        @{ Id = 'CMP-CROSS-TENANT' }, @{ Id = 'ENT-AUTHORIZATION' }, @{ Id = 'EMERGENCY-ACCESS' }, @{ Id = 'EXO-DKIM' }
    ) {
        $run = @($ApplyDecided | Where-Object Id -EQ $Id)[0]
        $planned = @(Get-Content -LiteralPath (Join-Path $run.Outcome.Folder 'plan.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)
        @($planned | Where-Object { $_ -and $_['type'] -ne 'Manual' }).Count | Should -BeGreaterThan 0
    }

    It 'sends no row back to pending once nothing changes, in all 111 scripts' {
        # The pass before this one may: a row can show the decision of another file, which the bench had just filled.
        @($ApplyDecided | Where-Object { (Get-Content -LiteralPath (Join-Path $_.Outcome.Folder 'journal.log') -Raw -Encoding utf8) -match 'goes back to pending' } | ForEach-Object Id | Select-Object -Unique) | Should -BeNullOrEmpty
    }

    It 'says so when decisions are pending' {
        $open = @($ApplyNoFile | Where-Object { $_.Nature -eq 'Decision' -and (Test-Path -LiteralPath (Join-Path $Two['Output'] "decisions/$($_.Id).csv")) -and @(Import-Csv -LiteralPath (Join-Path $Two['Output'] "decisions/$($_.Id).csv") -Encoding utf8BOM).Count })
        $open.Count | Should -BeGreaterThan 20
        @($open | Where-Object { -not $_.Outcome.PendingDecisions -and -not $_.Outcome.Alerts } | ForEach-Object Id) | Should -BeNullOrEmpty
    }

    It 'stops on no code error, preview or apply, with two sources' {
        @($ApplyNoFile + $PreviewEmptyReads + $PreviewDecided + $ApplyDecided | ForEach-Object { foreach ($failure in $_.Failures) { "$($_.Id): $failure" } }) | Should -BeNullOrEmpty
    }

    It 'stops on no code error with one source and with three' {
        @(foreach ($count in 1, 3) { $OtherCounts[$count]['Preview'] + $OtherCounts[$count]['Apply'] | ForEach-Object { foreach ($failure in $_.Failures) { "$count sources, $($_.Id): $failure" } } }) | Should -BeNullOrEmpty
    }

    It 'stops on no code error with the other allowed decisions' {
        @(foreach ($choice in 1, 2) { $OtherChoices[$choice] | ForEach-Object { foreach ($failure in $_.Failures) { "choice $choice, $($_.Id): $failure" } } }) | Should -BeNullOrEmpty
    }

    It 'turns the items of the plan into rows of the decisions file' {
        $unread = foreach ($fixture in $Two, $OtherCounts[3]['Fixture']) {
            foreach ($entry in $Entries) {
                if ($Texts[$entry['id']] -notmatch "items" -or $Texts[$entry['id']] -notmatch 'Get-TcDecision') { continue }
                $served = @($fixture['Plan']['actions'] | Where-Object { ($_['ruleId'] -in $entry['ruleIds'] -or $_['procedure'] -in $entry['ruleIds']) -and @($_['items']).Count })
                if (-not $served.Count) { continue }
                $file = Join-Path $fixture['Output'] "decisions/$($entry['id']).csv"
                if (-not (Test-Path -LiteralPath $file) -or -not @(Import-Csv -LiteralPath $file -Encoding utf8BOM).Count) { $entry['id'] }
            }
        }
        @($unread) | Should -BeNullOrEmpty
    }

    It 'gets a good share of the scripts to act when decisions are taken' {
        @($ApplyDecided | Where-Object { $_.Outcome.Actions }).Count | Should -BeGreaterThan 50
        @($ApplyDecided | Where-Object { $_.Writes.Count }).Count | Should -BeGreaterThan 15
    }

    Context 'The confirmations, on every script that would write' {
        BeforeAll {
            Install-TcRemediationStub -Mode Echo
            $script:Writing = @($ApplyDecided | Where-Object { $_.Writes.Count })
            function Invoke-TcBenchRefusal {
                param([string]$Id)
                $outcome = Invoke-TcRemediation -Id $Id -Project $Two['Project'] -Snapshot $Two['Snapshot'] -Plan $Two['Plan'] -AcknowledgeUntested -Apply -WarningAction SilentlyContinue 6>$null
                [pscustomobject]@{ Id = $Id; Code = $outcome.Code; Writes = @(Get-TcStubWrite).Count; Prompts = @(Get-TcStubRecord -Name 'Prompts') }
            }
        }

        It 'covers scripts that write' {
            $Writing.Count | Should -BeGreaterThan 15
        }

        It 'stops on an empty answer, with nothing written, even with the notice acknowledged' {
            $results = foreach ($run in $Writing) { Reset-TcStub; Invoke-TcBenchRefusal -Id $run.Id }
            @($results | Where-Object { $_.Writes -or $_.Code -ne 3 } | ForEach-Object Id) | Should -BeNullOrEmpty
            @($results | Where-Object { -not @($_.Prompts -match 'primary domain').Count } | ForEach-Object Id) | Should -BeNullOrEmpty
        }

        It 'stops on a wrong domain, with nothing written' {
            $results = foreach ($run in $Writing) { Reset-TcStub -Answer 'wrong.example'; Invoke-TcBenchRefusal -Id $run.Id }
            @($results | Where-Object { $_.Writes -or $_.Code -ne 3 } | ForEach-Object Id) | Should -BeNullOrEmpty
        }

        It 'asks a second time before a removal, and -Apply alone does not bypass it' {
            $removing = @($ApplyDecided | Where-Object { @($_.Prompts -cmatch 'Type REMOVE').Count })
            $removing.Count | Should -BeGreaterThan 3
            $results = foreach ($run in $removing) { Reset-TcStub -AutoConfirm -RemoveAnswer ''; Invoke-TcBenchRefusal -Id $run.Id }
            @($results | Where-Object { $_.Writes -or $_.Code -ne 3 } | ForEach-Object Id) | Should -BeNullOrEmpty
        }
    }

    It 'sees a write a script would make in a preview' {
        $file = Join-Path $TestDrive 'planted.ps1'
        Set-Content -LiteralPath $file -Value "# $Notice`n`$c = Open-TcRemediation`nInvoke-TcGraphTransport -Method POST -Url 'https://example.test/x' -Body @{ a = 1 }`nClose-TcRemediation" -Encoding utf8
        $module = Get-Module TenantConverge
        & $module {
            param($Folder)
            $script:SavedCatalog = $script:TcRemediationCatalog; $script:SavedRoot = $script:TcRemediationRoot
            $entry = [ordered]@{ id = 'PLANTED'; title = 'Planted'; workload = 'Entra ID'; ruleIds = @(); nature = 'Decision'; risk = 'Low'; reversible = $true; permissions = @(); testedOnRealTenant = $false; testedEvidence = $null
                service = 'Graph'; scope = 'Target'; roles = @(); taskIds = @(); removesObjects = $false; path = 'planted.ps1' }
            $script:TcRemediationCatalog = [ordered]@{ PLANTED = $entry }
            $script:TcRemediationRoot = $Folder
        } $TestDrive
        try {
            Reset-TcStub
            [void](Invoke-TcRemediation -Id 'PLANTED' -Project $Two['Project'] -Snapshot $Two['Snapshot'] -Plan $Two['Plan'] -WarningAction SilentlyContinue 6>$null)
            @(Get-TcStubWrite).Count | Should -Be 1
        }
        finally { & $module { $script:TcRemediationCatalog = $script:SavedCatalog; $script:TcRemediationRoot = $script:SavedRoot } }
    }
}

Describe 'A DNS record published from a block' {
    BeforeAll {
        $script:DnsSnapshot = & (Join-Path $Root 'tools/New-TcFakeSnapshot.ps1') -SourceCount 1 -Seed 3
        $DnsSnapshot['meta']['finished'] = (Get-Date).ToString('o')
        Install-TcRemediationStub -Mode Empty
        $script:DnsOutput = Join-Path $TestDrive 'dns-block'
        Set-TcBenchLicense -Snapshot $DnsSnapshot -Output $DnsOutput
        $script:DnsProject = New-TcBenchProject -Snapshot $DnsSnapshot -Output $DnsOutput
        $script:DnsPlan = New-TcPlan -Project $DnsProject -Snapshot $DnsSnapshot
        $script:SignedDomain = @($DnsSnapshot['tenants']['S1']['tables']['domains'] | Where-Object { $_['Domain'] -notmatch 'onmicrosoft' })[0]['Domain']
        $script:TestDomain = 'poc-test.example'

        $script:DkimAnswer = {
            param($Command, $Parameters)
            if ($Command -eq 'Get-AcceptedDomain') { return [pscustomobject]@{ DomainName = $SignedDomain } }
            if ($Command -eq 'Get-DkimSigningConfig') { return [pscustomobject]@{ Domain = $SignedDomain; Name = $SignedDomain; Enabled = $false; Selector1KeySize = 2048; Selector2KeySize = 2048; Selector1CNAME = 'one.selector.example'; Selector2CNAME = 'two.selector.example'; Status = 'Valid' } }
            $null
        }
        $script:PocAnswer = {
            param($Method, $Url)
            if ($Method -eq 'GET' -and $Url -like '*/verificationDnsRecords*') { return @{ value = @(@{ recordType = 'Txt'; text = 'verify-me' }) } }
            $null
        }
        $script:ShowsLater = {
            param($Name, $Type)
            $seconds = & (Get-Module TenantConverge) { $script:TcStub['Seconds'] }
            if ($seconds -lt 60) { return }
            if ($Type -eq 'TXT') { return [pscustomobject]@{ Type = 'TXT'; Strings = @('verify-me'); TTL = 300 } }
            [pscustomobject]@{ Type = 'CNAME'; NameHost = $(if ($Name -like 'selector1*') { 'one.selector.example' } else { 'two.selector.example' }); TTL = 300 }
        }

        function Invoke-TcDnsBlockScript {
            param([string]$Id, [switch]$Apply)
            Invoke-TcRemediation -Id $Id -Project $DnsProject -Snapshot $DnsSnapshot -Plan $DnsPlan -Tenant 'S1' -AcknowledgeUntested -Apply:$Apply -WarningAction SilentlyContinue 6>$null
        }

        Reset-TcStub -CommandAnswer $DkimAnswer
        [void](Invoke-TcDnsBlockScript -Id 'EXO-DKIM')
        [void](Invoke-TcDnsBlockScript -Id 'POC-TEST-DOMAIN')
        Set-TcBenchDecision -Output $DnsOutput
        $file = Join-Path $DnsOutput 'decisions/POC-TEST-DOMAIN.csv'
        $rows = @(Import-Csv -LiteralPath $file -Encoding utf8BOM)
        foreach ($row in $rows) { $row.Decision = 'Use'; $row.Note = $TestDomain }
        $rows | Export-Csv -LiteralPath $file -NoTypeInformation -Encoding utf8BOM
    }

    It 'EXO-DKIM waits for its CNAMEs, then turns signing on' {
        Reset-TcStub -AutoConfirm -CommandAnswer $DkimAnswer -DnsAnswer $ShowsLater
        [void](Invoke-TcDnsBlockScript -Id 'EXO-DKIM' -Apply)
        (& (Get-Module TenantConverge) { $script:TcStub['Seconds'] }) | Should -BeGreaterOrEqual 60
        @(Get-TcStubRecord -Name Commands | Where-Object Command -EQ 'Set-DkimSigningConfig').Count | Should -Be 1
    }

    It 'EXO-DKIM leaves signing off when a CNAME never shows' {
        Reset-TcStub -AutoConfirm -CommandAnswer $DkimAnswer
        $outcome = Invoke-TcDnsBlockScript -Id 'EXO-DKIM' -Apply
        @(Get-TcStubRecord -Name Commands | Where-Object Command -EQ 'Set-DkimSigningConfig') | Should -BeNullOrEmpty
        $outcome.Failed | Should -BeGreaterThan 0
    }

    It 'EXO-DKIM keeps the CNAMEs in the journal, for Undo-TcRemediation' {
        Reset-TcStub -AutoConfirm -CommandAnswer $DkimAnswer -DnsAnswer $ShowsLater
        $outcome = Invoke-TcDnsBlockScript -Id 'EXO-DKIM' -Apply
        $line = @(Get-Content -LiteralPath (Join-Path $outcome.Folder 'operations.jsonl') -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable -Depth 40 } | Where-Object { $_['description'] -like 'Publish the CNAMEs*' -and $_['status'] -eq 'Applied' })[0]
        @(@($line['undo']) | Where-Object { $_['type'] -eq 'Dns' }).Count | Should -BeGreaterThan 0
        @(@($line['undo']) | Where-Object { $_['command'] -eq 'Set-DkimSigningConfig' }).Count | Should -Be 1
    }

    It 'POC-TEST-DOMAIN verifies the domain only once its TXT shows' {
        Reset-TcStub -AutoConfirm -GraphAnswer $PocAnswer -DnsAnswer $ShowsLater
        [void](Invoke-TcDnsBlockScript -Id 'POC-TEST-DOMAIN' -Apply)
        (& (Get-Module TenantConverge) { $script:TcStub['Seconds'] }) | Should -BeGreaterOrEqual 60
        @(Get-TcStubRecord -Name Graph | Where-Object Url -Like "*/domains/$TestDomain/verify").Count | Should -Be 1
    }

    It 'POC-TEST-DOMAIN stops before the verification when the TXT never shows' {
        Reset-TcStub -AutoConfirm -GraphAnswer $PocAnswer
        $outcome = Invoke-TcDnsBlockScript -Id 'POC-TEST-DOMAIN' -Apply
        @(Get-TcStubRecord -Name Graph | Where-Object Url -Like "*/domains/$TestDomain/verify") | Should -BeNullOrEmpty
        $outcome.Failed | Should -Be 1
    }
}

Describe 'EMERGENCY-ACCESS, on a tenant with no key registered' {
    BeforeAll {
        $snapshot = & (Join-Path $Root 'tools/New-TcFakeSnapshot.ps1') -SourceCount 1 -Seed 3
        $snapshot['meta']['finished'] = (Get-Date).ToString('o')
        Install-TcRemediationStub -Mode Empty
        $output = Join-Path $TestDrive 'emergency'
        $project = New-TcBenchProject -Snapshot $snapshot -Output $output
        $plan = New-TcPlan -Project $project -Snapshot $snapshot
        $script:EmergencySnapshot = $snapshot
        $script:EmergencyPlan = $plan

        # An account exists once it was created. Nothing else is in the way, and no FIDO2 method ever shows.
        $answer = {
            param($Method, $Url)
            $decoded = [uri]::UnescapeDataString($Url)
            if ($Method -eq 'POST' -and $decoded -like '*/temporaryAccessPassMethods') { return @{ id = 'pass-1'; temporaryAccessPass = 'Pass-Value-1' } }
            if ($Method -ne 'GET') { return $null }
            if ($decoded -like '*/fido2Methods*') { return @{ value = @() } }
            if ($decoded -like '*/authenticationMethodConfigurations/fido2') { return @{ state = 'enabled'; includeTargets = @(@{ id = 'all_users' }) } }
            if ($decoded -like '*v1.0/groups?*') { return @{ value = @(@{ id = 'group-1'; isAssignableToRole = $true }) } }
            if ($decoded -match "userPrincipalName eq '([^']+)'") {
                $created = & (Get-Module TenantConverge) { @($script:TcStub['Graph'] | Where-Object { $_.Method -eq 'POST' -and $_.Url -like '*/v1.0/users' } | ForEach-Object { $_.Body['userPrincipalName'] }) }
                if ($Matches[1] -in $created) { return @{ value = @(@{ id = "id-$($Matches[1])"; userPrincipalName = $Matches[1]; accountEnabled = $true }) } }
            }
            $null
        }

        Reset-TcStub
        [void](Invoke-TcRemediation -Id 'EMERGENCY-ACCESS' -Project $project -Snapshot $snapshot -Plan $plan -AcknowledgeUntested -WarningAction SilentlyContinue 6>$null)
        Set-TcBenchDecision -Output $output
        $script:EmergencyAnswer = $answer
        Reset-TcStub -AutoConfirm -GraphAnswer $answer
        $script:EmergencyRun = Invoke-TcRemediation -Id 'EMERGENCY-ACCESS' -Project $project -Snapshot $snapshot -Plan $plan -AcknowledgeUntested -Apply -WarningAction SilentlyContinue 6>$null
        $script:EmergencyMessages = @(Get-TcStubRecord -Name Messages)
    }

    It 'keeps the password and the pass of each account apart' {
        $secrets = Join-Path $EmergencyRun.Folder 'secrets'
        $passwords = @(Get-ChildItem -LiteralPath $secrets -Filter 'password-*.xml')
        $passes = @(Get-ChildItem -LiteralPath $secrets -Filter 'temporary-access-pass-*.xml')
        $passwords.Count | Should -Be 2
        $passes.Count | Should -Be 2
        foreach ($file in $passwords) { (Import-Clixml -LiteralPath $file.FullName | ConvertFrom-SecureString -AsPlainText).Length | Should -Be 64 }
        foreach ($file in $passes) { Import-Clixml -LiteralPath $file.FullName | ConvertFrom-SecureString -AsPlainText | Should -Be 'Pass-Value-1' }
    }

    It 'plans nothing when no account is decided' {
        $folder = Join-Path $TestDrive 'emergency-none'
        $none = New-TcBenchProject -Snapshot $EmergencySnapshot -Output $folder
        Reset-TcStub
        [void](Invoke-TcRemediation -Id 'EMERGENCY-ACCESS' -Project $none -Snapshot $EmergencySnapshot -Plan $EmergencyPlan -AcknowledgeUntested -WarningAction SilentlyContinue 6>$null)
        Reset-TcStub -AutoConfirm
        $outcome = Invoke-TcRemediation -Id 'EMERGENCY-ACCESS' -Project $none -Snapshot $EmergencySnapshot -Plan $EmergencyPlan -AcknowledgeUntested -Apply -WarningAction SilentlyContinue 6>$null
        $outcome.Actions | Should -Be 0
        Get-TcStubWrite | Should -BeNullOrEmpty
        Get-TcStubRecord -Name Prompts | Should -BeNullOrEmpty
        (Get-Content -LiteralPath (Join-Path $folder 'decisions/EMERGENCY-ACCESS.csv') -Raw) | Should -Match 'emergency1@'
        (Get-Content -LiteralPath (Join-Path $folder 'decisions/EMERGENCY-ACCESS-POLICIES.csv') -Raw) | Should -Match 'Exclude'
    }

    It 'creates only the accounts decided, and excludes only the policies decided' {
        $folder = Join-Path $TestDrive 'emergency-some'
        $some = New-TcBenchProject -Snapshot $EmergencySnapshot -Output $folder
        Reset-TcStub
        [void](Invoke-TcRemediation -Id 'EMERGENCY-ACCESS' -Project $some -Snapshot $EmergencySnapshot -Plan $EmergencyPlan -AcknowledgeUntested -WarningAction SilentlyContinue 6>$null)
        Set-TcBenchDecision -Output $folder
        $accounts = Join-Path $folder 'decisions/EMERGENCY-ACCESS.csv'
        $rows = @(Import-Csv -LiteralPath $accounts -Encoding utf8BOM)
        $rows[1].Decision = 'Skip'
        $rows | Export-Csv -LiteralPath $accounts -NoTypeInformation -Encoding utf8BOM
        $policies = Join-Path $folder 'decisions/EMERGENCY-ACCESS-POLICIES.csv'
        $names = @(Import-Csv -LiteralPath $policies -Encoding utf8BOM)
        $names.Count | Should -BeGreaterThan 1
        $names[0].Decision = 'Keep'
        $names | Export-Csv -LiteralPath $policies -NoTypeInformation -Encoding utf8BOM
        $kept = $names[0].Policy
        $live = @($names | ForEach-Object { @{ id = "policy-$($_.Policy)"; displayName = $_.Policy; state = 'enabled'; conditions = @{ users = @{ includeUsers = @('All'); excludeUsers = @(); excludeGroups = @() } } } })
        $inner = $EmergencyAnswer
        $answer = {
            param($Method, $Url)
            if ($Method -eq 'GET' -and $Url -like '*/identity/conditionalAccess/policies') { return @{ value = $live } }
            & $inner $Method $Url
        }.GetNewClosure()
        Reset-TcStub -AutoConfirm -GraphAnswer $answer
        [void](Invoke-TcRemediation -Id 'EMERGENCY-ACCESS' -Project $some -Snapshot $EmergencySnapshot -Plan $EmergencyPlan -AcknowledgeUntested -Apply -WarningAction SilentlyContinue 6>$null)
        @(Get-TcStubRecord -Name Graph | Where-Object { $_.Method -eq 'POST' -and $_.Url -like '*/v1.0/users' }).Count | Should -Be 1
        $patched = @(Get-TcStubRecord -Name Graph | Where-Object { $_.Method -eq 'PATCH' -and $_.Url -like '*/conditionalAccess/policies/*' })
        $patched.Count | Should -Be ($names.Count - 1)
        @($patched | Where-Object Url -Like "*policy-$kept") | Should -BeNullOrEmpty
    }

    It 'points the person to a file that exists' {
        $paths = @($EmergencyMessages | Select-String -Pattern "Import-Clixml '([^']+)'" | ForEach-Object { $_.Matches[0].Groups[1].Value } | Select-Object -Unique)
        $paths.Count | Should -Be 2
        foreach ($path in $paths) {
            $path | Should -Exist
            Split-Path -Leaf $path | Should -BeLike 'temporary-access-pass-*'
        }
    }
}

Describe 'The target license' {
    BeforeAll {
        $script:LicenseSnapshot = & (Join-Path $Root 'tools/New-TcFakeSnapshot.ps1') -SourceCount 1 -Seed 3
        $LicenseSnapshot['meta']['finished'] = (Get-Date).ToString('o')
        Install-TcRemediationStub -Mode Empty

        function Invoke-TcLicenseScript {
            param([string]$Id, [string]$Output, [hashtable]$Setting = @{}, [switch]$Apply)
            $project = New-TcBenchProject -Snapshot $LicenseSnapshot -Output $Output
            $plan = New-TcPlan -Project $project -Snapshot $LicenseSnapshot
            Reset-TcStub
            Invoke-TcRemediation -Id $Id -Project $project -Snapshot $LicenseSnapshot -Plan $plan -Setting $Setting -AcknowledgeUntested -Apply:$Apply -WarningAction SilentlyContinue 6>$null
        }
    }

    It '<Id> says what is missing and writes nothing, in a preview with no license setting' -ForEach @(
        @{ Id = 'CMP-LICENSES' }, @{ Id = 'CON-LICENSES' }, @{ Id = 'IDENTITY-MATRIX' }, @{ Id = 'LICENSE-CHECK' }
    ) {
        $output = Join-Path $TestDrive "no-license-$Id"
        $outcome = Invoke-TcLicenseScript -Id $Id -Output $output
        $outcome.Code | Should -Be 2
        $outcome.Error | Should -BeLike '*LicenseSku*'
        (Get-TcStubRecord -Name Messages) -join "`n" | Should -BeLike '*LicenseSku*'
        Get-TcStubWrite | Should -BeNullOrEmpty
        Get-TcStubRecord -Name Connections | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath (Join-Path $output 'decisions') -Recurse -File -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        @(Get-ChildItem -LiteralPath (Join-Path $outcome.Folder 'exports') -Recurse -File -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }

    It '<Id> stops the same way with -Apply, and asks nothing' -ForEach @(
        @{ Id = 'CMP-LICENSES' }, @{ Id = 'CON-LICENSES' }, @{ Id = 'IDENTITY-MATRIX' }, @{ Id = 'LICENSE-CHECK' }
    ) {
        $outcome = Invoke-TcLicenseScript -Id $Id -Output (Join-Path $TestDrive "no-license-apply-$Id") -Apply
        $outcome.Error | Should -BeLike '*LicenseSku*'
        Get-TcStubWrite | Should -BeNullOrEmpty
        Get-TcStubRecord -Name Prompts | Should -BeNullOrEmpty
    }

    It '<Id> goes on once the setting names the license' -ForEach @(
        @{ Id = 'CMP-LICENSES' }, @{ Id = 'CON-LICENSES' }, @{ Id = 'IDENTITY-MATRIX' }, @{ Id = 'LICENSE-CHECK' }
    ) {
        (Invoke-TcLicenseScript -Id $Id -Output (Join-Path $TestDrive "license-$Id") -Setting @{ LicenseSku = 'FICTIONAL_PLAN' }).Error | Should -BeNullOrEmpty
    }

    It 'treats a blank value as no value' {
        (Invoke-TcLicenseScript -Id 'CON-LICENSES' -Output (Join-Path $TestDrive 'blank-license') -Setting @{ LicenseSku = '   ' }).Error | Should -BeLike '*LicenseSku*'
    }

    It 'has no default, under the name Invoke-TcRuleSet uses' {
        $defaults = & (Get-Module TenantConverge) { Get-TcRemediationDefault }
        $defaults['LicenseSku'] | Should -BeNullOrEmpty
        $defaults.ContainsKey('LicenseSku') | Should -BeTrue
        $defaults.ContainsKey('DefaultLicenseSku') | Should -BeFalse
        (Get-Command Invoke-TcRuleSet).Parameters.ContainsKey('LicenseSku') | Should -BeTrue
    }

    It 'names no license SKU in a manifest title, a default or a script' {
        $defaults = & (Get-Module TenantConverge) { Get-TcRemediationDefault }
        @($Entries | Where-Object { $_['title'] -cmatch $TcLicenseSkuPattern } | ForEach-Object { $_['title'] }) | Should -BeNullOrEmpty
        @($defaults.Keys | Where-Object { [string]$defaults[$_] -cmatch $TcLicenseSkuPattern }) | Should -BeNullOrEmpty
        # The Teams Phone part numbers name a product a script looks for in any tenant, not a license a project chose.
        $product = '\b(MCOEV|MCOPSTN\w*|PHONESYSTEM_VIRTUALUSER)\b'
        @($Texts.Keys | Where-Object { ($Texts[$_] -creplace $product, '') -cmatch $TcLicenseSkuPattern }) | Should -BeNullOrEmpty
    }

    It 'recognises a license SKU, and nothing else' {
        foreach ($sku in 'Order the SPE_F1 licenses', 'ENTERPRISEPACK', 'O365_BUSINESS_PREMIUM', 'MCOEV') { $sku | Should -MatchExactly $TcLicenseSkuPattern }
        foreach ($other in 'CF_API_TOKEN', 'Order the target license', 'TenantConverge') { $other | Should -Not -MatchExactly $TcLicenseSkuPattern }
    }
}

Describe 'INT-AUTOPILOT, which writes to two tenants' {
    BeforeAll {
        $snapshot = & (Join-Path $Root 'tools/New-TcFakeSnapshot.ps1') -SourceCount 2 -Seed 3
        $snapshot['meta']['finished'] = (Get-Date).ToString('o')
        Install-TcRemediationStub -Mode Empty
        $script:FenceOutput = Join-Path $TestDrive 'autopilot'
        $script:FenceProject = New-TcBenchProject -Snapshot $snapshot -Output $FenceOutput
        $script:FenceSnapshot = $snapshot
        $script:FencePlan = New-TcPlan -Project $FenceProject -Snapshot $snapshot
        $script:FenceSerial = [string]@($snapshot['tenants']['S1']['tables']['autopilotDevices'])[0]['Serial number']
        $script:TargetDomain = $snapshot['tenants']['Target']['primaryDomain']
        $script:SourceDomain = $snapshot['tenants']['S1']['primaryDomain']

        # The registration exists until the DELETE, on the source only, and the import ends at once.
        $script:FenceAnswer = {
            param($Method, $Url)
            $module = Get-Module TenantConverge
            $current = & $module { $script:TcStub['Current'] }
            $deleted = & $module { @($script:TcStub['Graph'] | Where-Object { $_.Method -eq 'DELETE' -and $_.Tenant -eq 'S1' }).Count }
            if ($Method -eq 'GET' -and $Url -like '*v1.0/deviceManagement/windowsAutopilotDeviceIdentities*') {
                if ($current -eq 'S1' -and -not $deleted) { return @{ value = @(@{ id = 'identity-1'; serialNumber = $FenceSerial; userPrincipalName = 'someone@example.test' }) } }
                return @{ value = @() }
            }
            if ($Method -eq 'POST' -and $Url -like '*importedWindowsAutopilotDeviceIdentities/import') { return @{ value = @(@{ id = 'import-1' }) } }
            if ($Method -eq 'GET' -and $Url -like '*importedWindowsAutopilotDeviceIdentities/import-1') { return @{ state = @{ deviceImportStatus = 'complete' } } }
            $null
        }

        function Invoke-TcFenceScript {
            param([switch]$Apply)
            Invoke-TcRemediation -Id 'INT-AUTOPILOT' -Project $FenceProject -Snapshot $FenceSnapshot -Plan $FencePlan -Tenant 'S1' -AcknowledgeUntested -Apply:$Apply -WarningAction SilentlyContinue 6>$null
        }

        $hashes = Join-Path $FenceOutput 'autopilot/S1'
        New-Item -ItemType Directory -Force -Path $hashes | Out-Null
        [pscustomobject]@{ 'Device Serial Number' = $FenceSerial; 'Windows Product ID' = ''; 'Hardware Hash' = [Convert]::ToBase64String([byte[]]::new(2100)) } | Export-Csv -LiteralPath (Join-Path $hashes 'one.csv') -NoTypeInformation
        Reset-TcStub
        [void](Invoke-TcFenceScript)
        Set-TcBenchDecision -Output $FenceOutput
    }

    It 'stops before the first write on a wrong domain of the source' {
        Reset-TcStub -Answer $TargetDomain, 'wrong.example' -GraphAnswer $FenceAnswer
        $outcome = Invoke-TcFenceScript -Apply
        Get-TcStubWrite | Should -BeNullOrEmpty
        $outcome.Code | Should -Be 3
        (Get-TcStubRecord -Name Prompts) -join "`n" | Should -BeLike '*(S1)*'
    }

    It 'removes the device from the source once both domains are typed, and says so in the journal' {
        Reset-TcStub -Answer $TargetDomain, $SourceDomain, 'REMOVE' -GraphAnswer $FenceAnswer
        $outcome = Invoke-TcFenceScript -Apply
        @(Get-TcStubWrite | Where-Object { $_.Method -eq 'DELETE' -and $_.Tenant -eq 'S1' }).Count | Should -Be 1
        $moved = @(Get-Content -LiteralPath (Join-Path $outcome.Folder 'operations.jsonl') -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable -Depth 40 } | Where-Object { $_['object'] -eq $FenceSerial -and $_['status'] -eq 'Applied' })
        $moved.Count | Should -Be 1
        @($moved[0]['written'] | Sort-Object) | Should -Be @('S1', 'Target')
    }
}

Describe 'Plan items, in the format the rules write' {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')
        $box = { param($Address) @{ 'Primary address' = $Address; UPN = $Address; Alias = 'info'; Name = 'Info'; Type = 'SharedMailbox'; ObjectId = "id-$Address" } }
        $snapshot = New-TcRuleSnapshot -Sources 'S1', 'S2' -Given @{
            Target = @{ mailboxes = @(& $box 'info@summit.example') }
            S1     = @{ mailboxes = @(& $box 'info@alpine.example') }
            S2     = @{ mailboxes = @(& $box 'info@birch.example') }
        }
        $snapshot['meta']['finished'] = (Get-Date).ToString('o')
        Install-TcRemediationStub -Mode Empty
        $script:ItemOutput = Join-Path $TestDrive 'items'
        $script:ItemProject = New-TcBenchProject -Snapshot $snapshot -Output $ItemOutput
        $script:ItemSnapshot = $snapshot
        $script:ItemPlan = New-TcPlan -Project $ItemProject -Snapshot $snapshot

        function Invoke-TcItemScript {
            param([string]$Id)
            Reset-TcStub
            [void](Invoke-TcRemediation -Id $Id -Project $ItemProject -Snapshot $ItemSnapshot -Plan $ItemPlan -WarningAction SilentlyContinue 6>$null)
            $file = Join-Path $ItemOutput "decisions/$Id.csv"
            if (Test-Path -LiteralPath $file) { @(Import-Csv -LiteralPath $file -Encoding utf8BOM) }
        }
    }

    It 'gives the pairs of mailboxes to CMP-SHARED-MAILBOXES' {
        $rows = @(Invoke-TcItemScript -Id 'CMP-SHARED-MAILBOXES')
        @($rows | ForEach-Object 'Source mailbox' | Sort-Object) | Should -Be @('info@alpine.example', 'info@birch.example')
        @($rows | ForEach-Object 'Target mailbox' | Sort-Object -Unique) | Should -Be @('info@summit.example')
    }

    It 'gives the shared names to CON-SHARED-MAILBOXES' {
        @(Invoke-TcItemScript -Id 'CON-SHARED-MAILBOXES').Count | Should -BeGreaterThan 0
    }
}

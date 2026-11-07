BeforeDiscovery {
    $script:DocNames = 'getting-started', 'how-it-works', 'permissions', 'privacy', 'remediations', 'limitations', 'glossary'
}

Describe 'The public documents' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $module = Import-Module (Join-Path $root 'src/TenantConverge/TenantConverge.psd1') -Force -PassThru
        $script:Files = @(
            Get-Item (Join-Path $root 'README.md'), (Join-Path $root 'CONTRIBUTING.md'), (Join-Path $root 'SECURITY.md'), (Join-Path $root 'CHANGELOG.md')
            Get-ChildItem (Join-Path $root 'docs') -Filter '*.md' -ErrorAction SilentlyContinue
        )
        $script:Texts = @{}
        foreach ($file in $Files) { $Texts[$file.FullName] = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 }
        $script:Tools = @(Get-ChildItem (Join-Path $root 'tools') -Filter '*.ps1' | ForEach-Object BaseName)

        function Get-CodeBlock {
            param([string]$Text)
            [regex]::Matches($Text, '(?ms)^```powershell\r?\n(.*?)^```') | ForEach-Object { $_.Groups[1].Value }
        }
    }

    It 'has the page <_>, linked from the README' -ForEach $DocNames {
        Join-Path $root "docs/$_.md" | Should -Exist
        $Texts[(Join-Path $root 'README.md')] | Should -Match "\(docs/$_\.md\)"
    }

    It 'links only to files that exist' {
        $broken = foreach ($file in $Files) {
            foreach ($match in [regex]::Matches($Texts[$file.FullName], '\]\((?!https?://|mailto:|#)([^)#]+)(#[^)]*)?\)')) {
                if (-not (Test-Path -LiteralPath (Join-Path $file.DirectoryName $match.Groups[1].Value))) { "$($file.Name): $($match.Groups[1].Value)" }
            }
        }
        @($broken) | Should -BeNullOrEmpty
    }

    It 'shows only commands and parameters that exist' {
        $wrong = foreach ($file in $Files) {
            foreach ($block in Get-CodeBlock -Text $Texts[$file.FullName]) {
                $tokens = $null; $errors = $null
                $ast = [Management.Automation.Language.Parser]::ParseInput($block, [ref]$tokens, [ref]$errors)
                foreach ($problem in $errors) { "$($file.Name): $($problem.Message): $block" }
                foreach ($call in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
                    $name = $call.GetCommandName()
                    if ($name -notmatch '^[A-Z][a-z]+-Tc|^Start-TenantConverge$') { continue }
                    if ($name -notin $module.ExportedFunctions.Keys) { "$($file.Name): unknown command $name"; continue }
                    $known = (Get-Command $name).Parameters.Keys
                    foreach ($parameter in $call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] }) {
                        if ($parameter.ParameterName -notin $known) { "$($file.Name): $name has no -$($parameter.ParameterName)" }
                    }
                }
            }
        }
        @($wrong) | Should -BeNullOrEmpty
    }

    It 'names only commands of the module in its text' {
        $names = foreach ($file in $Files | Where-Object Name -NE 'CONTRIBUTING.md') { [regex]::Matches($Texts[$file.FullName], '`([A-Z][a-z]+-Tc[A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value } }
        @($names | Sort-Object -Unique | Where-Object { $_ -notin $module.ExportedFunctions.Keys -and $_ -notin $Tools }) | Should -BeNullOrEmpty
    }

    It 'says nothing of how the module was built: <_>' -ForEach @('\blot\s*\d', '\blots\b', '\bruling', '\bbench', '\bold tool', '\bprevious tool') {
        $pattern = $_
        @($Files | Where-Object { $Texts[$_.FullName] -match "(?i)$pattern" } | ForEach-Object Name) | Should -BeNullOrEmpty
    }

    It 'does not say in the help of the access commands that nothing else writes to a tenant' {
        foreach ($command in 'Initialize-TcAccess', 'Remove-TcAccess') {
            $text = (Get-Help $command -Full).description.Text -join ' '
            $text | Should -Match 'Invoke-TcRemediation'
            $text | Should -Not -Match 'only part of TenantConverge|one of the two commands'
        }
    }

    It 'opens the limitations with what has never been run' {
        ((Get-Content (Join-Path $root 'docs/limitations.md') -Encoding utf8 | Where-Object { $_ -and $_ -notmatch '^#' })[0]) | Should -Match 'never run against a real tenant'
    }

    It 'gives the status in the first screen of the README' {
        (Get-Content (Join-Path $root 'README.md') -Encoding utf8 -TotalCount 12) -join ' ' | Should -Match 'never run against a real tenant'
    }

    It 'lists every Graph permission the assessment asks for, and no other' {
        $text = $Texts[(Join-Path $root 'docs/permissions.md')]
        $delegated = @(& $module { Get-TcGraphScope -Kind Assessment })
        $application = @(& $module { Get-TcApplicationPermission })
        foreach ($name in $delegated + $application) { $text | Should -Match ('`{0}`' -f [regex]::Escape($name)) -Because 'the code asks for it' }
        $shown = @([regex]::Matches($text, '`([A-Z][A-Za-z]+(\.[A-Za-z]+)+)`') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $other = 'Exchange.ManageAsApp', 'Sites.FullControl.All', 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'RoleManagement.ReadWrite.Directory', 'AllSites.FullControl', 'TermStore.Read.All', 'ReportSettings.ReadWrite.All', 'Policy.ReadWrite.Authorization', 'Directory.AccessAsUser.All'
        @($shown | Where-Object { $_ -notin $delegated -and $_ -notin $application -and $_ -notin $other }) | Should -BeNullOrEmpty
    }

    It 'gives the natures, the risks and the removals of the manifest' {
        $entries = @((Get-Content (Join-Path $root 'src/TenantConverge/Data/remediations.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)['remediations'])
        $text = $Texts[(Join-Path $root 'docs/remediations.md')]
        foreach ($group in $entries | Group-Object { $_['nature'] }) { $text | Should -Match ('\| {0} \| {1} \|' -f $group.Name, $group.Count) }
        foreach ($group in $entries | Group-Object { $_['risk'] }) { $text | Should -Match ('{0} risk: {1}' -f $group.Name, $group.Count) }
        $text | Should -Match ('{0} scripts can remove objects' -f @($entries | Where-Object { $_['removesObjects'] }).Count)
        $text | Should -Match ('{0} are marked reversible' -f @($entries | Where-Object { $_['reversible'] }).Count)
    }

    It 'counts the scripts that hold a write as the code does' {
        $writers = 'Add-TcGraphAction', 'Add-TcCommandAction', 'Add-TcBlockAction', 'Add-TcDnsAction'
        $holding = @(Get-ChildItem (Join-Path $root 'src/TenantConverge/Remediation') -Recurse -Filter '*.ps1' | Where-Object {
                $tokens = $null; $errors = $null
                $ast = [Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
                $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in $writers }, $true).Count -gt 0
            })
        $Texts[(Join-Path $root 'docs/remediations.md')] | Should -Match ('{0} of the 111 scripts hold' -f $holding.Count)
    }

    It 'names the default DNS server of the code in the privacy page' {
        $server = & $module { (Get-TcRemediationDefault)['DnsServer'] }
        Get-Content (Join-Path $root 'src/TenantConverge/Private/Collect/Initialize-TcCollection.ps1') -Raw | Should -Match ("dnsServer = '{0}'" -f [regex]::Escape($server))
        $Texts[(Join-Path $root 'docs/privacy.md')] | Should -Match ([regex]::Escape($server))
    }
}

Describe 'The diagrams' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Import-Module (Join-Path $root 'src/TenantConverge/TenantConverge.psd1') -Force
        $script:Pictures = @(Get-ChildItem (Join-Path $root 'docs/images') -Filter '*.png')
        $script:Sources = @(Get-ChildItem (Join-Path $root 'docs/images/source') -Filter '*.svg')
        $script:Readme = Get-Content (Join-Path $root 'README.md') -Raw -Encoding utf8
        $script:Guide = Get-Content (Join-Path $root 'docs/how-it-works.md') -Raw -Encoding utf8
        $script:Overview = Get-Content (Join-Path $root 'docs/images/source/overview.svg') -Raw -Encoding utf8
        $script:RunSource = Get-Content (Join-Path $root 'docs/images/source/how-a-run-works.svg') -Raw -Encoding utf8
        $script:GateSource = Get-Content (Join-Path $root 'docs/images/source/remediation-gates.svg') -Raw -Encoding utf8
        $script:Data = Join-Path $root 'src/TenantConverge/Data'
    }

    It 'has one picture for each source, and no other' {
        $Sources.Count | Should -BeGreaterOrEqual 5
        @($Pictures | ForEach-Object BaseName | Sort-Object) | Should -Be @($Sources | ForEach-Object BaseName | Sort-Object)
    }

    It 'keeps each picture small enough for a page' {
        foreach ($picture in $Pictures) { $picture.Length | Should -BeLessThan 1MB -Because $picture.Name }
    }

    It 'renders each picture at twice the size of its source' {
        foreach ($source in $Sources) {
            $text = Get-Content -LiteralPath $source.FullName -Raw -Encoding utf8
            $text -match 'viewBox="0 0 (\d+) (\d+)"' | Should -BeTrue
            $width, $height = [int]$Matches[1], [int]$Matches[2]
            $bytes = [IO.File]::ReadAllBytes((Join-Path $source.Directory.Parent.FullName "$($source.BaseName).png"))
            [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 16)) | Should -Be ($width * 2) -Because $source.Name
            [Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 20)) | Should -Be ($height * 2) -Because $source.Name
        }
    }

    It 'describes each source for a reader who cannot see it' {
        foreach ($source in $Sources) {
            $text = Get-Content -LiteralPath $source.FullName -Raw -Encoding utf8
            $text | Should -Match 'role="img"' -Because $source.Name
            $text | Should -Match 'aria-label="[^"]{80,}"' -Because $source.Name
        }
    }

    It 'shows the overview in the first screen of the README' {
        $Readme.IndexOf('docs/images/overview.png') | Should -BeGreaterThan 0
        $Readme.IndexOf('docs/images/overview.png') | Should -BeLessThan $Readme.IndexOf('## Requirements')
    }

    It 'shows every diagram in the page on how it works' {
        foreach ($picture in $Pictures) { $Guide | Should -Match ([regex]::Escape("images/$($picture.Name)")) }
    }

    It 'describes every picture where a document shows it' {
        $documents = @(Get-Item (Join-Path $PSScriptRoot '../README.md')) + @(Get-ChildItem (Join-Path $PSScriptRoot '../docs') -Filter '*.md')
        foreach ($document in $documents) {
            $text = Get-Content -LiteralPath $document.FullName -Raw -Encoding utf8
            foreach ($image in [regex]::Matches($text, '!\[([^\]]*)\]\(([^)]+)\)')) {
                $image.Groups[1].Value.Length | Should -BeGreaterThan 40 -Because "$($document.Name) shows $($image.Groups[2].Value)"
            }
        }
    }

    It 'gives the counts of the code in the overview' {
        $rules = @((Get-Content (Join-Path $Data 'rules.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)['rules']).Count
        $scripts = @((Get-Content (Join-Path $Data 'remediations.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable)['remediations']).Count
        $collectors = InModuleScope TenantConverge { @(Get-TcCollector).Count }
        $Overview | Should -Match ">$collectors collectors<"
        $Overview | Should -Match ">$rules rules<"
        $Overview | Should -Match ">$scripts remediation scripts"
        $RunSource | Should -Match ">$collectors collectors read<"
        $RunSource | Should -Match ">$rules rules find"
        $GateSource | Should -Match "None of the $scripts scripts"
    }

    It 'says in the overview that nothing has run on a real tenant' {
        $Overview | Should -Match 'never run on a real tenant yet'
    }

    It 'names no module function that does not exist' {
        $GateSource | Should -Match 'Undo-TcRemediation'
        Get-Command Undo-TcRemediation -Module TenantConverge | Should -Not -BeNullOrEmpty
    }
}

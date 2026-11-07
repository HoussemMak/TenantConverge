BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force

    function ConvertTo-Html {
        param($Data = @{ note = 'x' }, $Tables = @{})
        InModuleScope TenantConverge -Parameters @{ Data = $Data; Tables = $Tables } {
            param($Data, $Tables)
            ConvertTo-TcReportHtml -Data $Data -Tables $Tables
        }
    }

    function ConvertTo-Json2 {
        param($Value)
        InModuleScope TenantConverge -Parameters @{ Value = $Value } {
            param($Value)
            ConvertTo-TcReportJson -InputObject $Value
        }
    }

    function Get-DataBlock {
        <# Returns what a browser would read from one data block. #>
        param([string]$Html, [string]$Id)
        $match = [regex]::Match($Html, "<script id=`"$Id`" type=`"application/json`">(?<json>.*?)</script>", 'Singleline')
        $match.Success | Should -BeTrue -Because "the block $Id must exist and close once"
        $match.Groups['json'].Value
    }

    function Get-Script {
        param([string]$Html)
        $match = [regex]::Match($Html, '<script>(?<code>.*?)</script>', 'Singleline')
        $match.Success | Should -BeTrue
        $match.Groups['code'].Value
    }

    $script:Hostile = @(
        '<img src=x onerror=alert(1)>', '</script><script>alert(2)</script>', '<!-- open', '<script>', ']]>', "line`u{2028}break", '&amp;', "it's",
        '$& $1 $'' $`', '/*__SCRIPT__*/', '/*__TABLES__*/', '/*__DATA__*/', '/*__STYLES__*/', '<!--__ICONS__-->', '__TEXT_FONT__'
    )
}

Describe 'JSON that lives in a script block' {
    It 'writes no character that HTML could read as markup' {
        $json = ConvertTo-Json2 @{ values = $script:Hostile }
        $json | Should -Not -Match '[<>&'']'
    }

    It 'gives back every value exactly' {
        $json = ConvertTo-Json2 @{ values = $script:Hostile }
        $back = $json | ConvertFrom-Json -AsHashtable
        for ($i = 0; $i -lt $script:Hostile.Count; $i++) { $back['values'][$i] | Should -BeExactly $script:Hostile[$i] }
    }

    It 'keeps an empty list and a list of one as lists' {
        $json = ConvertTo-Json2 ([ordered]@{ none = @(); one = @('a') })
        $json | Should -Match '"none":\[\]'
        $json | Should -Match '"one":\["a"\]'
    }

    It 'keeps a null as a null, not as a zero' {
        ConvertTo-Json2 @{ value = $null } | Should -Match '"value":null'
    }

    It 'goes deep enough for a plan' {
        $deep = @{ a = @{ b = @{ c = @{ d = @{ e = @{ f = @{ g = @{ h = 'bottom' } } } } } } } }
        ConvertTo-Json2 $deep | Should -Match 'bottom'
    }
}

Describe 'The assembled page' {
    BeforeAll { $script:Html = ConvertTo-Html }

    It 'leaves no marker behind' {
        $script:Html | Should -Not -Match '/\*__[A-Z_]+__\*/|<!--__[A-Z_]+__-->|__TEXT_FONT__|__CODE_FONT__'
    }

    It 'embeds the two fonts' {
        ([regex]::Matches($script:Html, 'url\(data:font/woff2;base64,')).Count | Should -Be 2
    }

    It 'loads nothing from outside' {
        $script:Html | Should -Not -Match '(?i)<(script|link|img|iframe|object|embed)\b[^>]*\b(src|href)\s*=\s*"?https?:'
        $script:Html | Should -Not -Match '(?i)url\(\s*["'']?https?:'
        $script:Html | Should -Not -Match '(?i)@import'
    }

    It 'closes every script block where it should' {
        ([regex]::Matches($script:Html, '</script>')).Count | Should -Be 3
    }

    It 'says nothing of who made it beyond the module' {
        $script:Html | Should -Match '<html lang="en">'
        $script:Html | Should -Match 'name="generator" content="TenantConverge"'
    }
}

Describe 'The content security policy' {
    BeforeAll {
        $script:Html = ConvertTo-Html
        $script:Policy = [regex]::Match($script:Html, 'http-equiv="Content-Security-Policy" content="(?<p>[^"]+)"').Groups['p'].Value
    }

    It 'comes before anything that could run or load' {
        $script:Policy | Should -Not -BeNullOrEmpty
        $script:Html.IndexOf('Content-Security-Policy') | Should -BeLessThan $script:Html.IndexOf('<style>')
        $script:Html.IndexOf('Content-Security-Policy') | Should -BeLessThan $script:Html.IndexOf('<script')
    }

    It 'refuses every connection and every outside resource' {
        foreach ($directive in "default-src 'none'", "connect-src 'none'", "base-uri 'none'", "form-action 'none'", 'font-src data:', 'img-src data:') {
            $script:Policy | Should -Match ([regex]::Escape($directive))
        }
    }

    It 'runs only the script of the report, by its hash' {
        $script:Policy | Should -Not -Match "script-src[^;]*'unsafe-inline'"
        $code = Get-Script $script:Html
        $hash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($code)))
        $script:Policy | Should -Match ([regex]::Escape("script-src 'sha256-$hash'"))
    }

    It 'hashes what a browser reads: no carriage return in the script' {
        (Get-Script $script:Html) | Should -Not -Match "`r"
    }

    It 'keeps text that would close or confuse a script out of the code' {
        (Get-Script $script:Html) | Should -Not -Match '(?i)</script|<!--|<script'
    }
}

Describe 'Hostile values at assembly' {
    It 'keeps <Value> as data, and inserts each part once' -ForEach @(
        @{ Value = '/*__SCRIPT__*/' }, @{ Value = '/*__TABLES__*/' }, @{ Value = '/*__DATA__*/' }, @{ Value = '/*__STYLES__*/' }, @{ Value = '<!--__ICONS__-->' }, @{ Value = '$& $1 $'' $`' }
    ) {
        $clean = ConvertTo-Html -Data @{ name = 'plain' } -Tables @{ S1 = @{ users = @(@{ Name = 'plain' }) } }
        $html = ConvertTo-Html -Data @{ name = $Value } -Tables @{ S1 = @{ users = @(@{ Name = $Value }) } }

        (Get-DataBlock $html 'report-data' | ConvertFrom-Json -AsHashtable)['name'] | Should -BeExactly $Value
        (Get-DataBlock $html 'report-tables' | ConvertFrom-Json -AsHashtable)['S1']['users'][0]['Name'] | Should -BeExactly $Value
        (Get-Script $html) | Should -BeExactly (Get-Script $clean)
        $html.Length | Should -BeLessThan ($clean.Length + 400)
    }

    It 'does not let a closing script tag end a data block' {
        $html = ConvertTo-Html -Data @{ name = '</script><script>alert(1)</script>' }
        ([regex]::Matches($html, '</script>')).Count | Should -Be 3
    }

    It 'does not let a comment opener break the JSON' {
        $html = ConvertTo-Html -Data @{ name = '<!-- open' }
        (Get-DataBlock $html 'report-data' | ConvertFrom-Json -AsHashtable)['name'] | Should -BeExactly '<!-- open'
    }
}

Describe 'The embedded fonts' {
    BeforeAll {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $script:Notices = Join-Path $script:Root 'THIRD-PARTY-NOTICES.md'
    }

    It 'names each font and its copyright in the notices' {
        $text = Get-Content $script:Notices -Raw
        $text | Should -Match 'Copyright 2022 The Instrument Sans Project Authors'
        $text | Should -Match 'Copyright 2020 The JetBrains Mono Project Authors'
    }

    It 'carries the full license' {
        $text = Get-Content $script:Notices -Raw
        foreach ($clause in 'PREAMBLE', 'DEFINITIONS', 'PERMISSION & CONDITIONS', 'TERMINATION', 'DISCLAIMER') { $text | Should -Match $clause }
    }

    It 'ships every font file the template asks for' {
        foreach ($name in 'instrument-sans.woff2', 'jetbrains-mono.woff2') {
            Join-Path $script:Root 'src/TenantConverge/Private/Report/Fonts' $name | Should -Exist
        }
    }
}

Describe 'The styles of the template' {
    BeforeAll {
        $script:Template = Join-Path $PSScriptRoot '../src/TenantConverge/Private/Report/Template'
        $script:Css = Get-Content (Join-Path $script:Template 'styles.css') -Raw
        $script:Code = (Get-ChildItem $script:Template -Include '*.js', '*.html' -Recurse | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n"
    }

    It 'styles every class the page uses' {
        # Classes that only hook the code, or that are styled through a parent.
        $hooks = 'chev', 'i', 'p', 'none', 'nofile', 'block-note', 'orphans', 'unrecognised', 'status', 'c', 'e', 'v', 'x', 'n', 't', 't2', 'ok', 'info', 'warn', 'q', 'alert', 'partly', 'head', 'cell', 'line'
        $used = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($match in [regex]::Matches($script:Code, 'class="([^"]*)"')) {
            foreach ($token in ($match.Groups[1].Value -replace '\$\{[^}]*\}', ' ' -split '\s+')) { if ($token -match '^[a-z][a-z0-9-]*[a-z0-9]$') { [void]$used.Add($token) } }
        }
        $missing = @($used | Where-Object { $_ -notin $hooks -and $script:Css -notmatch "\.$([regex]::Escape($_))(?![\w-])" } | Sort-Object)
        $missing | Should -BeNullOrEmpty
    }

    It 'gives each tone of a chip and a box its own rule' {
        foreach ($selector in '.chip.blocking', '.chip.warn', '.chip.ok', '.chip.info', '.box.q', '.box.alert', '.box.ok', '.box.note-info', '.action.blocking', '.action.closed', '.link-csv.linked', '.status', '.st-doing', '.st-done', '.st-blocked', '.m-yes', '.m-partial', '.m-no', '.m-check') {
            $script:Css | Should -Match ([regex]::Escape($selector)) -Because $selector
        }
    }

    It 'uses the four colors, by role, in both themes' {
        foreach ($pair in '--Target:#2E62C0', '--S1:#0E8F7E', '--S2:#8A52D8', '--S3:#D0457F', '--Target:#4F86EE', '--S1:#10A88A', '--S2:#AA6CEA', '--S3:#E65F90') { $script:Css | Should -Match $pair }
    }
}

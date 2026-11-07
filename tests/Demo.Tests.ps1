Describe 'The demonstration' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $folder = Join-Path $TestDrive 'demo'
        $script:Returned = @(& (Join-Path $root 'tools/New-TcDemo.ps1') -OutputPath $folder 6>$null)
        $script:ReportFile = Join-Path $folder 'consolidation-report.html'
        $script:WorkbookFile = Join-Path $folder 'consolidation-workbook.xlsx'
        $script:ReportText = Get-Content -LiteralPath $ReportFile -Raw -Encoding utf8

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        function Read-WorkbookText {
            param([Parameter(Mandatory)][string]$Path)
            $zip = [IO.Compression.ZipFile]::OpenRead($Path)
            try {
                $parts = [ordered]@{}
                foreach ($entry in $zip.Entries) {
                    $reader = [IO.StreamReader]::new($entry.Open())
                    $parts[$entry.FullName] = $reader.ReadToEnd()
                    $reader.Dispose()
                }
                $parts
            }
            finally { $zip.Dispose() }
        }
        $script:Parts = Read-WorkbookText -Path $WorkbookFile
    }

    It 'writes a report and a workbook, and leaves nothing else' {
        @(Get-ChildItem -LiteralPath $folder -Name | Sort-Object) | Should -Be @('consolidation-report.html', 'consolidation-workbook.xlsx')
        $Returned | Should -Be @($ReportFile, $WorkbookFile)
    }

    It 'stays small enough to keep in a repository' {
        (Get-Item -LiteralPath $ReportFile).Length | Should -BeLessThan (4MB)
        (Get-Item -LiteralPath $WorkbookFile).Length | Should -BeLessThan (1MB)
    }

    It 'shows no path, user or computer of the machine that wrote it' {
        foreach ($text in @($ReportText) + @($Parts.Values)) {
            $text | Should -Not -Match ([regex]::Escape($HOME))
            $text | Should -Not -Match ([regex]::Escape($root))
            $text | Should -Not -Match ('(?i)\b{0}\b' -f [regex]::Escape($env:USERNAME))
            $text | Should -Not -Match ('(?i)\b{0}\b' -f [regex]::Escape($env:COMPUTERNAME))
        }
    }

    It 'gives the workbook no author but the module' {
        $Parts['docProps/core.xml'] | Should -Match '<dc:creator>TenantConverge</dc:creator>'
    }

    It 'names the fictional tenants, on reserved domains' {
        $ReportText | Should -Match 'Summit Holdings'
        $ReportText | Should -Match 'summit\.example'
        $domains = @([regex]::Matches($ReportText, '[\w.-]+@([\w-]+(\.[\w-]+)+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $domains | Should -Not -BeNullOrEmpty
        @($domains | Where-Object { $_ -notmatch '\.example$|^example\.com$|^fictional-[a-z]+\.onmicrosoft\.com$|^odata\.' }) | Should -BeNullOrEmpty
    }

    It 'uses no tenant address that a real tenant could hold' {
        $ReportText | Should -Not -Match '(?<![\w-])(summit|alpine|birch|cedar)(-my)?\.(sharepoint|onmicrosoft)\.com'
        ($Parts.Values -join ' ') | Should -Not -Match '(?<![\w-])(summit|alpine|birch|cedar)(-my)?\.(sharepoint|onmicrosoft)\.com'
    }

    It 'uses only phone numbers set aside for fiction' {
        $numbers = @([regex]::Matches($ReportText, '\+1\d{10}') | ForEach-Object Value | Sort-Object -Unique)
        $numbers | Should -Not -BeNullOrEmpty
        @($numbers | Where-Object { $_ -notmatch '^\+1\d{3}55501\d{2}$' }) | Should -BeNullOrEmpty
    }

    It 'says that the remediations are untested, in both files' {
        $ReportText | Should -Match 'Untested'
        ($Parts.Values -join ' ') | Should -Match 'Untested'
    }

    It 'is in the repository, under its own names' {
        Join-Path $root 'docs/demo/consolidation-report.html' | Should -Exist
        Join-Path $root 'docs/demo/consolidation-workbook.xlsx' | Should -Exist
        (Get-Item (Join-Path $root 'docs/demo/consolidation-report.html')).Length | Should -BeLessThan (4MB)
        (Get-Item (Join-Path $root 'docs/demo/consolidation-workbook.xlsx')).Length | Should -BeLessThan (1MB)
    }

    It 'keeps the bytes of the demonstration: git changes no line ending in it' {
        git -C $root check-attr text -- docs/demo/consolidation-report.html | Should -Match 'text: unset'
        git -C $root check-attr binary -- docs/demo/consolidation-workbook.xlsx | Should -Match 'binary: set'
    }

    It 'shows the module version of this repository, not an older one' {
        $manifest = Test-ModuleManifest (Join-Path $root 'src/TenantConverge/TenantConverge.psd1')
        Get-Content (Join-Path $root 'docs/demo/consolidation-report.html') -Raw -Encoding utf8 | Should -Match ('TenantConverge {0}|"moduleVersion":"{0}' -f [regex]::Escape([string]$manifest.Version))
    }
}

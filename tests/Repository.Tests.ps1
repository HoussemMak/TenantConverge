Describe 'Repository rules' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        Import-Module (Join-Path $root 'src/TenantConverge/TenantConverge.psd1') -Force
        $workflow = Join-Path $root '.github/workflows/ci.yml'
    }

    It 'calls Read-Host only in Read-TcAnswer' {
        $files = Get-ChildItem (Join-Path $root 'src') -Filter '*.ps1' -Recurse
        $callers = foreach ($file in $files) {
            $tokens = $null
            $parseErrors = $null
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            $calls = $ast.FindAll({
                    param($node)
                    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Read-Host'
                }, $true)
            if ($calls) { $file.Name }
        }
        $callers | Should -Be 'Read-TcAnswer.ps1'
    }

    It 'gives every public command a synopsis and an example' {
        $commands = (Get-Module TenantConverge).ExportedFunctions.Keys
        $commands | Should -Not -BeNullOrEmpty
        foreach ($command in $commands) {
            $help = Get-Help $command -Full
            $help.Synopsis | Should -Not -Match '^\s*$' -Because "$command needs a synopsis"
            $help.Synopsis | Should -Not -Match '^\s*\r?\n?\s*Start-|^\s*\r?\n?\s*New-|^\s*\r?\n?\s*Test-' -Because "$command needs a written synopsis"
            @($help.examples.example).Count | Should -BeGreaterThan 0 -Because "$command needs an example"
        }
    }

    It 'pins every GitHub Action to a full commit SHA' {
        $uses = @(Get-Content $workflow | Where-Object { $_ -match '^\s*(-\s*)?uses:' })
        $uses | Should -Not -BeNullOrEmpty
        foreach ($line in $uses) {
            $line | Should -Match '@[0-9a-f]{40}(\s|$)'
        }
    }

    It 'limits the time of every job of every workflow' {
        foreach ($file in Get-ChildItem (Join-Path $root '.github/workflows') -Filter '*.yml') {
            $text = Get-Content $file.FullName -Raw
            ([regex]::Matches($text, '(?m)^\s+timeout-minutes:\s*\d+\s*$')).Count | Should -Be ([regex]::Matches($text, '(?m)^\s+runs-on:')).Count -Because $file.Name
        }
    }

    It 'declares least-privilege workflow permissions' {
        $text = Get-Content $workflow -Raw
        $text | Should -Match '(?m)^permissions:'
        $text | Should -Match 'contents: read'
        $text | Should -Not -Match ':\s*write\b'
    }

    It 'covers install, usage, the three-source limit and the license in the README' {
        $readme = Get-Content (Join-Path $root 'README.md') -Raw
        $readme | Should -Match '(?m)^## Install'
        $readme | Should -Match '(?m)^## Usage'
        $readme | Should -Match '(?m)^## License'
        $readme | Should -Match 'Apache-2\.0'
        $readme | Should -Match '1, 2 or 3 source'
        $readme | Should -Match 'Start-TenantConverge'
    }

    It 'keeps every example on a reserved .example domain' {
        $examples = Get-ChildItem (Join-Path $root 'examples') -Filter '*.project.json'
        $examples | Should -Not -BeNullOrEmpty
        foreach ($example in $examples) {
            $project = Get-Content $example.FullName -Raw | ConvertFrom-Json
            foreach ($tenant in @($project.target) + @($project.sources)) {
                $tenant.primaryDomain | Should -Match '\.example$'
            }
        }
    }

    It 'ignores local tooling folders' {
        foreach ($sample in '.superpowers/notes.md', '.claude/notes.md') {
            git -C $root check-ignore -q $sample
            $LASTEXITCODE | Should -Be 0 -Because "$sample must never be staged"
        }
    }

    It 'tells maintainers how to turn on the hooks' {
        Get-Content (Join-Path $root 'CONTRIBUTING.md') -Raw | Should -Match 'Enable-TcHooks'
    }

    It 'explains what a wave is in the README' {
        Get-Content (Join-Path $root 'README.md') -Raw | Should -Match '(?i)a wave is'
    }

    It 'ships the security and contribution guides' {
        Get-Content (Join-Path $root 'SECURITY.md') -Raw | Should -Match 'private'
        Get-Content (Join-Path $root 'CONTRIBUTING.md') -Raw | Should -Match 'Invoke-Pester'
    }
}

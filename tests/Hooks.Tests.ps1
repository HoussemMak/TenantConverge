Describe 'Git hooks' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

        function New-HookRepository {
            param([switch]$WithoutTerms)
            $folder = Join-Path $TestDrive ([guid]::NewGuid())
            New-Item -ItemType Directory -Path (Join-Path $folder 'tools') -Force | Out-Null
            Copy-Item (Join-Path $root 'tools/Test-TcForbiddenTerm.ps1') (Join-Path $folder 'tools')
            Copy-Item (Join-Path $root '.githooks') (Join-Path $folder '.githooks') -Recurse
            git -C $folder init -q -b main
            git -C $folder config user.name 'Test Author'
            git -C $folder config user.email 'author@test.example'
            git -C $folder config core.hooksPath .githooks
            if (-not $WithoutTerms) {
                $terms = Join-Path $folder '.git/terms.txt'
                Set-Content -Path $terms -Value 'ZZSECRET'
                git -C $folder config tenantconverge.termsfile $terms
            }
            git -C $folder add -A
            git -C $folder commit -q --no-verify -m 'start'
            $folder
        }

        function Invoke-Git {
            param([string]$Folder, [string[]]$Arguments)
            $null = & git -C $Folder @Arguments 2>&1
            $LASTEXITCODE
        }
    }

    It 'blocks a commit whose staged content has a term, even if the working copy is clean' {
        $folder = New-HookRepository
        $file = Join-Path $folder 'file.txt'
        Set-Content -Path $file -Value 'ZZSECRET'
        git -C $folder add file.txt
        Set-Content -Path $file -Value 'clean'

        Invoke-Git $folder @('commit', '-q', '-m', 'add file') | Should -Not -Be 0
    }

    It 'lets a commit pass when only an untracked file has a term' {
        $folder = New-HookRepository
        Set-Content -Path (Join-Path $folder 'scratch.txt') -Value 'ZZSECRET'
        Set-Content -Path (Join-Path $folder 'clean.txt') -Value 'clean'
        git -C $folder add clean.txt

        Invoke-Git $folder @('commit', '-q', '-m', 'add clean file') | Should -Be 0
    }

    It 'blocks a commit message with a term' {
        $folder = New-HookRepository
        Set-Content -Path (Join-Path $folder 'clean.txt') -Value 'clean'
        git -C $folder add clean.txt

        Invoke-Git $folder @('commit', '-q', '-m', 'about ZZSECRET') | Should -Not -Be 0
    }

    It 'blocks a merge commit that brings a term' {
        $folder = New-HookRepository
        git -C $folder checkout -q -b side
        Set-Content -Path (Join-Path $folder 'side.txt') -Value 'ZZSECRET'
        git -C $folder add side.txt
        git -C $folder commit -q --no-verify -m 'side work'
        git -C $folder checkout -q main
        Set-Content -Path (Join-Path $folder 'main.txt') -Value 'clean'
        git -C $folder add main.txt
        git -C $folder commit -q -m 'main work'

        Invoke-Git $folder @('merge', '-q', '--no-edit', 'side') | Should -Not -Be 0
    }

    It 'blocks a push when the history has a term' {
        $folder = New-HookRepository
        $remote = Join-Path $TestDrive ([guid]::NewGuid())
        git init -q --bare $remote
        git -C $folder remote add origin $remote
        Set-Content -Path (Join-Path $folder 'file.txt') -Value 'ZZSECRET'
        git -C $folder add file.txt
        git -C $folder commit -q --no-verify -m 'skipped the hooks'

        Invoke-Git $folder @('push', '-q', 'origin', 'main') | Should -Not -Be 0
    }

    It 'does nothing without a terms file' {
        $folder = New-HookRepository -WithoutTerms
        Set-Content -Path (Join-Path $folder 'file.txt') -Value 'ZZSECRET'
        git -C $folder add file.txt

        Invoke-Git $folder @('commit', '-q', '-m', 'outside contributor') | Should -Be 0
    }

    It 'blocks when the configured terms file is missing' {
        $folder = New-HookRepository
        git -C $folder config tenantconverge.termsfile (Join-Path $TestDrive 'absent.txt')
        Set-Content -Path (Join-Path $folder 'clean.txt') -Value 'clean'
        git -C $folder add clean.txt

        Invoke-Git $folder @('commit', '-q', '-m', 'add clean file') | Should -Not -Be 0
    }
}

Describe 'Enable-TcHooks' {
    BeforeAll {
        $tool = (Resolve-Path (Join-Path $PSScriptRoot '../tools/Enable-TcHooks.ps1')).Path
    }

    It 'turns on the hooks and records the full path of the terms file' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $folder | Out-Null
        git -C $folder init -q -b main
        $terms = Join-Path $TestDrive 'terms.txt'
        Set-Content -Path $terms -Value 'ZZSECRET'

        & pwsh -NoProfile -File $tool -TermsPath $terms -Path $folder | Out-Null

        $LASTEXITCODE | Should -Be 0
        git -C $folder config --get core.hooksPath | Should -Be '.githooks'
        git -C $folder config --get tenantconverge.termsfile | Should -Be (Resolve-Path $terms).Path
    }

    It 'stops when the terms file does not exist' {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Path $folder | Out-Null
        git -C $folder init -q -b main

        & pwsh -NoProfile -File $tool -TermsPath (Join-Path $TestDrive 'absent.txt') -Path $folder 2>&1 | Out-Null

        $LASTEXITCODE | Should -Not -Be 0
        git -C $folder config --get core.hooksPath | Should -BeNullOrEmpty
    }
}

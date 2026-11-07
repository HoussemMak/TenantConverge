Describe 'Test-TcForbiddenTerm' {
    BeforeAll {
        $tool = (Resolve-Path (Join-Path $PSScriptRoot '../tools/Test-TcForbiddenTerm.ps1')).Path

        function Invoke-Guard {
            param([string[]]$Arguments)
            $lines = & pwsh -NoProfile -File $tool @Arguments 2>&1
            [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($lines -join "`n") }
        }

        function New-TestRepository {
            $folder = Join-Path $TestDrive ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $folder | Out-Null
            git -C $folder init -q -b main
            git -C $folder config user.name 'Test Author'
            git -C $folder config user.email 'author@test.example'
            $folder
        }

        function Add-Commit {
            param([string]$Folder, [string]$Message = 'test commit')
            git -C $Folder add -A
            git -C $Folder commit -q -m $Message
        }

        $terms = Join-Path $TestDrive 'terms.txt'
        Set-Content -Path $terms -Value @('# comment', 'ZZSECRET', '\bZZW\b')
    }

    It 'returns 0 on a clean tree' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'clean.txt') -Value 'nothing here'
        Add-Commit $folder

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder)).Code | Should -Be 0
    }

    It 'returns 1 for a match inside a tracked file' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'bad.txt') -Value @('line one', 'has ZZSECRET inside')
        Add-Commit $folder

        $result = Invoke-Guard @('-TermsPath', $terms, '-Path', $folder)

        $result.Code | Should -Be 1
        $result.Output | Should -Match 'bad\.txt:2 matched term #1'
    }

    It 'returns 1 for a match in a file not added yet' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'new.txt') -Value 'ZZSECRET'

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder)).Code | Should -Be 1
    }

    It 'ignores files covered by .gitignore' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder '.gitignore') -Value 'private.txt'
        Set-Content -Path (Join-Path $folder 'private.txt') -Value 'ZZSECRET'

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder)).Code | Should -Be 0
    }

    It 'returns 1 for a match in a file name' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'ZZSECRET-notes.txt') -Value 'clean'

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder)).Code | Should -Be 1
    }

    It 'finds a term inside a binary file' {
        $folder = New-TestRepository
        $bytes = [byte[]](0, 1, 2) + [Text.Encoding]::ASCII.GetBytes('ZZSECRET') + [byte[]](0, 3)
        [IO.File]::WriteAllBytes((Join-Path $folder 'data.bin'), $bytes)

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder)).Code | Should -Be 1
    }

    It 'returns 1 for a match in a commit message with -IncludeGitHistory' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'clean.txt') -Value 'clean'
        Add-Commit $folder 'about ZZSECRET'

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder)).Code | Should -Be 0
        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-IncludeGitHistory')).Code | Should -Be 1
    }

    It 'returns 1 for a match in the author with -IncludeGitHistory' {
        $folder = New-TestRepository
        git -C $folder config user.name 'ZZSECRET Person'
        Set-Content -Path (Join-Path $folder 'clean.txt') -Value 'clean'
        Add-Commit $folder

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-IncludeGitHistory')).Code | Should -Be 1
    }

    It 'finds a term removed from the tree but kept in the history' {
        $folder = New-TestRepository
        $file = Join-Path $folder 'file.txt'
        Set-Content -Path $file -Value 'ZZSECRET'
        Add-Commit $folder
        Set-Content -Path $file -Value 'clean'
        Add-Commit $folder

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder)).Code | Should -Be 0
        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-IncludeGitHistory')).Code | Should -Be 1
    }

    It 'returns 1 for a term in the name of a <Kind>, and masks the name' -ForEach @(
        @{ Kind = 'branch'; Command = 'branch' }
        @{ Kind = 'tag'; Command = 'tag' }
    ) {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'clean.txt') -Value 'clean'
        Add-Commit $folder
        git -C $folder $Command 'work-ZZSECRET'

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder)).Code | Should -Be 0
        $result = Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-IncludeGitHistory')
        $result.Code | Should -Be 1
        $result.Output | Should -Match 'matched term #1'
        $result.Output | Should -Not -Match 'ZZSECRET'
    }

    It 'returns 1 for a term in the message of an annotated tag' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'clean.txt') -Value 'clean'
        Add-Commit $folder
        git -C $folder tag -a 'v1' -m 'about ZZSECRET'

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-IncludeGitHistory')).Code | Should -Be 1
    }

    It 'stays at 0 for clean branches and tags' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'clean.txt') -Value 'clean'
        Add-Commit $folder
        git -C $folder branch 'work'
        git -C $folder tag -a 'v1' -m 'first'

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-IncludeGitHistory')).Code | Should -Be 0
    }

    It 'accepts a repository with no commit yet' {
        $folder = New-TestRepository

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-IncludeGitHistory')).Code | Should -Be 0
    }

    It 'checks a commit message file' {
        $folder = New-TestRepository
        $good = Join-Path $TestDrive 'good-message.txt'
        $bad = Join-Path $TestDrive 'bad-message.txt'
        Set-Content -Path $good -Value 'a clean message'
        Set-Content -Path $bad -Value 'mentions ZZSECRET'

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-MessageFile', $good)).Code | Should -Be 0
        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-MessageFile', $bad)).Code | Should -Be 1
    }

    It 'reads a relative message file from the current location, not from the process folder' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'good.txt') -Value 'a clean message'
        Set-Content -Path (Join-Path $folder 'bad.txt') -Value 'mentions ZZSECRET'
        $call = "Set-Location -LiteralPath '$folder'; & '$tool' -TermsPath '$terms' -Path . -MessageFile {0}; exit `$LASTEXITCODE"

        & pwsh -NoProfile -Command ($call -f 'good.txt') *> $null
        $LASTEXITCODE | Should -Be 0
        & pwsh -NoProfile -Command ($call -f 'bad.txt') *> $null
        $LASTEXITCODE | Should -Be 1
    }

    It 'checks the staged version with -Staged' {
        $folder = New-TestRepository
        $file = Join-Path $folder 'file.txt'
        Set-Content -Path $file -Value 'ZZSECRET'
        git -C $folder add file.txt
        Set-Content -Path $file -Value 'clean'

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-Staged')).Code | Should -Be 1
    }

    It 'ignores untracked files with -Staged' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'scratch.txt') -Value 'ZZSECRET'

        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-Staged')).Code | Should -Be 0
    }

    It 'checks a staged file name with -Staged' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'ZZSECRET-notes.txt') -Value 'clean'
        git -C $folder add -A

        $result = Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-Staged')

        $result.Code | Should -Be 1
        $result.Output | Should -Not -Match 'ZZSECRET'
    }

    It 'returns 2 when the terms file is missing' {
        $folder = New-TestRepository

        (Invoke-Guard @('-TermsPath', (Join-Path $TestDrive 'absent.txt'), '-Path', $folder)).Code | Should -Be 2
    }

    It 'returns 2 when the terms file has no pattern' {
        $folder = New-TestRepository
        $empty = Join-Path $TestDrive 'empty.txt'
        Set-Content -Path $empty -Value @('# only a comment', '')

        (Invoke-Guard @('-TermsPath', $empty, '-Path', $folder)).Code | Should -Be 2
    }

    It 'returns 2 for an invalid pattern, without printing it' {
        $folder = New-TestRepository
        $broken = Join-Path $TestDrive 'broken.txt'
        Set-Content -Path $broken -Value 'ZZBROKEN('

        $result = Invoke-Guard @('-TermsPath', $broken, '-Path', $folder)

        $result.Code | Should -Be 2
        $result.Output | Should -Not -Match 'ZZBROKEN'
    }

    It 'never prints the term or the matching line' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'bad.txt') -Value 'context words ZZSECRET more'
        Set-Content -Path (Join-Path $folder 'ZZSECRET-name.txt') -Value 'clean'
        Add-Commit $folder 'message with ZZSECRET'

        $result = Invoke-Guard @('-TermsPath', $terms, '-Path', $folder, '-IncludeGitHistory')

        $result.Code | Should -Be 1
        $result.Output | Should -Not -Match 'ZZSECRET'
        $result.Output | Should -Not -Match 'context words'
        $result.Output | Should -Match 'matched term #1'
    }

    It 'matches whole words and case only when the pattern says so' {
        $folder = New-TestRepository
        Set-Content -Path (Join-Path $folder 'near.txt') -Value @('ZZWX', 'zzw')
        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder)).Code | Should -Be 0

        Set-Content -Path (Join-Path $folder 'exact.txt') -Value 'the ZZW word'
        (Invoke-Guard @('-TermsPath', $terms, '-Path', $folder)).Code | Should -Be 1
    }
}

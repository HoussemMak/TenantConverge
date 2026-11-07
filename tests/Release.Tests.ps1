BeforeDiscovery {
    $script:CanPack = [bool](Get-Command Compress-PSResource -ErrorAction SilentlyContinue)
}

Describe 'The release workflow' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $file = Join-Path $root '.github/workflows/release.yml'
        $text = (Get-Content $file -Raw) -replace "`r`n", "`n"
        $jobs = [ordered]@{}
        foreach ($block in [regex]::Matches(($text -split '(?m)^jobs:\n', 2)[1], '(?ms)^  (?<name>[\w-]+):\n(?<body>.*?)(?=^  [\w-]+:\n|\z)')) { $jobs[$block.Groups['name'].Value] = $block.Groups['body'].Value }
    }

    It 'runs on a tag named v and on nothing else' {
        $trigger = [regex]::Match($text, '(?ms)^on:\n(.*?)^\S').Groups[1].Value
        $trigger | Should -Match "(?m)^  push:\n    tags:\n      - 'v\*'\n"
        ($trigger -split "`n" | Where-Object { $_ -match '^  \w' }) | Should -Be '  push:'
        $trigger | Should -Not -Match 'branches'
    }

    It 'checks the tag again in the job that publishes' {
        $jobs['publish'] | Should -Match "(?m)^    if: startsWith\(github\.ref, 'refs/tags/v'\)$"
    }

    It 'grants nothing at the top, and to each job only what it reads' {
        $text | Should -Match '(?m)^permissions: \{\}$'
        $jobs.Count | Should -BeGreaterThan 1
        foreach ($name in $jobs.Keys) {
            $jobs[$name] | Should -Match '(?m)^    permissions:\n      contents: read$' -Because $name
        }
        $text | Should -Not -Match ':\s*write\b'
    }

    It 'pins every action to a full commit SHA' {
        $uses = @($text -split "`n" | Where-Object { $_ -match '^\s*(-\s*)?uses:' })
        $uses.Count | Should -BeGreaterThan 1
        foreach ($line in $uses) { $line | Should -Match '@[0-9a-f]{40}(\s|$)' }
    }

    It 'publishes only after the job that tests' {
        $jobs['publish'] | Should -Match '(?m)^    needs: test$'
        $jobs['test'] | Should -Match 'Invoke-Pester tests'
        $jobs['test'] | Should -Not -Match 'Publish-Module|PSGALLERY_API_KEY'
    }

    It 'refuses a tag that is not the version of the manifest' {
        $jobs['test'] | Should -Match 'TAG: \$\{\{ github\.ref_name \}\}'
        $jobs['test'] | Should -Match '\$env:TAG -cne'
        $text | Should -Not -Match 'run:.*\$\{\{'
    }

    It 'stops without the term check, instead of skipping it' {
        $jobs['test'] | Should -Match 'TC_FORBIDDEN_TERMS: \$\{\{ secrets\.TC_FORBIDDEN_TERMS \}\}'
        $jobs['test'] | Should -Match 'Test-TcForbiddenTerm\.ps1 -TermsPath \$file -Path \. -IncludeGitHistory'
        $jobs['test'] | Should -Match "throw '[^']*TC_FORBIDDEN_TERMS"
        $jobs['test'] | Should -Not -Match 'Skipping'
    }

    It 'publishes the folder of the module, with the key of the Gallery' {
        $jobs['publish'] | Should -Match 'PSGALLERY_API_KEY: \$\{\{ secrets\.PSGALLERY_API_KEY \}\}'
        $jobs['publish'] | Should -Match 'Publish-Module -Path \./src/TenantConverge -NuGetApiKey \$env:PSGALLERY_API_KEY -Repository PSGallery'
        ([regex]::Matches($text, 'Publish-Module')).Count | Should -Be 1
    }
}

Describe 'The published package' {
    BeforeAll {
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        $module = Join-Path $root 'src/TenantConverge'

        function Get-ModuleFile {
            Get-ChildItem $module -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($module, $_.FullName).Replace([IO.Path]::DirectorySeparatorChar, [char]'/') } | Sort-Object
        }
    }

    It 'carries the license and the notices, the same as the repository' -ForEach @(
        @{ Name = 'LICENSE' }, @{ Name = 'NOTICE' }, @{ Name = 'THIRD-PARTY-NOTICES.md' }
    ) {
        Join-Path $module $Name | Should -Exist
        (Get-FileHash (Join-Path $module $Name)).Hash | Should -Be (Get-FileHash (Join-Path $root $Name)).Hash
    }

    It 'has no test, tool, document or private file in the folder it publishes' {
        $relative = @(Get-ModuleFile)
        $relative | Should -Not -BeNullOrEmpty
        @($relative | Where-Object { $_ -match '\.Tests\.ps1$|^(tests|tools|docs|examples|prive)/|\.(log|xml|pfx|cer|key|pem)$' }) | Should -BeNullOrEmpty
    }

    Context 'Packed as the Gallery receives it' -Skip:(-not $CanPack) {
        BeforeAll {
            $folder = Join-Path $TestDrive 'package'
            New-Item -ItemType Directory -Path $folder | Out-Null
            Compress-PSResource -Path $module -DestinationPath $folder -ErrorAction Stop
            $script:Package = @(Get-ChildItem $folder -Filter '*.nupkg')
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($Package[0].FullName)
            $script:Entries = @($zip.Entries.FullName | ForEach-Object { [uri]::UnescapeDataString($_) })
            $zip.Dispose()
        }

        It 'is named after the version of the manifest' {
            $manifest = Test-ModuleManifest (Join-Path $module 'TenantConverge.psd1')
            $Package.Name | Should -Be ('TenantConverge.{0}-{1}.nupkg' -f $manifest.Version, $manifest.PrivateData.PSData.Prerelease)
        }

        It 'holds the files of the module folder and nothing else, but what the format adds' {
            $format = '^(_rels/|package/|\[Content_Types\]\.xml$|TenantConverge\.nuspec$)'
            @($Entries | Where-Object { $_ -notmatch $format } | Sort-Object) | Should -Be @(Get-ModuleFile)
        }
    }
}

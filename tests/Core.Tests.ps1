Describe 'Run log' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    }

    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        InModuleScope TenantConverge -Parameters @{ Folder = $folder } {
            param($Folder)
            Initialize-TcLog -Path $Folder
        }
    }

    AfterEach {
        InModuleScope TenantConverge {
            $script:TcLogFile = $null
            $script:TcEventFile = $null
        }
    }

    It 'creates the log files and the exports folder' {
        Test-Path (Join-Path $folder 'exports') | Should -BeTrue
        InModuleScope TenantConverge { Write-TcLog -Message 'Collection started' }
        Test-Path (Join-Path $folder 'journal.log') | Should -BeTrue
        Test-Path (Join-Path $folder 'events.jsonl') | Should -BeTrue
    }

    It 'writes a text line with level and step' {
        InModuleScope TenantConverge { Write-TcLog -Message 'Read users' -Level WARN -Step 'ENT-03' }
        $line = Get-Content (Join-Path $folder 'journal.log') -Raw
        $line | Should -Match '\[WARN\s*\] \[ENT-03\] Read users'
    }

    It 'writes one readable JSON event per line' {
        InModuleScope TenantConverge {
            Write-TcLog -Message 'first'
            Write-TcLog -Message 'second' -Level OK -Step 'ENT-01' -Data @{ rows = 12 }
        }
        $lines = @(Get-Content (Join-Path $folder 'events.jsonl'))
        $lines.Count | Should -Be 2
        $event2 = $lines[1] | ConvertFrom-Json
        $event2.message | Should -Be 'second'
        $event2.level | Should -Be 'OK'
        $event2.step | Should -Be 'ENT-01'
        $event2.data.rows | Should -Be 12
        { [datetimeoffset]::Parse($event2.timestamp) } | Should -Not -Throw
    }

    It 'never writes a secret to either file' -TestCases @(
        @{ Text = 'login failed password=Hunter2!x' }
        @{ Text = 'client_secret=abc123XYZ was refused' }
        @{ Text = 'Authorization: Bearer abcdefghijklmnop.qrstuvwxyz' }
        @{ Text = 'token eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxMjM0NTYifQ.c2lnbmF0dXJlMTIz' }
        @{ Text = '{"access_token":"s3cr3tvalue","expires":10}' }
        @{ Text = 'thumbprint 0123456789ABCDEF0123456789ABCDEF01234567' }
    ) {
        InModuleScope TenantConverge -Parameters @{ Text = $Text } {
            param($Text)
            Write-TcLog -Message $Text
        }
        $all = (Get-Content (Join-Path $folder 'journal.log') -Raw) + (Get-Content (Join-Path $folder 'events.jsonl') -Raw)
        foreach ($secret in 'Hunter2!x', 'abc123XYZ', 'abcdefghijklmnop', 'eyJhbGciOiJSUzI1NiJ9', 's3cr3tvalue', '0123456789ABCDEF0123456789ABCDEF01234567') {
            $all | Should -Not -Match ([regex]::Escape($secret))
        }
    }

    It 'never writes a secret held in structured data' {
        InModuleScope TenantConverge {
            Write-TcLog -Message 'connected' -Data @{
                clientId = 'visible-id'
                clientSecret = 'p4ssw0rd-value'
                nested = @{ password = 'other-value'; list = @('Bearer zzzzzzzzzzzzzzzzzzzz') }
            }
        }
        $event = Get-Content (Join-Path $folder 'events.jsonl') -Raw
        $event | Should -Match 'visible-id'
        $event | Should -Not -Match 'p4ssw0rd-value'
        $event | Should -Not -Match 'other-value'
        $event | Should -Not -Match 'zzzzzzzzzzzzzzzzzzzz'
    }

    It 'does nothing before the log is set up' {
        InModuleScope TenantConverge {
            $script:TcLogFile = $null
            { Write-TcLog -Message 'ignored' } | Should -Not -Throw
        }
    }
}

Describe 'Core helpers' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    }

    It 'reads a property from a dictionary, an object or nothing' {
        InModuleScope TenantConverge {
            Get-TcProperty @{ a = 1 } 'a' | Should -Be 1
            Get-TcProperty ([ordered]@{ a = 2 }) 'a' | Should -Be 2
            Get-TcProperty ([pscustomobject]@{ a = 3 }) 'a' | Should -Be 3
            Get-TcProperty $null 'a' | Should -BeNullOrEmpty
            Get-TcProperty @{ a = 1 } 'b' | Should -BeNullOrEmpty
        }
    }

    It 'returns the default only when the property is missing' {
        InModuleScope TenantConverge {
            Get-TcProperty @{ a = 1 } 'b' 'fallback' | Should -Be 'fallback'
            Get-TcProperty $null 'b' 'fallback' | Should -Be 'fallback'
            Get-TcProperty ([pscustomobject]@{ a = 1 }) 'b' 7 | Should -Be 7
            Get-TcProperty @{ a = $false } 'a' $true | Should -BeFalse
        }
    }

    It 'turns nested objects into dictionaries' {
        InModuleScope TenantConverge {
            $copy = ConvertTo-TcHashtable ([pscustomobject]@{ a = 1; b = [pscustomobject]@{ c = @(1, 2) } })
            $copy['a'] | Should -Be 1
            $copy['b']['c'].Count | Should -Be 2
            ConvertTo-TcHashtable $null | Should -BeNullOrEmpty
        }
    }

    It 'writes JSON atomically and reads it back in order' {
        $file = Join-Path $TestDrive 'data.json'
        InModuleScope TenantConverge -Parameters @{ File = $file } {
            param($File)
            Write-TcJsonFile -Path $File -InputObject ([ordered]@{ zebra = 1; alpha = 'Éric'; rows = @([ordered]@{ a = 1 }) })
            $read = Read-TcJsonFile -Path $File
            @($read.Keys) | Should -Be @('zebra', 'alpha', 'rows')
            $read['alpha'] | Should -Be 'Éric'
            @($read['rows'])[0]['a'] | Should -Be 1
        }
        Test-Path "$file.tmp" | Should -BeFalse
    }

    It 'writes a relative path against the PowerShell location, not the folder of the process' {
        $folder = Join-Path $TestDrive 'elsewhere'
        New-Item -ItemType Directory -Force $folder | Out-Null
        Push-Location $folder
        try {
            InModuleScope TenantConverge { Write-TcJsonFile -Path './relative.json' -InputObject @{ a = 1 } }
        }
        finally { Pop-Location }
        Test-Path (Join-Path $folder 'relative.json') | Should -BeTrue
    }

    It 'keeps a single row as a list in JSON' {
        $file = Join-Path $TestDrive 'single.json'
        InModuleScope TenantConverge -Parameters @{ File = $file } {
            param($File)
            Write-TcJsonFile -Path $File -InputObject @{ rows = @(@{ a = 1 }) }
        }
        (Get-Content $file -Raw) | Should -Match '"rows":\s*\['
    }

    It 'reads the error text of a Graph failure' {
        InModuleScope TenantConverge {
            $body = 'Failed: {"error":{"code":"Forbidden","message":"Insufficient privileges"}}'
            Get-TcErrorText ([System.Exception]::new($body)) | Should -Be 'Forbidden: Insufficient privileges'
            Get-TcErrorText 'plain   text' | Should -Be 'plain text'
            Get-TcErrorText $null | Should -Be ''
        }
    }

    It 'reads the domain and the prefix of an address' {
        InModuleScope TenantConverge {
            Get-TcAddressDomain 'Ana@Summit.Example' | Should -Be 'summit.example'
            Get-TcAddressDomain 'no-domain' | Should -Be ''
            Get-TcAddressPrefix 'smtp:ana@summit.example' | Should -Be 'ana'
            Get-TcAddressPrefix 'no-domain' | Should -Be 'no-domain'
        }
    }
}

Describe 'Step display' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    }

    It 'shows each step and logs it' {
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Write-TcLog -ModuleName TenantConverge
        InModuleScope TenantConverge {
            Write-TcPhase -Title 'Assessment of Summit' -StepCount 2
            Write-TcStepStart -Rank 1 -Total 2 -Id 'ENT-01' -Title 'Organization' -Purpose 'Entra ID'
            Write-TcStepLine -Status OK -Text '1 table' -Step 'ENT-01'
            Write-TcStepEnd -Status Done -Seconds 1.5
        }
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -Times 5 -Exactly
        Should -Invoke Write-TcLog -ModuleName TenantConverge -ParameterFilter { $Level -eq 'OK' -and $Step -eq 'ENT-01' } -Times 1 -Exactly
    }
}

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Notice = 'UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.'
    $script:FakeSnapshot = & (Join-Path $Root 'tools/New-TcFakeSnapshot.ps1') -SourceCount 2 -Seed 3
    $FakeSnapshot['meta']['finished'] = (Get-Date).ToString('o')
    Import-Module (Join-Path $Root 'src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RemediationStubs.ps1')
    Install-TcRemediationStub -Mode Empty

    $script:Work = Join-Path $TestDrive 'work'
    New-Item -ItemType Directory -Force -Path $Work | Out-Null

    function New-TcSampleProject {
        param([string]$Output)
        $target = $FakeSnapshot['tenants']['Target']
        $sources = foreach ($role in @($FakeSnapshot['tenants'].Keys | Where-Object { $_ -ne 'Target' })) {
            [pscustomobject]@{ role = $role; displayName = $FakeSnapshot['tenants'][$role]['displayName']; primaryDomain = $FakeSnapshot['tenants'][$role]['primaryDomain']; tenantId = $FakeSnapshot['tenants'][$role]['tenantId']; wave = 1 }
        }
        [pscustomobject]@{
            schemaVersion = 1; name = 'Sample'
            target = [pscustomobject]@{ displayName = $target['displayName']; primaryDomain = $target['primaryDomain']; tenantId = $target['tenantId']; state = 'Production' }
            sources = @($sources); access = [pscustomobject]@{ mode = 'Browser' }; output = [pscustomobject]@{ path = $Output }
        }
    }

    function New-TcSampleScript {
        <# A remediation in its real shape: it declares, the engine acts. #>
        param([string]$Id, [string]$Body)
        $path = Join-Path $Work "$Id.ps1"
        Set-Content -LiteralPath $path -Value "# $Notice`n[CmdletBinding()]`nparam()`n`$c = Open-TcRemediation`n$Body`nClose-TcRemediation" -Encoding utf8
        $path
    }

    function Set-TcSampleCatalog {
        <# Puts fixture scripts in place of the manifest. #>
        param([hashtable[]]$Entry)
        $module = Get-Module TenantConverge
        & $module {
            param($Entries, $Folder)
            $script:TcRemediationCatalog = [ordered]@{}
            foreach ($item in $Entries) {
                $full = [ordered]@{ id = $item['id']; title = "Title of $($item['id'])"; workload = 'Entra ID'; ruleIds = @(); nature = 'Decision'; risk = 'Medium'; reversible = $true; permissions = @('User.ReadWrite.All'); testedOnRealTenant = $false; testedEvidence = $null
                                    service = 'Graph'; scope = 'Target'; roles = @(); taskIds = @(); removesObjects = $false; path = "$($item['id']).ps1" }
                foreach ($key in $item.Keys) { $full[$key] = $item[$key] }
                $script:TcRemediationCatalog[$item['id']] = $full
            }
            $script:TcRemediationRoot = $Folder
        } $Entry $Work
    }

    function Invoke-TcSample {
        <# Runs a fixture on the fake project and snapshot. #>
        param([string]$Id, [switch]$Apply, [switch]$Acknowledge, [hashtable]$Setting = @{}, [string[]]$Tenant, $Snapshot = $FakeSnapshot)
        $parameters = @{ Id = $Id; Project = $script:Project; Snapshot = $Snapshot; Plan = $script:Plan; Setting = $Setting; AcknowledgeUntested = $Acknowledge; Apply = $Apply }
        if ($Tenant) { $parameters['Tenant'] = $Tenant }
        Invoke-TcRemediation @parameters
    }

    function Set-TcDecisionRow {
        <# Fills the Decision column of a proposals file. #>
        param([string]$Path, [string]$Decision)
        $rows = @(Import-Csv -LiteralPath $Path -Encoding utf8BOM)
        foreach ($row in $rows) { $row.Decision = $Decision }
        $rows | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8BOM
    }

    $script:Output = Join-Path $TestDrive 'output'
    $script:Project = New-TcSampleProject -Output $Output
    $script:Plan = New-TcPlan -Project $Project -Snapshot $FakeSnapshot
    $script:Domain = $FakeSnapshot['tenants']['Target']['primaryDomain']
    $script:SampleUser = @'
$rows = @(foreach ($t in $c.Tenants) { [ordered]@{ Tenant = $t; Account = 'one@example.test'; Proposal = 'Disable' } })
$decisions = @(Get-TcDecision -Name 'SAMPLE' -Proposal $rows -Key 'Tenant', 'Account' -Choice 'Disable', 'Keep')
foreach ($d in $decisions | Where-Object { $_.Decision -eq 'Disable' }) {
    Add-TcGraphAction -Tenant $d.Tenant -Method PATCH -Uri "v1.0/users/$($d.Account)" -Body @{ accountEnabled = $false } -Object $d.Account -Description "Disable $($d.Account)"
}
Invoke-TcRemediationPlan
'@
    $script:SampleRemove = @'
$rows = @(foreach ($t in $c.Tenants) { [ordered]@{ Tenant = $t; Account = 'one@example.test'; Proposal = 'Delete' } })
$decisions = @(Get-TcDecision -Name 'SAMPLE-REMOVE' -Proposal $rows -Key 'Tenant', 'Account' -Choice 'Delete', 'Keep')
foreach ($d in $decisions | Where-Object { $_.Decision -eq 'Delete' }) {
    Add-TcGraphAction -Tenant $d.Tenant -Method DELETE -Uri "v1.0/users/$($d.Account)" -Object $d.Account -Description "Delete $($d.Account)" -Undo $null -Reason 'A deleted account comes back only from the recycle bin.'
}
Invoke-TcRemediationPlan
'@
    [void](New-TcSampleScript -Id 'SAMPLE' -Body $SampleUser)
    [void](New-TcSampleScript -Id 'SAMPLE-REMOVE' -Body $SampleRemove)
    [void](New-TcSampleScript -Id 'STRICT' -Body '$missing = @{}; $missing.nothing; Invoke-TcRemediationPlan')
    [void](New-TcSampleScript -Id 'DIRECT-WRITE' -Body 'Invoke-TcGraph -Tenant Target -Method POST -Uri ''v1.0/groups'' -Body @{ displayName = ''x'' }; Invoke-TcRemediationPlan')
    [void](New-TcSampleScript -Id 'MANUAL' -Body 'Add-TcManualAction -Tenant Target -Object ''Portal'' -Description ''Do it by hand'' -Instruction ''Open the portal''; Invoke-TcRemediationPlan')
    function Reset-TcSampleCatalog { Set-TcSampleCatalog -Entry @(@{ id = 'SAMPLE' }, @{ id = 'SAMPLE-REMOVE'; removesObjects = $true }, @{ id = 'STRICT' }, @{ id = 'DIRECT-WRITE' }, @{ id = 'MANUAL'; nature = 'Partial' }) }
}

AfterAll {
    Remove-Module TenantConverge -Force -ErrorAction SilentlyContinue
}

Describe 'Running a remediation' {
    BeforeEach {
        Reset-TcStub
        Reset-TcSampleCatalog
        Get-ChildItem -LiteralPath $Output -Recurse -File -ErrorAction SilentlyContinue | Remove-Item -Force
    }

    Context 'Every run' {
        It 'shows the exact notice in preview' {
            [void](Invoke-TcSample -Id 'SAMPLE')
            (Get-TcStubRecord -Name Messages) -join "`n" | Should -BeLike "*$Notice*"
        }

        It 'shows the exact notice with -Apply' {
            Reset-TcStub -Answer 'UNTESTED', $Domain
            [void](Invoke-TcSample -Id 'SAMPLE' -Apply)
            (Get-TcStubRecord -Name Messages) -join "`n" | Should -BeLike "*$Notice*"
        }

        It 'refuses an identifier that is not in the manifest' {
            { Invoke-TcSample -Id 'NOPE' } | Should -Throw '*NOPE*'
        }

        It 'refuses a tenant that is not in the project' {
            { Invoke-TcSample -Id 'SAMPLE' -Tenant 'S3' } | Should -Throw '*S3*'
        }

        It 'keeps a run log, the plan and a summary in its own folder' {
            $result = Invoke-TcSample -Id 'SAMPLE'
            $result.Folder | Should -BeLike (Join-Path $Output 'remediations*SAMPLE-Preview*')
            foreach ($name in 'journal.log', 'plan.json', 'summary.json') { Join-Path $result.Folder $name | Should -Exist }
        }

        It 'runs the script under strict mode 3.0' {
            $result = Invoke-TcSample -Id 'STRICT'
            $result.Code | Should -Be 2
            $result.Error | Should -BeLike '*cannot be found*'
        }
    }

    Context 'Decisions' {
        It 'changes nothing with no decisions file, and says so' {
            $result = Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Actions | Should -Be 0
            (Get-TcStubRecord -Name Messages) -join "`n" | Should -BeLike '*No decisions file*'
        }

        It 'writes the proposals for a person, without a decision' {
            [void](Invoke-TcSample -Id 'SAMPLE')
            $rows = @(Import-Csv -LiteralPath (Join-Path $Output 'decisions/SAMPLE.csv') -Encoding utf8BOM)
            $rows.Count | Should -Be 1
            $rows[0].Proposal | Should -Be 'Disable'
            $rows[0].'Allowed values' | Should -Be 'Disable, Keep'
            $rows[0].Decision | Should -BeNullOrEmpty
        }

        It 'changes nothing with an empty file, and says so' {
            New-Item -ItemType Directory -Force -Path (Join-Path $Output 'decisions') | Out-Null
            Set-Content -LiteralPath (Join-Path $Output 'decisions/SAMPLE.csv') -Value '' -NoNewline
            $result = Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Actions | Should -Be 0
            (Get-TcStubRecord -Name Messages) -join "`n" | Should -BeLike '*empty*'
        }

        It 'acts on a decided row' {
            [void](Invoke-TcSample -Id 'SAMPLE')
            Set-TcDecisionRow -Path (Join-Path $Output 'decisions/SAMPLE.csv') -Decision 'Disable'
            Reset-TcStub -Answer $Domain
            $result = Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge
            $result.Applied | Should -Be 1
            @(Get-TcStubWrite).Count | Should -Be 1
        }

        It 'does not act on a value outside the allowed list' {
            [void](Invoke-TcSample -Id 'SAMPLE')
            Set-TcDecisionRow -Path (Join-Path $Output 'decisions/SAMPLE.csv') -Decision 'disable it please'
            $result = Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.PendingDecisions | Should -Be 1
        }

        It 'keeps what a person decided while the row stays the same' {
            [void](Invoke-TcSample -Id 'SAMPLE')
            Set-TcDecisionRow -Path (Join-Path $Output 'decisions/SAMPLE.csv') -Decision 'Keep'
            Reset-TcStub
            [void](Invoke-TcSample -Id 'SAMPLE')
            (Import-Csv -LiteralPath (Join-Path $Output 'decisions/SAMPLE.csv') -Encoding utf8BOM)[0].Decision | Should -Be 'Keep'
            (Get-TcStubRecord -Name Messages) -join "`n" | Should -Not -BeLike '*goes back to pending*'
        }

        Context 'A row that changed since its decision' {
            BeforeAll {
                $script:ChangeBody = @'
$choices = @(Get-TcRemediationOption 'UsualCountries')
$rows = @([ordered]@{ Tenant = 'Target'; Account = 'bob@s1.example'; 'Target UPN' = ('{0}@target.example' -f (Get-TcRemediationOption 'ObjectPrefix')); Created = (Get-TcRemediationOption 'TestSender'); Proposal = (Get-TcRemediationOption 'DnsServer') })
$decisions = @(Get-TcDecision -Name 'CHANGE' -Proposal $rows -Key 'Tenant', 'Account' -Choice (@('Create', 'Keep') + $choices))
foreach ($d in $decisions | Where-Object { $_.Decision -eq 'Create' }) { Add-TcGraphAction -Tenant $d.Tenant -Method POST -Uri 'v1.0/users' -Body @{ userPrincipalName = $d.'Target UPN' } -Object $d.Account -Description 'Create' }
Invoke-TcRemediationPlan
'@

                function Invoke-TcChange {
                    param([hashtable]$Setting = @{}, [switch]$Apply)
                    $values = @{ ObjectPrefix = 'bob'; UsualCountries = @('US'); TestSender = '2026-01-13 00:00'; DnsServer = '1.1.1.1' }
                    foreach ($key in $Setting.Keys) { $values[$key] = $Setting[$key] }
                    Invoke-TcSample -Id 'CHANGE' -Setting $values -Apply:$Apply -Acknowledge
                }

                function Read-TcChangeRow { (Import-Csv -LiteralPath (Join-Path $Output 'decisions/CHANGE.csv') -Encoding utf8BOM)[0] }

                function Set-TcChangeRow {
                    <# What a person leaves in the file: a decision, a name, a date and a note. #>
                    $path = Join-Path $Output 'decisions/CHANGE.csv'
                    $rows = @(Import-Csv -LiteralPath $path -Encoding utf8BOM)
                    foreach ($row in $rows) { $row.Decision = 'Create'; $row.'Decision maker' = 'Alice'; $row.Date = '2030-01-01'; $row.Note = 'Checked with the owner' }
                    $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8BOM
                }
            }

            BeforeEach {
                [void](New-TcSampleScript -Id 'CHANGE' -Body $ChangeBody)
                Set-TcSampleCatalog -Entry @(@{ id = 'CHANGE' })
                [void](Invoke-TcChange)
                Set-TcChangeRow
                Reset-TcStub -Answer $Domain
            }

            It 'goes back to pending, says what changed, and acts on nothing' {
                $result = Invoke-TcChange -Setting @{ ObjectPrefix = 'robert.b' } -Apply
                Get-TcStubWrite | Should -BeNullOrEmpty
                $result.PendingDecisions | Should -Be 1
                $row = Read-TcChangeRow
                $row.'Target UPN' | Should -Be 'robert.b@target.example'
                $row.Decision | Should -BeNullOrEmpty
                $row.'Decision maker' | Should -BeNullOrEmpty
                $row.Date | Should -BeNullOrEmpty
                $text = (Get-TcStubRecord -Name Messages) -join "`n"
                $text | Should -BeLike '*goes back to pending*'
                $text | Should -BeLike '*Target UPN*bob@target.example*robert.b@target.example*'
            }

            It 'keeps the note of the person' {
                [void](Invoke-TcChange -Setting @{ ObjectPrefix = 'robert.b' })
                (Read-TcChangeRow).Note | Should -Be 'Checked with the owner'
            }

            It 'goes back to pending when the proposal changes' {
                [void](Invoke-TcChange -Setting @{ DnsServer = '9.9.9.9' })
                (Read-TcChangeRow).Decision | Should -BeNullOrEmpty
                (Get-TcStubRecord -Name Messages) -join "`n" | Should -BeLike '*Proposal*'
            }

            It 'acts again once a person decides again' {
                [void](Invoke-TcChange -Setting @{ ObjectPrefix = 'robert.b' })
                Set-TcChangeRow
                Reset-TcStub -Answer $Domain
                (Invoke-TcChange -Setting @{ ObjectPrefix = 'robert.b' } -Apply).Applied | Should -Be 1
                @(Get-TcStubWrite)[0].Body['userPrincipalName'] | Should -Be 'robert.b@target.example'
            }

            It 'does not touch the decision when only the allowed values change' {
                [void](Invoke-TcChange -Setting @{ UsualCountries = @('US', 'CA') })
                (Read-TcChangeRow).Decision | Should -Be 'Create'
            }

            It 'does not take a date Excel rewrote for a change' {
                $path = Join-Path $Output 'decisions/CHANGE.csv'
                $rows = @(Import-Csv -LiteralPath $path -Encoding utf8BOM)
                foreach ($row in $rows) { $row.Created = '1/13/2026 0:00' }
                $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8BOM
                [void](Invoke-TcChange)
                (Read-TcChangeRow).Decision | Should -Be 'Create'
            }

            It 'does not go back to pending for a row nobody decided' {
                $path = Join-Path $Output 'decisions/CHANGE.csv'
                $rows = @(Import-Csv -LiteralPath $path -Encoding utf8BOM)
                foreach ($row in $rows) { $row.Decision = '' }
                $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8BOM
                [void](Invoke-TcChange -Setting @{ ObjectPrefix = 'robert.b' })
                (Get-TcStubRecord -Name Messages) -join "`n" | Should -Not -BeLike '*goes back to pending*'
                (Read-TcChangeRow).'Target UPN' | Should -Be 'robert.b@target.example'
            }
        }

        It 'stops on an unknown column and leaves the file alone' {
            [void](Invoke-TcSample -Id 'SAMPLE')
            $path = Join-Path $Output 'decisions/SAMPLE.csv'
            $rows = Import-Csv -LiteralPath $path -Encoding utf8BOM | Select-Object *, @{ Name = 'Surprise'; Expression = { 'x' } }
            foreach ($row in $rows) { $row.Decision = 'Disable' }
            $rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8BOM
            $before = Get-Content -LiteralPath $path -Raw
            $result = Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Code | Should -Be 2
            $result.Error | Should -BeLike '*Surprise*'
            Get-Content -LiteralPath $path -Raw | Should -Be $before
        }

        It 'stops on a file with no Decision column' {
            New-Item -ItemType Directory -Force -Path (Join-Path $Output 'decisions') | Out-Null
            Set-Content -LiteralPath (Join-Path $Output 'decisions/SAMPLE.csv') -Value "Tenant,Account`nTarget,one@example.test" -Encoding utf8BOM
            $result = Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Code | Should -Be 2
        }

        It 'does not act on a row with a cut key' {
            [void](Invoke-TcSample -Id 'SAMPLE')
            $path = Join-Path $Output 'decisions/SAMPLE.csv'
            $lines = @(Get-Content -LiteralPath $path -Encoding utf8BOM)
            Set-Content -LiteralPath $path -Value @($lines[0], '"Target","two@example.test","","","Disable"') -Encoding utf8BOM
            $result = Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Applied | Should -Be 0
        }

        It 'does not act on a key cell that starts with an equals sign' {
            [void](Invoke-TcSample -Id 'SAMPLE')
            $path = Join-Path $Output 'decisions/SAMPLE.csv'
            $text = (Get-Content -LiteralPath $path -Raw -Encoding utf8BOM).Replace('one@example.test', '=cmd|calc!A1')
            Set-Content -LiteralPath $path -Value $text -Encoding utf8BOM -NoNewline
            Set-TcDecisionRow -Path $path -Decision 'Disable'
            [void](Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge)
            Get-TcStubWrite | Should -BeNullOrEmpty
        }

        It 'does not act on a Decision cell that starts with an equals sign' {
            [void](Invoke-TcSample -Id 'SAMPLE')
            Set-TcDecisionRow -Path (Join-Path $Output 'decisions/SAMPLE.csv') -Decision '=Disable'
            [void](Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge)
            Get-TcStubWrite | Should -BeNullOrEmpty
        }

        It 'puts an apostrophe in front of a hostile value, and reads it back without it' {
            $body = @'
$rows = @([ordered]@{ Tenant = 'Target'; Account = '=SUM(1,2)'; Proposal = 'Disable' })
$decisions = @(Get-TcDecision -Name 'HOSTILE' -Proposal $rows -Key 'Tenant', 'Account' -Choice 'Disable', 'Keep')
foreach ($d in $decisions) { Add-TcGraphAction -Tenant $d.Tenant -Method PATCH -Uri 'v1.0/users/x' -Body @{ displayName = $d.Account } -Object 'x' -Description 'Set the name' }
Invoke-TcRemediationPlan
'@
            [void](New-TcSampleScript -Id 'HOSTILE' -Body $body)
            Set-TcSampleCatalog -Entry @(@{ id = 'SAMPLE' }, @{ id = 'HOSTILE' })
            [void](Invoke-TcSample -Id 'HOSTILE')
            $path = Join-Path $Output 'decisions/HOSTILE.csv'
            (Import-Csv -LiteralPath $path -Encoding utf8BOM)[0].Account | Should -Be "'=SUM(1,2)"
            Set-TcDecisionRow -Path $path -Decision 'Disable'
            Reset-TcStub -Answer $Domain
            [void](Invoke-TcSample -Id 'HOSTILE' -Apply -Acknowledge)
            (Get-TcStubRecord -Name Graph | Where-Object Method -EQ 'PATCH').Body['displayName'] | Should -Be '=SUM(1,2)'
        }
    }

    Context 'Confirmations' {
        BeforeEach {
            [void](Invoke-TcSample -Id 'SAMPLE')
            Set-TcDecisionRow -Path (Join-Path $Output 'decisions/SAMPLE.csv') -Decision 'Disable'
            [void](Invoke-TcSample -Id 'SAMPLE-REMOVE')
            Set-TcDecisionRow -Path (Join-Path $Output 'decisions/SAMPLE-REMOVE.csv') -Decision 'Delete'
        }

        It 'writes nothing without -Apply, even with every row decided' {
            Reset-TcStub
            $result = Invoke-TcSample -Id 'SAMPLE'
            Get-TcStubWrite | Should -BeNullOrEmpty
            Get-TcStubRecord -Name Connections | Should -BeNullOrEmpty
            Get-TcStubRecord -Name Prompts | Should -BeNullOrEmpty
            $result.Actions | Should -Be 1
            $result.Applied | Should -Be 0
        }

        It 'stops on a wrong domain' {
            Reset-TcStub -Answer 'wrong.example'
            $result = Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Code | Should -Be 3
            $result.Applied | Should -Be 0
        }

        It 'stops on an empty answer' {
            Reset-TcStub -Answer ''
            $result = Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Code | Should -Be 3
        }

        It 'accepts the domain in any case, with spaces around it' {
            Reset-TcStub -Answer " $($Domain.ToUpperInvariant()) "
            (Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge).Applied | Should -Be 1
        }

        It 'asks for the word UNTESTED, then the domain, without -AcknowledgeUntested' {
            Reset-TcStub -Answer 'UNTESTED', $Domain
            (Invoke-TcSample -Id 'SAMPLE' -Apply).Applied | Should -Be 1
            @(Get-TcStubRecord -Name Prompts).Count | Should -Be 2
        }

        It 'stops when the word UNTESTED is refused' {
            Reset-TcStub -Answer 'no', $Domain
            $result = Invoke-TcSample -Id 'SAMPLE' -Apply
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Code | Should -Be 3
        }

        Context 'a script that reads a tenant to build its plan' {
            BeforeEach {
                [void](New-TcSampleScript -Id 'READ-FIRST' -Body "[void](Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/organization')`nInvoke-TcRemediationPlan")
                Set-TcSampleCatalog -Entry @(@{ id = 'READ-FIRST' })
            }

            AfterEach { Reset-TcSampleCatalog }

            It 'opens no sign-in window when the word UNTESTED is refused' {
                Reset-TcStub -Answer 'no'
                $result = Invoke-TcSample -Id 'READ-FIRST' -Apply
                Get-TcStubRecord -Name Connections | Should -BeNullOrEmpty
                $result.Code | Should -Be 3
                (Get-TcStubRecord -Name Messages) -join "`n" | Should -BeLike "*$Notice*"
            }

            It 'asks for the word once, before the sign-in' {
                Reset-TcStub -Answer 'UNTESTED'
                (Invoke-TcSample -Id 'READ-FIRST' -Apply).Code | Should -Not -Be 2
                @(Get-TcStubRecord -Name Prompts | Where-Object { $_ -cmatch 'Type UNTESTED' }).Count | Should -Be 1
                @(Get-TcStubRecord -Name Connections).Count | Should -Be 1
            }

            It 'does not ask for the word with -AcknowledgeUntested' {
                Reset-TcStub
                [void](Invoke-TcSample -Id 'READ-FIRST' -Apply -Acknowledge)
                Get-TcStubRecord -Name Prompts | Should -BeNullOrEmpty
                @(Get-TcStubRecord -Name Connections).Count | Should -Be 1
            }
        }

        It 'still asks for the domain with -AcknowledgeUntested' {
            Reset-TcStub -Answer 'wrong.example'
            [void](Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge)
            Get-TcStubWrite | Should -BeNullOrEmpty
            @(Get-TcStubRecord -Name Prompts).Count | Should -Be 1
            @(Get-TcStubRecord -Name Prompts)[0] | Should -BeLike '*domain*'
        }

        It 'asks twice for a script that removes objects' {
            Reset-TcStub -Answer $Domain, 'REMOVE'
            (Invoke-TcSample -Id 'SAMPLE-REMOVE' -Apply -Acknowledge).Applied | Should -Be 1
            @(Get-TcStubRecord -Name Prompts).Count | Should -Be 2
        }

        It 'does not let -Apply alone through the second confirmation' {
            Reset-TcStub -Answer $Domain, ''
            $result = Invoke-TcSample -Id 'SAMPLE-REMOVE' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Code | Should -Be 3
        }

        It 'asks twice when an action removes an object, even in a script the manifest does not flag' {
            Set-TcSampleCatalog -Entry @(@{ id = 'SAMPLE' }, @{ id = 'SAMPLE-REMOVE'; removesObjects = $false })
            Reset-TcStub -Answer $Domain, 'nope'
            [void](Invoke-TcSample -Id 'SAMPLE-REMOVE' -Apply -Acknowledge)
            Get-TcStubWrite | Should -BeNullOrEmpty
        }

        It 'asks for nothing but the word UNTESTED when there is nothing to do' {
            Remove-Item -LiteralPath (Join-Path $Output 'decisions/SAMPLE.csv')
            Reset-TcStub -Answer 'UNTESTED'
            [void](Invoke-TcSample -Id 'SAMPLE' -Apply)
            @(Get-TcStubRecord -Name Prompts).Count | Should -Be 1
        }

        It 'refuses a write outside the plan, before any confirmation' {
            Reset-TcStub
            $result = Invoke-TcSample -Id 'DIRECT-WRITE' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Code | Should -Be 2
        }

        It 'connects with the permissions of the script, and nothing more' {
            Reset-TcStub -Answer $Domain
            [void](Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge)
            @(Get-TcStubRecord -Name Connections)[0].Scopes | Should -Be 'User.ReadWrite.All'
        }

        It 'refuses to write from a snapshot older than the limit' {
            $old = (Get-Module TenantConverge).Invoke({ param($s) ConvertTo-TcHashtable -InputObject $s }, $FakeSnapshot)
            $old['meta']['finished'] = (Get-Date).AddDays(-400).ToString('o')
            { Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge -Snapshot $old } | Should -Throw '*older*'
        }
    }

    Context 'The tenants a person confirmed' {
        BeforeAll {
            $script:S1Domain = $FakeSnapshot['tenants']['S1']['primaryDomain']

            function Set-TcCrossScript {
                <# A block planned on S1, whose code reaches for another tenant. #>
                param([string]$Call, [string]$Declare = '', [string]$Verify = '')
                $body = "Add-TcBlockAction -Tenant 'S1' -Service Graph -Object 'x' -Description 'Reaches for another tenant' $Declare -Block {`n    param(`$a)`n    $Call`n}`nInvoke-TcRemediationPlan$Verify"
                [void](New-TcSampleScript -Id 'CROSS' -Body $body)
                Set-TcSampleCatalog -Entry @(@{ id = 'CROSS'; nature = 'Partial'; scope = 'All' })
            }

            function Read-TcSampleJournal {
                <# The last line of the first action of a run. #>
                param([string]$Folder)
                @(Get-Content -LiteralPath (Join-Path $Folder 'operations.jsonl') -Encoding utf8 | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable -Depth 40 })[-1]
            }
        }

        It 'refuses a write to a tenant whose domain nobody typed, by <Path>, and names it' -ForEach @(
            @{ Path = 'Graph'; Call = 'Invoke-TcGraph -Tenant ''Target'' -Method DELETE -Uri ''v1.0/users/victim'' | Out-Null' }
            @{ Path = 'Exchange'; Call = 'Invoke-TcServiceCommand -Tenant ''Target'' -Service Exo -Command ''Set-Mailbox'' -Parameters @{ Identity = ''x'' } | Out-Null' }
            @{ Path = 'Purview'; Call = 'Invoke-TcServiceCommand -Tenant ''Target'' -Service Scc -Command ''Set-Label'' -Parameters @{ Identity = ''x'' } | Out-Null' }
            @{ Path = 'Teams'; Call = 'Invoke-TcServiceCommand -Tenant ''Target'' -Service Teams -Command ''Set-CsTeamsMeetingPolicy'' -Parameters @{ Identity = ''x'' } | Out-Null' }
            @{ Path = 'PnP'; Call = 'Invoke-TcServiceCommand -Tenant ''Target'' -Service Pnp -Command ''Set-PnPTenant'' -Parameters @{ SharingCapability = ''x'' } | Out-Null' }
            @{ Path = 'Cloudflare'; Call = 'Set-TcCloudflareRecord -Tenant ''Target'' -Zone ''zone.test'' -Name ''zone.test'' -Type TXT -Value ''x'' -Ttl 300 -Priority 0 -Action Add' }
            @{ Path = 'a Cloudflare TTL'; Call = 'Set-TcCloudflareTtl -Tenant ''Target'' -Zone ''zone.test'' -Name ''zone.test'' -Type MX -Ttl 300' }
            @{ Path = 'a DNS record at a manual host'; Call = 'Invoke-TcDnsAction @{ id = ''x''; tenant = ''Target''; dns = [ordered]@{ zone = ''zone.test''; name = ''zone.test''; type = ''TXT''; value = ''x''; ttl = 300; priority = 0; action = ''Add''; wait = $false } }' }
        ) {
            Set-TcCrossScript -Call $Call
            Reset-TcStub -Answer $S1Domain
            $result = Invoke-TcSample -Id 'CROSS' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            (Get-TcStubRecord -Name Messages) -join "`n" | Should -Not -BeLike '*To do at*'
            $result.Failed | Should -Be 1
            (Read-TcSampleJournal -Folder $result.Folder)['error'] | Should -BeLike '*Write refused on Target*'
        }

        It 'refuses the same write from a -Test' {
            [void](New-TcSampleScript -Id 'CROSS' -Body "Add-TcGraphAction -Tenant 'S1' -Method PATCH -Uri 'v1.0/users/x' -Body @{ a = 1 } -Object 'x' -Description 'Change' -Test { param(`$a) Invoke-TcGraph -Tenant 'Target' -Method DELETE -Uri 'v1.0/users/victim' }`nInvoke-TcRemediationPlan")
            Set-TcSampleCatalog -Entry @(@{ id = 'CROSS'; scope = 'All' })
            Reset-TcStub -Answer $S1Domain
            [void](Invoke-TcSample -Id 'CROSS' -Apply -Acknowledge)
            @(Get-TcStubRecord -Name Graph | Where-Object Url -Like '*victim*') | Should -BeNullOrEmpty
        }

        It 'refuses the same write from a -Verify' {
            Set-TcCrossScript -Call '$null = $a' -Verify " -Verify { param(`$t) Invoke-TcGraph -Tenant 'Target' -Method DELETE -Uri 'v1.0/users/victim' }"
            Reset-TcStub -Answer $S1Domain
            $result = Invoke-TcSample -Id 'CROSS' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Code | Should -Be 2
        }

        It 'refuses the same write from a -WaitUntil' {
            [void](New-TcSampleScript -Id 'CROSS' -Body "Add-TcManualAction -Tenant 'S1' -Object 'x' -Description 'Wait' -Instruction 'Wait' -Minutes 1 -IntervalSeconds 1 -WaitUntil { param(`$a) Invoke-TcGraph -Tenant 'Target' -Method DELETE -Uri 'v1.0/users/victim'; `$true }`nInvoke-TcRemediationPlan")
            Set-TcSampleCatalog -Entry @(@{ id = 'CROSS'; nature = 'Partial'; scope = 'All' })
            Reset-TcStub -Answer $S1Domain
            [void](Invoke-TcSample -Id 'CROSS' -Apply -Acknowledge)
            Get-TcStubWrite | Should -BeNullOrEmpty
        }

        It 'still reads a tenant nobody confirmed' {
            Set-TcCrossScript -Call 'Invoke-TcGraph -Tenant ''Target'' -Uri ''v1.0/users'' | Out-Null'
            Reset-TcStub -Answer $S1Domain
            $result = Invoke-TcSample -Id 'CROSS' -Apply -Acknowledge
            $result.Failed | Should -Be 0
            @(Get-TcStubRecord -Name Connections | Where-Object Tenant -EQ 'Target').Count | Should -Be 1
        }

        It 'asks the second domain before the first write, for a tenant the action declares' {
            Set-TcCrossScript -Declare '-AlsoWrites ''Target''' -Call 'Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri ''v1.0/users/one'' -Body @{ a = 1 } | Out-Null; Invoke-TcGraph -Tenant $a.alsoWrites[0] -Method DELETE -Uri ''v1.0/users/two'' | Out-Null'
            Reset-TcStub -Answer $S1Domain, 'wrong.example'
            $result = Invoke-TcSample -Id 'CROSS' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Code | Should -Be 3
            (Get-TcStubRecord -Name Prompts) -join "`n" | Should -BeLike '*(Target)*'
        }

        It 'writes to both tenants once both domains are typed' {
            Set-TcCrossScript -Declare '-AlsoWrites ''Target''' -Call 'Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri ''v1.0/users/one'' -Body @{ a = 1 } | Out-Null; Invoke-TcGraph -Tenant $a.alsoWrites[0] -Method DELETE -Uri ''v1.0/users/two'' | Out-Null'
            Reset-TcStub -Answer $S1Domain, $Domain
            (Invoke-TcSample -Id 'CROSS' -Apply -Acknowledge).Applied | Should -Be 1
            @(Get-TcStubWrite).Count | Should -Be 2
        }

        It 'refuses a declared tenant the project does not have' {
            Set-TcCrossScript -Declare '-AlsoWrites ''S9''' -Call '$null = $a'
            (Invoke-TcSample -Id 'CROSS').Error | Should -BeLike '*S9*'
        }

        It 'shows the declared tenant in the preview and in plan.csv' {
            Set-TcCrossScript -Declare '-AlsoWrites ''Target''' -Call '$null = $a'
            $result = Invoke-TcSample -Id 'CROSS'
            (Get-TcStubRecord -Name Messages) -join "`n" | Should -Match 'Target: 1 action'
            (Import-Csv -LiteralPath (Join-Path $result.Folder 'plan.csv') -Encoding utf8BOM)[0].'Also writes' | Should -Be 'Target'
        }

        It 'records in the journal the tenants really written to' {
            Set-TcCrossScript -Declare '-AlsoWrites ''Target''' -Call 'Invoke-TcGraph -Tenant $a.alsoWrites[0] -Method DELETE -Uri ''v1.0/users/two'' | Out-Null'
            Reset-TcStub -Answer $S1Domain, $Domain
            $result = Invoke-TcSample -Id 'CROSS' -Apply -Acknowledge
            $line = Read-TcSampleJournal -Folder $result.Folder
            $line['tenant'] | Should -Be 'S1'
            @($line['written']) | Should -Be @('Target')
        }

        It 'asks undo for the tenant the undo writes to, named by the block' {
            Set-TcCrossScript -Declare '-AlsoWrites ''Target''' -Call '$a.undo = @{ type = ''Graph''; tenant = $a.alsoWrites[0]; method = ''PATCH''; uri = ''v1.0/users/two''; body = @{ a = 0 } }; Invoke-TcGraph -Tenant $a.alsoWrites[0] -Method PATCH -Uri ''v1.0/users/two'' -Body @{ a = 1 } | Out-Null'
            Reset-TcStub -Answer $S1Domain, $Domain
            $result = Invoke-TcSample -Id 'CROSS' -Apply -Acknowledge
            Reset-TcStub -Answer $Domain
            (Undo-TcRemediation -Path $result.Folder -Project $Project -Apply -AcknowledgeUntested).Undone | Should -Be 1
            @(Get-TcStubRecord -Name Prompts).Count | Should -Be 1
            @(Get-TcStubRecord -Name Prompts)[0] | Should -BeLike '*(Target)*'
        }

        It 'asks undo for the tenant in the journal when the undo names none' {
            Set-TcCrossScript -Declare '-AlsoWrites ''Target''' -Call '$a.undo = @{ type = ''Graph''; method = ''PATCH''; uri = ''v1.0/users/two''; body = @{ a = 0 } }; Invoke-TcGraph -Tenant $a.alsoWrites[0] -Method PATCH -Uri ''v1.0/users/two'' -Body @{ a = 1 } | Out-Null'
            Reset-TcStub -Answer $S1Domain, $Domain
            $result = Invoke-TcSample -Id 'CROSS' -Apply -Acknowledge
            Reset-TcStub -Answer $Domain
            (Undo-TcRemediation -Path $result.Folder -Project $Project -Apply -AcknowledgeUntested).Undone | Should -Be 1
            @(Get-TcStubRecord -Name Prompts)[0] | Should -BeLike '*(Target)*'
            @(Get-TcStubRecord -Name Connections)[-1].Tenant | Should -Be 'Target'
        }
    }

    Context 'Undoing a DNS change' {
        BeforeAll {
            # A small Cloudflare zone, and the public DNS that shows it.
            $script:CloudAnswer = {
                param($Method, $Path, $Body)
                if ($Path -like 'zones?name=*') { return [pscustomobject]@{ result = @([pscustomobject]@{ id = 'zone-1' }) } }
                if ($Method -eq 'GET') { return [pscustomobject]@{ result = @($Cloud | ForEach-Object { [pscustomobject]$_ }) } }
                $id = ($Path -split '/')[-1]
                if ($Method -eq 'POST') { $Cloud.Add(@{ id = "new-$($Cloud.Count)"; type = $Body['type']; name = $Body['name']; content = $Body['content']; ttl = $Body['ttl']; priority = $Body['priority'] }) }
                $found = @($Cloud | Where-Object { $_['id'] -eq $id })
                if ($Method -eq 'DELETE') { foreach ($item in $found) { [void]$Cloud.Remove($item) } }
                if ($Method -eq 'PUT') { foreach ($item in $found) { $item['content'] = $Body['content']; $item['ttl'] = $Body['ttl'] } }
                [pscustomobject]@{ result = @() }
            }
            $script:PublicAnswer = {
                param($Name, $Type)
                foreach ($item in $Cloud) {
                    switch ($Type) {
                        'MX' { [pscustomobject]@{ Type = 'MX'; NameExchange = $item['content']; TTL = $item['ttl']; Preference = $item['priority'] } }
                        'TXT' { [pscustomobject]@{ Type = 'TXT'; Strings = @($item['content']); TTL = $item['ttl'] } }
                        'CNAME' { [pscustomobject]@{ Type = 'CNAME'; NameHost = $item['content']; TTL = $item['ttl'] } }
                    }
                }
            }

            function Invoke-TcDnsRoundTrip {
                <# Applies one DNS action on the small zone, then undoes it. #>
                param([string]$Action, [string]$Answer = 'REMOVE')
                $settings = Join-Path $Output 'decisions'
                New-Item -ItemType Directory -Force -Path $settings | Out-Null
                '{ "DnsHosts": { "zone.test": "Cloudflare" } }' | Set-Content -LiteralPath (Join-Path $settings 'settings.json') -Encoding utf8
                [void](New-TcSampleScript -Id 'DNS' -Body "$Action`nInvoke-TcRemediationPlan")
                Set-TcSampleCatalog -Entry @(@{ id = 'DNS'; service = 'Dns'; nature = 'Partial' })
                Reset-TcStub -Answer $Domain, 'REMOVE' -DnsAnswer $PublicAnswer -CloudflareAnswer $CloudAnswer
                $applied = Invoke-TcSample -Id 'DNS' -Apply -Acknowledge
                $applied.Applied | Should -Be 1
                Reset-TcStub -Answer $Domain, $Answer -DnsAnswer $PublicAnswer -CloudflareAnswer $CloudAnswer
                Undo-TcRemediation -Path $applied.Folder -Project $Project -Apply -AcknowledgeUntested
            }
        }

        BeforeEach { $script:Cloud = [System.Collections.Generic.List[object]]::new() }
        AfterEach { Remove-Item -LiteralPath (Join-Path $Output 'decisions/settings.json') -ErrorAction SilentlyContinue }

        It 'keeps two MX records two' {
            $Cloud.Add(@{ id = 'a'; type = 'MX'; name = 'zone.test'; content = 'mx-one.zone.test'; ttl = 3600; priority = 10 })
            $Cloud.Add(@{ id = 'b'; type = 'MX'; name = 'zone.test'; content = 'mx-two.zone.test'; ttl = 3600; priority = 20 })
            $result = Invoke-TcDnsRoundTrip -Action 'Add-TcDnsAction -Tenant Target -Zone zone.test -Name zone.test -Type MX -Ttl 300 -Action TTL -Description ''Lower the TTL'''
            $result.Undone | Should -Be 1
            @($Cloud | ForEach-Object { $_['content'] } | Sort-Object) | Should -Be @('mx-one.zone.test', 'mx-two.zone.test')
            @($Cloud | Where-Object { $_['ttl'] -ne 3600 }) | Should -BeNullOrEmpty
        }

        It 'leaves the other TXT of a name alone when it puts an SPF back' {
            $Cloud.Add(@{ id = 'a'; type = 'TXT'; name = 'zone.test'; content = 'verification=abc'; ttl = 3600 })
            $Cloud.Add(@{ id = 'b'; type = 'TXT'; name = 'zone.test'; content = 'v=spf1 -all'; ttl = 3600 })
            [void](Invoke-TcDnsRoundTrip -Action 'Add-TcDnsAction -Tenant Target -Zone zone.test -Name zone.test -Type TXT -Value ''v=spf1 include:mail.test -all'' -Action Set -NoWait -Description ''Set the SPF''')
            @($Cloud | ForEach-Object { $_['content'] } | Sort-Object) | Should -Be @('v=spf1 -all', 'verification=abc')
        }

        It 'removes what an Add published, and nothing else, after the word REMOVE' {
            $Cloud.Add(@{ id = 'a'; type = 'TXT'; name = 'zone.test'; content = 'v=spf1 -all'; ttl = 3600 })
            [void](Invoke-TcDnsRoundTrip -Action 'Add-TcDnsAction -Tenant Target -Zone zone.test -Name zone.test -Type TXT -Value ''test=1'' -Action Add -NoWait -Description ''Add a TXT''')
            @($Cloud | ForEach-Object { $_['content'] }) | Should -Be @('v=spf1 -all')
            (Get-TcStubRecord -Name Prompts) -join "`n" | Should -BeLike '*Type REMOVE*'
        }

        It 'publishes again what a Remove took away' {
            $Cloud.Add(@{ id = 'a'; type = 'TXT'; name = 'zone.test'; content = 'old=1'; ttl = 3600 })
            [void](Invoke-TcDnsRoundTrip -Action 'Add-TcDnsAction -Tenant Target -Zone zone.test -Name zone.test -Type TXT -Value ''old=1'' -Action Remove -NoWait -Description ''Remove a TXT''')
            @($Cloud | ForEach-Object { $_['content'] }) | Should -Be @('old=1')
        }

        It 'puts a CNAME back over the one that replaced it' {
            $Cloud.Add(@{ id = 'a'; type = 'CNAME'; name = 'zone.test'; content = 'old.zone.test'; ttl = 3600 })
            [void](Invoke-TcDnsRoundTrip -Action 'Add-TcDnsAction -Tenant Target -Zone zone.test -Name zone.test -Type CNAME -Value ''new.zone.test'' -Action Set -NoWait -Description ''Set the CNAME''')
            @($Cloud | ForEach-Object { $_['content'] }) | Should -Be @('old.zone.test')
        }

        It 'removes nothing when the read before a Set found nothing' {
            [void](New-TcSampleScript -Id 'DNS' -Body 'x')
            $Cloud.Add(@{ id = 'a'; type = 'TXT'; name = 'zone.test'; content = 'v=spf1 new -all'; ttl = 3600 })
            $journal = Join-Path $TestDrive 'dns-run'
            New-Item -ItemType Directory -Force -Path $journal | Out-Null
            @{ id = 'A-0001'; tenant = 'Target'; type = 'Dns'; status = 'Applied'; description = 'Set the SPF'; timestamp = (Get-Date).ToString('o'); undo = @{ type = 'Dns'; tenant = 'Target'; dns = @{ zone = 'zone.test'; name = 'zone.test'; type = 'TXT'; value = 'v=spf1 new -all'; action = 'Set' }; before = @() } } | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath (Join-Path $journal 'operations.jsonl') -Encoding utf8
            New-Item -ItemType Directory -Force -Path (Join-Path $Output 'decisions') | Out-Null
            '{ "DnsHosts": { "zone.test": "Cloudflare" } }' | Set-Content -LiteralPath (Join-Path $Output 'decisions/settings.json') -Encoding utf8
            Reset-TcStub -Answer $Domain -DnsAnswer $PublicAnswer -CloudflareAnswer $CloudAnswer
            [void](Undo-TcRemediation -Path $journal -Project $Project -Apply -AcknowledgeUntested)
            @($Cloud | ForEach-Object { $_['content'] }) | Should -Be @('v=spf1 new -all')
        }

        It 'tells a person each record to restore, and the one to remove, at a host with no API' {
            $journal = Join-Path $TestDrive 'dns-manual-run'
            New-Item -ItemType Directory -Force -Path $journal | Out-Null
            @{ id = 'A-0001'; tenant = 'Target'; type = 'Dns'; status = 'Applied'; description = 'Set the SPF'; timestamp = (Get-Date).ToString('o'); undo = @{ type = 'Dns'; tenant = 'Target'; dns = @{ zone = 'manual.test'; name = 'manual.test'; type = 'TXT'; value = 'new=1'; action = 'Set' }; before = @(@{ value = 'old=1'; ttl = 300 }) } } | ConvertTo-Json -Depth 10 -Compress | Set-Content -LiteralPath (Join-Path $journal 'operations.jsonl') -Encoding utf8
            Reset-TcStub -Answer $Domain, 'REMOVE'
            [void](Undo-TcRemediation -Path $journal -Project $Project -Apply -AcknowledgeUntested)
            $text = (Get-TcStubRecord -Name Messages) -join "`n"
            $text | Should -BeLike '*To restore at Manual: TXT manual.test = old=1*'
            $text | Should -BeLike '*To remove at Manual: TXT manual.test = new=1*'
        }
    }

    Context 'The plan' {
        It 'stops the plan after a critical failure and keeps going after a plain one' {
            $body = @'
Add-TcGraphAction -Tenant Target -Method PATCH -Uri 'v1.0/fail/1' -Body @{ a = 1 } -Object 'one' -Description 'One'
Add-TcGraphAction -Tenant Target -Method PATCH -Uri 'v1.0/ok/2' -Body @{ a = 1 } -Object 'two' -Description 'Two'
Add-TcGraphAction -Tenant Target -Method PATCH -Uri 'v1.0/fail/3' -Body @{ a = 1 } -Object 'three' -Description 'Three' -Critical
Add-TcGraphAction -Tenant Target -Method PATCH -Uri 'v1.0/ok/4' -Body @{ a = 1 } -Object 'four' -Description 'Four'
Invoke-TcRemediationPlan
'@
            [void](New-TcSampleScript -Id 'CRITICAL' -Body $body)
            Set-TcSampleCatalog -Entry @(@{ id = 'SAMPLE' }, @{ id = 'CRITICAL' })
            Reset-TcStub -Answer $Domain -FailGraph 'fail'
            $result = Invoke-TcSample -Id 'CRITICAL' -Apply -Acknowledge
            $result.Failed | Should -Be 2
            $result.Applied | Should -Be 1
            $result.Code | Should -Be 2
            @(Get-TcStubRecord -Name Graph | Where-Object Url -Like '*ok/4*').Count | Should -Be 0
        }

        It 'skips what its test finds already in place' {
            $body = @'
Add-TcGraphAction -Tenant Target -Method PATCH -Uri 'v1.0/users/x' -Body @{ a = 1 } -Object 'x' -Description 'Change' -Test { param($a) $a.tenant -eq 'Target' }
Invoke-TcRemediationPlan
'@
            [void](New-TcSampleScript -Id 'INPLACE' -Body $body)
            Set-TcSampleCatalog -Entry @(@{ id = 'SAMPLE' }, @{ id = 'INPLACE' })
            Reset-TcStub -Answer $Domain
            $result = Invoke-TcSample -Id 'INPLACE' -Apply -Acknowledge
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.AlreadyInPlace | Should -Be 1
        }

        It 'reports what a person has to do' {
            Reset-TcStub -Answer $Domain
            $result = Invoke-TcSample -Id 'MANUAL' -Apply -Acknowledge
            $result.ForAPerson | Should -Be 1
            $result.Code | Should -Be 1
        }

        It 'masks a password in the journal of operations' {
            $body = @'
Add-TcGraphAction -Tenant Target -Method POST -Uri 'v1.0/users' -Body @{ displayName = 'x'; passwordProfile = @{ password = 'S3cret-Value!' } } -Object 'x' -Description 'Create'
Invoke-TcRemediationPlan
'@
            [void](New-TcSampleScript -Id 'SECRET' -Body $body)
            Set-TcSampleCatalog -Entry @(@{ id = 'SAMPLE' }, @{ id = 'SECRET' })
            Reset-TcStub -Answer $Domain
            $result = Invoke-TcSample -Id 'SECRET' -Apply -Acknowledge
            (Get-Content -LiteralPath (Join-Path $result.Folder 'operations.jsonl') -Raw) | Should -Not -BeLike '*S3cret-Value*'
            (Get-Content -LiteralPath (Join-Path $result.Folder 'plan.json') -Raw) | Should -Not -BeLike '*S3cret-Value*'
        }
    }

    Context 'Undo' {
        BeforeEach {
            [void](Invoke-TcSample -Id 'SAMPLE')
            Set-TcDecisionRow -Path (Join-Path $Output 'decisions/SAMPLE.csv') -Decision 'Disable'
            Reset-TcStub -Answer $Domain
            $script:Applied = Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge
        }

        It 'only shows what it would undo, by default' {
            Reset-TcStub
            $result = Undo-TcRemediation -Path $Applied.Folder -Project $Project
            Get-TcStubWrite | Should -BeNullOrEmpty
            Get-TcStubRecord -Name Connections | Should -BeNullOrEmpty
            $result.Undoable | Should -Be 1
            (Get-TcStubRecord -Name Messages) -join "`n" | Should -BeLike "*$Notice*"
        }

        It 'puts back the values read before the change' {
            Reset-TcStub -Answer $Domain
            $result = Undo-TcRemediation -Path $Applied.Folder -Project $Project -Apply -AcknowledgeUntested
            $result.Undone | Should -Be 1
            $write = @(Get-TcStubWrite)
            $write.Count | Should -Be 1
            $write[0].Method | Should -Be 'PATCH'
            $write[0].Body.Keys | Should -Contain 'accountEnabled'
        }

        It 'stops on a wrong domain' {
            Reset-TcStub -Answer 'wrong.example'
            $result = Undo-TcRemediation -Path $Applied.Folder -Project $Project -Apply -AcknowledgeUntested
            Get-TcStubWrite | Should -BeNullOrEmpty
            $result.Code | Should -Be 3
        }

        It 'lists an operation that has no way back, with its reason' {
            [void](Invoke-TcSample -Id 'SAMPLE-REMOVE')
            Set-TcDecisionRow -Path (Join-Path $Output 'decisions/SAMPLE-REMOVE.csv') -Decision 'Delete'
            Reset-TcStub -Answer $Domain, 'REMOVE'
            $removed = Invoke-TcSample -Id 'SAMPLE-REMOVE' -Apply -Acknowledge
            Reset-TcStub
            $result = Undo-TcRemediation -Path $removed.Folder -Project $Project
            $result.NoWayBack | Should -Be 1
            (Get-TcStubRecord -Name Messages) -join "`n" | Should -BeLike '*recycle bin*'
        }

        It 'finds nothing to do the second time' {
            Reset-TcStub -Answer $Domain
            (Undo-TcRemediation -Path $Applied.Folder -Project $Project -Apply -AcknowledgeUntested).Undone | Should -Be 1
            Reset-TcStub -Answer $Domain
            $again = Undo-TcRemediation -Path $Applied.Folder -Project $Project -Apply -AcknowledgeUntested
            $again.Undoable | Should -Be 0
            $again.Undone | Should -Be 0
            Get-TcStubWrite | Should -BeNullOrEmpty
            Get-TcStubRecord -Name Prompts | Should -BeNullOrEmpty
        }

        It 'marks what it undid in the journal of the run' {
            Reset-TcStub -Answer $Domain
            [void](Undo-TcRemediation -Path $Applied.Folder -Project $Project -Apply -AcknowledgeUntested)
            (Get-Content -LiteralPath (Join-Path $Applied.Folder 'operations.jsonl') -Encoding utf8)[-1] | ConvertFrom-Json -AsHashtable | ForEach-Object { $_['status'] } | Should -Be 'Undone'
        }

        It 'keeps a journal and a summary of its own' {
            Reset-TcStub -Answer $Domain
            $undone = Undo-TcRemediation -Path $Applied.Folder -Project $Project -Apply -AcknowledgeUntested
            $undone.Run | Should -Not -BeNullOrEmpty
            $undone.Run | Should -Not -Be $Applied.Folder
            @(Get-Content -LiteralPath (Join-Path $undone.Run 'operations.jsonl') -Encoding utf8).Count | Should -BeGreaterThan 0
            (Get-Content -LiteralPath (Join-Path $undone.Run 'summary.json') -Raw | ConvertFrom-Json).undone | Should -Be 1
        }

        It 'offers nothing to undo in the journal of an undo' {
            Reset-TcStub -Answer $Domain
            $undone = Undo-TcRemediation -Path $Applied.Folder -Project $Project -Apply -AcknowledgeUntested
            Reset-TcStub
            (Undo-TcRemediation -Path $undone.Run -Project $Project).Undoable | Should -Be 0
        }

        It 'writes nothing to the journal in a preview, or when it is not confirmed' {
            $before = Get-Content -LiteralPath (Join-Path $Applied.Folder 'operations.jsonl') -Raw
            Reset-TcStub
            [void](Undo-TcRemediation -Path $Applied.Folder -Project $Project)
            Reset-TcStub -Answer 'wrong.example'
            [void](Undo-TcRemediation -Path $Applied.Folder -Project $Project -Apply -AcknowledgeUntested)
            Get-Content -LiteralPath (Join-Path $Applied.Folder 'operations.jsonl') -Raw | Should -Be $before
        }

        It 'keeps a failed undo to do' {
            Reset-TcStub -Answer $Domain -FailGraph 'users'
            (Undo-TcRemediation -Path $Applied.Folder -Project $Project -Apply -AcknowledgeUntested).Failed | Should -Be 1
            Reset-TcStub
            (Undo-TcRemediation -Path $Applied.Folder -Project $Project).Undoable | Should -Be 1
        }

        It 'lists a line left at <Status> as status unknown, and does not replay it' -ForEach @(
            @{ Status = 'Running' }, @{ Status = 'Undoing' }
        ) {
            $journal = Join-Path $Applied.Folder 'operations.jsonl'
            $line = @(Get-Content -LiteralPath $journal -Encoding utf8)[-1] | ConvertFrom-Json -AsHashtable -Depth 40
            $line['id'] = 'A-0099'; $line['status'] = $Status; $line['description'] = 'Cut short'
            Add-Content -LiteralPath $journal -Value ($line | ConvertTo-Json -Depth 30 -Compress) -Encoding utf8
            Reset-TcStub -Answer $Domain
            $result = Undo-TcRemediation -Path $Applied.Folder -Project $Project -Apply -AcknowledgeUntested
            $result.Undone | Should -Be 1
            $result.NoWayBack | Should -Be 1
            (Get-TcStubRecord -Name Messages) -join "`n" | Should -BeLike '*Cut short: status unknown, check the tenant*'
        }

        It 'asks REMOVE for an undo that deletes what the run created' {
            [void](New-TcSampleScript -Id 'CREATE' -Body "Add-TcGraphAction -Tenant 'Target' -Method POST -Uri 'v1.0/groups' -Body @{ displayName = 'x' } -Object 'x' -Description 'Create'`nInvoke-TcRemediationPlan")
            Set-TcSampleCatalog -Entry @(@{ id = 'CREATE' })
            Reset-TcStub -Answer $Domain
            $created = Invoke-TcSample -Id 'CREATE' -Apply -Acknowledge
            Reset-TcStub -Answer $Domain, ''
            $refused = Undo-TcRemediation -Path $created.Folder -Project $Project -Apply -AcknowledgeUntested
            Get-TcStubWrite | Should -BeNullOrEmpty
            $refused.Code | Should -Be 3
            Reset-TcStub -Answer $Domain, 'REMOVE'
            (Undo-TcRemediation -Path $created.Folder -Project $Project -Apply -AcknowledgeUntested).Undone | Should -Be 1
            @(Get-TcStubWrite)[0].Method | Should -Be 'DELETE'
        }

        It 'does not ask REMOVE for an undo that deletes nothing' {
            Reset-TcStub -Answer $Domain
            [void](Undo-TcRemediation -Path $Applied.Folder -Project $Project -Apply -AcknowledgeUntested)
            @(Get-TcStubRecord -Name Prompts).Count | Should -Be 1
        }

        It 'refuses a folder that holds several runs, and lists them' {
            Reset-TcStub -Answer $Domain
            $second = Invoke-TcSample -Id 'SAMPLE' -Apply -Acknowledge
            Reset-TcStub -Answer $Domain
            $folder = Join-Path $Output 'remediations'
            $thrown = { Undo-TcRemediation -Path $folder -Project $Project -Apply -AcknowledgeUntested } | Should -Throw -PassThru
            $thrown.Exception.Message | Should -BeLike "*$(Split-Path -Leaf $Applied.Folder)*"
            $thrown.Exception.Message | Should -BeLike "*$(Split-Path -Leaf $second.Folder)*"
            Get-TcStubWrite | Should -BeNullOrEmpty
            Get-TcStubRecord -Name Prompts | Should -BeNullOrEmpty
        }

        It 'refuses a folder above a single run too' {
            $parent = Join-Path $TestDrive 'parent'
            New-Item -ItemType Directory -Force -Path (Join-Path $parent 'one') | Out-Null
            Copy-Item -LiteralPath (Join-Path $Applied.Folder 'operations.jsonl') -Destination (Join-Path $parent 'one/operations.jsonl')
            { Undo-TcRemediation -Path $parent -Project $Project } | Should -Throw '*one run folder*'
        }

        It 'says so when a folder holds no operation' {
            $folder = Join-Path $TestDrive 'empty-run'
            New-Item -ItemType Directory -Force -Path $folder | Out-Null
            (Undo-TcRemediation -Path $folder -Project $Project).Undoable | Should -Be 0
        }
    }
}

BeforeAll {
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:FakeSnapshot = & (Join-Path $Root 'tools/New-TcFakeSnapshot.ps1') -SourceCount 2 -Seed 3
    Import-Module (Join-Path $Root 'src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RemediationStubs.ps1')
    . (Join-Path $PSScriptRoot 'Support/RemediationBench.ps1')
    Install-TcRemediationStub -Mode Empty

    $script:Output = Join-Path $TestDrive 'output'
    $script:Project = New-TcBenchProject -Snapshot $FakeSnapshot -Output $Output
    $script:Plan = New-TcPlan -Project $Project -Snapshot $FakeSnapshot
    $script:DecisionFolder = Join-Path $Output 'decisions'
    New-Item -ItemType Directory -Force -Path $DecisionFolder | Out-Null

    # Prepares the run a script would see, without a script.
    $module = Get-Module TenantConverge
    & $module {
        param($Project, $Snapshot, $Plan)
        $entry = Get-TcRemediationEntry -Id 'ENT-INACTIVE'
        $script:TcRemediationRun = New-TcRemediationRun -Entry $entry -Project $Project -Snapshot $Snapshot -Plan $Plan -Apply $false -Acknowledged $false -Setting @{ SourceGroups = @{ S1 = @(@{ name = 'Finance' }) } } -Output (Get-TcProperty (Get-TcProperty $Project 'output') 'path')
    } $Project $FakeSnapshot $Plan
    $script:Run = $module
}

Describe 'Get-TcRemediation' {
    It 'lists all the scripts' {
        @(Get-TcRemediation).Count | Should -Be 111
    }

    It 'finds one by its identifier and keeps the contract' {
        $entry = Get-TcRemediation -Id 'ENT-MFA'
        $entry.id | Should -Be 'ENT-MFA'
        $entry.nature | Should -Be 'Decision'
        $entry.testedOnRealTenant | Should -BeFalse
    }

    It 'filters by workload and by nature' {
        $phone = @(Get-TcRemediation -Workload 'Teams Phone')
        $phone.Count | Should -BeGreaterThan 3
        @($phone | Where-Object workload -NE 'Teams Phone') | Should -BeNullOrEmpty
        @(Get-TcRemediation -Nature Automated).Count | Should -Be 3
    }

    It 'gives nothing for an unknown identifier' {
        @(Get-TcRemediation -Id 'NOT-A-SCRIPT' -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
    }
}

Describe 'Reads that strict mode would stop on' {
    It 'reads a member of a dictionary and of an object, whatever the case of the object' {
        & $Run { Get-TcMember @{ a = 1 } 'a' } | Should -Be 1
        & $Run { Get-TcMember ([pscustomobject]@{ a = 2 }) 'a' } | Should -Be 2
    }

    It 'gives nothing for a missing member or for $null' {
        @(& $Run { Get-TcMember @{ a = 1 } 'b' }).Count | Should -Be 0
        @(& $Run { Get-TcMember ([pscustomobject]@{ a = 1 }) 'b' }).Count | Should -Be 0
        @(& $Run { Get-TcMember $null 'b' }).Count | Should -Be 0
    }

    It 'reads each item of a list' {
        @(& $Run { Get-TcMember @(@{ a = 1 }, @{ a = 2 }) 'a' }) | Should -Be @(1, 2)
    }

    It 'gives an empty string, not $null, for text that is missing' {
        & $Run { (Get-TcText ([pscustomobject]@{ a = 1 }) 'b').Trim().Length } | Should -Be 0
        & $Run { (Get-TcText $null 'b').Length } | Should -Be 0
        & $Run { Get-TcText @{ a = 'x' } 'a' } | Should -Be 'x'
    }

    It 'counts a single object, a list and nothing' {
        & $Run { Get-TcCount @(1, 2) } | Should -Be 2
        & $Run { Get-TcCount 'one' } | Should -Be 1
        & $Run { Get-TcCount $null } | Should -Be 0
    }
}

Describe 'What the scripts read of the project' {
    It 'names the sources and the project' {
        @(& $Run { Get-TcSourceRole }) | Should -Be @('S1', 'S2')
        @(& $Run { Get-TcProjectRole }) | Should -Be @('Target', 'S1', 'S2')
    }

    It 'gives the blocking actions of a tenant only' {
        $blockers = @(& $Run { Get-TcRemediationPlanBlocker -Tenant 'S1' })
        $expected = @($Plan['actions'] | Where-Object { $_['blocking'] -and $_['role'] -in 'S1', 'All' })
        $blockers.Count | Should -Be $expected.Count
    }

    It 'gives the groups a project plans for a source, and none for another' {
        @(& $Run { Get-TcSourceGroup -Tenant 'S1' }).Count | Should -Be 1
        @(& $Run { Get-TcSourceGroup -Tenant 'S2' }).Count | Should -Be 0
    }

    It 'says a cutover step is done only when a row says Done' {
        & $Run { Test-TcCutoverStep -Tenant 'S1' -Step 'UPNs released' } | Should -BeFalse
        [pscustomobject]@{ Tenant = 'S1'; Step = 'UPNs released'; Decision = 'Done' } | Export-Csv -LiteralPath (Join-Path $DecisionFolder 'CUTOVER-STEPS.csv') -NoTypeInformation -Encoding utf8BOM
        & $Run { Test-TcCutoverStep -Tenant 'S1' -Step 'UPNs released' } | Should -BeTrue
        & $Run { Test-TcCutoverStep -Tenant 'S2' -Step 'UPNs released' } | Should -BeFalse
    }

    It 'names the object of a project with the prefix of the setting' {
        & $Run { Get-TcObjectName ' - Sample' } | Should -Match ' - Sample$'
        & $Run { Get-TcObjectName ' - Sample' } | Should -Not -Match '^\s'
    }

    It 'reads a cell that carried an apostrophe against a formula' {
        '"Decision"' , '"''=SUM(A1)"' | Set-Content -LiteralPath (Join-Path $DecisionFolder 'CELL.csv') -Encoding utf8BOM
        @(& $Run { Read-TcDecisionRow 'CELL' })[0].Decision | Should -Be '=SUM(A1)'
    }
}

Describe 'Add-TcPlanRemediation' {
    It 'leaves an action no script serves as it is, and gives no entry' {
        $action = [ordered]@{ ruleId = 'NOT-A-RULE'; procedure = '' }
        @(& $Run { param($Row) Add-TcPlanRemediation -Action @($Row) -Task @() } $action) | Should -BeNullOrEmpty
        $action.Contains('remediations') | Should -BeFalse
    }

    It 'links through the rule and through the procedure' {
        $byRule = [ordered]@{ ruleId = 'ENT-MFA'; procedure = '' }
        $byProcedure = [ordered]@{ ruleId = ''; procedure = 'ENT-MFA' }
        $entries = @(& $Run { param($One, $Two) Add-TcPlanRemediation -Action @($One, $Two) -Task @() } $byRule $byProcedure)
        @($entries | ForEach-Object { $_['id'] }) | Should -Be @('ENT-MFA')
        @($byRule['remediations']) | Should -Be @('ENT-MFA')
        @($byProcedure['remediations']) | Should -Be @('ENT-MFA')
    }
}

# Last in this file: it loads the module again, without the stubs.
Describe 'Assert-TcModuleFamily' {
    BeforeAll {
        Import-Module (Join-Path $Root 'src/TenantConverge/TenantConverge.psd1') -Force
    }

    It 'refuses a script next to a module of another family' {
        InModuleScope TenantConverge {
            Mock Get-Module { [pscustomobject]@{ Name = 'MicrosoftTeams' } }
            { Assert-TcModuleFamily -Service 'Pnp' } | Should -Throw '*new window*'
        }
    }

    It 'lets a script run when no other family is loaded' {
        InModuleScope TenantConverge {
            Mock Get-Module { }
            { Assert-TcModuleFamily -Service 'Pnp' } | Should -Not -Throw
        }
    }

    It 'has nothing to check for a service with no module family' {
        InModuleScope TenantConverge {
            Mock Get-Module { [pscustomobject]@{ Name = 'MicrosoftTeams' } }
            { Assert-TcModuleFamily -Service 'Graph' } | Should -Not -Throw
        }
    }
}

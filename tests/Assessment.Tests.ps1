BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/ServiceStubs.ps1')
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    function Get-TcTestTenantId {
        param([string]$Uri)
        $names = 'summit', 'alpine', 'birch', 'cedar', 'dune'
        for ($i = 0; $i -lt $names.Count; $i++) {
            if ($Uri -match $names[$i]) { return "$($i + 1)$($i + 1)$($i + 1)$($i + 1)$($i + 1)$($i + 1)$($i + 1)$($i + 1)-1111-4111-8111-111111111111" }
        }
        throw "No fictional tenant for $Uri"
    }

    function Set-TcAssessmentMock {
        <# Two fictional collectors, and no service. #>
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Connect-TcService -ModuleName TenantConverge
        Mock Disconnect-TcService -ModuleName TenantConverge
        Mock Test-TcServiceModule -ModuleName TenantConverge { @{ ok = $true } }
        Mock Invoke-RestMethod -ModuleName TenantConverge { [pscustomobject]@{ issuer = "https://login.microsoftonline.com/$(Get-TcTestTenantId $Uri)/v2.0" } }
        InModuleScope TenantConverge {
            Mock Get-TcCollector {
                @{
                    Id = 'ENT-01'; Workload = 'Entra ID'; Title = 'Domains'; Service = 'Graph'
                    Collect = { param($Role) Add-TcTable 'domains' @([ordered]@{ Domain = "$($Role.ToLowerInvariant()).example"; Verified = $true }) }
                }
                @{
                    Id = 'ENT-03'; Workload = 'Entra ID'; Title = 'Users'; Service = 'Graph'
                    Collect = { param($Role) Add-TcTable 'users' @([ordered]@{ Id = 'u1'; UPN = "ana@$($Role.ToLowerInvariant()).example"; Name = 'Ana Silva'; Type = 'Member'; Enabled = $true; 'Last sign-in' = (Get-Date).ToString('yyyy-MM-dd HH:mm'); 'License count' = 1 }) }
                }
                @{
                    Id = 'INT-01'; Workload = 'Intune'; Title = 'Devices'; Service = 'Graph'
                    Collect = { param($Role) throw '403 Forbidden' }
                }
            }
        }
    }
}

AfterAll {
    Remove-TcServiceStub
}

Describe 'Invoke-TcAssessment' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force $folder | Out-Null
        $saved = @{ OneDrive = $env:OneDrive; OneDriveCommercial = $env:OneDriveCommercial; OneDriveConsumer = $env:OneDriveConsumer }
        $env:OneDrive = $null; $env:OneDriveCommercial = $null; $env:OneDriveConsumer = $null
        $project = New-TcTestProject -Folder $folder -SourceCount 2
        Set-TcAssessmentMock
    }

    AfterEach {
        $env:OneDrive = $saved.OneDrive; $env:OneDriveCommercial = $saved.OneDriveCommercial; $env:OneDriveConsumer = $saved.OneDriveConsumer
    }

    It 'writes a dated run folder with the files of the format' {
        $result = Invoke-TcAssessment -Project $project
        (Split-Path $result.Folder -Leaf) | Should -Match '^\d{8}-\d{6}-assessment$'
        foreach ($file in 'snapshot.json', 'findings.json', 'plan.json', 'journal.log', 'events.jsonl') {
            Test-Path (Join-Path $result.Folder $file) | Should -BeTrue -Because $file
        }
        Test-Path (Join-Path $result.Folder 'exports/Target.domains.csv') | Should -BeTrue
        Test-Path (Join-Path $result.Folder 'snapshot.partial.json') | Should -BeFalse
    }

    It 'writes the plan of the project and returns its path' {
        $result = Invoke-TcAssessment -Project $project
        $result.Plan | Should -Be (Join-Path $result.Folder 'plan.json')
        $plan = Get-Content $result.Plan -Raw | ConvertFrom-Json -AsHashtable
        $plan['meta']['project'] | Should -Be 'Summit consolidation'
        @($plan['tenants'] | ForEach-Object { $_['role'] }) -join ',' | Should -Be 'Target,S1,S2'
    }

    It 'keeps the snapshot and the findings when the plan cannot be computed, and says so' {
        Mock New-TcPlan -ModuleName TenantConverge { throw 'plan failed' }
        $result = Invoke-TcAssessment -Project $project
        Test-Path $result.Snapshot | Should -BeTrue
        Test-Path (Join-Path $result.Folder 'findings.json') | Should -BeTrue
        $result.Plan | Should -BeNullOrEmpty
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*plan*' }
    }

    It 'collects the target and every source' {
        $result = Invoke-TcAssessment -Project $project
        $snapshot = Get-Content $result.Snapshot -Raw | ConvertFrom-Json -AsHashtable
        @($snapshot.tenants.Keys) | Should -Be @('Target', 'S1', 'S2')
        $snapshot.tenants.S2.tables.domains[0].Domain | Should -Be 's2.example'
        @($snapshot.coverage).Count | Should -Be 9
        $snapshot.meta.depth | Should -Be 'Complete'
        $snapshot.meta.project | Should -Be 'Summit consolidation'
        $snapshot.tenants.S1.tenantId | Should -Be (Get-TcTestTenantId 'alpine')
    }

    It 'counts what was not collected and says it in the coverage' {
        $result = Invoke-TcAssessment -Project $project
        $result.NotCollected | Should -Be 3
        $snapshot = Get-Content $result.Snapshot -Raw | ConvertFrom-Json -AsHashtable
        @($snapshot.coverage | Where-Object status -EQ 'Insufficient access').Count | Should -Be 3
        $snapshot.tenants.S1.tables.Contains('managedDevices') | Should -BeFalse
    }

    It 'says everything was collected only when it was' {
        Invoke-TcAssessment -Project $project -Workload 'Entra ID' | Out-Null
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Success' -and $Message -like '*Everything was collected*' }
    }

    It 'does not say everything was collected when rules stopped' {
        Mock Invoke-TcRuleSet -ModuleName TenantConverge { [ordered]@{ findings = @(); measures = @(); settingGaps = @(); unread = @(); errors = @([ordered]@{ role = 'S1'; workload = 'Entra ID'; message = 'Broken column' }) } }
        $result = Invoke-TcAssessment -Project $project -Workload 'Entra ID'
        $result.RulesStopped | Should -Be 1
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -Times 0 -Exactly -ParameterFilter { $Message -like '*Everything was collected*' }
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*1 rule block(s) stopped*findings.json*' }
    }

    It 'does not say everything was collected when a collector was partial' {
        InModuleScope TenantConverge {
            Mock Get-TcCollector {
                @{
                    Id = 'ENT-01'; Workload = 'Entra ID'; Title = 'Domains'; Service = 'Graph'
                    Collect = {
                        param($Role)
                        Add-TcTable 'domains' @([ordered]@{ Domain = "$($Role.ToLowerInvariant()).example"; Verified = $true })
                        Invoke-TcCollectorPart 'Refused part' { throw '403 Forbidden' }
                    }
                }
            }
        }
        $result = Invoke-TcAssessment -Project $project -Workload 'Entra ID'
        $result.NotCollected | Should -Be 0
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -Times 0 -Exactly -ParameterFilter { $Message -like '*Everything was collected*' }
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -like '*read only part*' }
    }

    It 'can limit the run to some tenants and still give a valid snapshot' {
        $result = Invoke-TcAssessment -Project $project -Tenant S1
        $snapshot = Get-Content $result.Snapshot -Raw | ConvertFrom-Json -AsHashtable
        @($snapshot.coverage.role | Sort-Object -Unique) | Should -Be @('S1')
        @($snapshot.tenants.Keys) | Should -Be @('Target', 'S1', 'S2')
        @($snapshot.tenants.Target.tables.Keys).Count | Should -Be 0
    }

    It 'can limit the run to a workload' {
        $result = Invoke-TcAssessment -Project $project -Workload 'Intune'
        $snapshot = Get-Content $result.Snapshot -Raw | ConvertFrom-Json -AsHashtable
        @($snapshot.coverage.id | Sort-Object -Unique) | Should -Be @('INT-01')
    }

    It 'passes the depth to the snapshot' {
        $result = Invoke-TcAssessment -Project $project -Depth Standard
        (Get-Content $result.Snapshot -Raw | ConvertFrom-Json).meta.depth | Should -Be 'Standard'
    }

    It 'writes a draft identity matrix for each source' {
        $result = Invoke-TcAssessment -Project $project
        @(Get-ChildItem $result.Folder -Filter 'identity-matrix-*.csv').Name | Should -Be @('identity-matrix-S1.csv', 'identity-matrix-S2.csv')
    }

    It 'refuses more than 3 sources when the collection starts' {
        $bad = New-TcTestProject -Folder $folder -SourceCount 4
        { Invoke-TcAssessment -Project $bad } | Should -Throw '*TC1002*'
    }

    It 'refuses two sources that resolve to the same tenant' {
        Mock Invoke-RestMethod -ModuleName TenantConverge { [pscustomobject]@{ issuer = "https://login.microsoftonline.com/$(Get-TcTestTenantId 'summit')/v2.0" } }
        { Invoke-TcAssessment -Project $project } | Should -Throw '*same tenant*'
    }

    It 'refuses a project tenant ID that does not match its domain' {
        $data = Get-Content $project -Raw | ConvertFrom-Json
        $data.target.tenantId = Get-TcTestTenantId 'cedar'
        $data | ConvertTo-Json -Depth 6 | Set-Content $project
        { Invoke-TcAssessment -Project $project } | Should -Throw '*does not match*'
    }

    It 'stops in Application mode when a tenant has no application' {
        $application = New-TcTestProject -Folder $folder -Mode Application
        { Invoke-TcAssessment -Project $application } | Should -Throw '*Initialize-TcAccess*'
        Test-Path (Join-Path $folder 'output') | Should -BeFalse
    }

    It 'stops an unattended run in a folder synced to the cloud' {
        $env:OneDrive = $folder
        { Invoke-TcAssessment -Project $project -Unattended } | Should -Throw '*OneDrive*'
    }

    It 'warns about a folder synced to the cloud' {
        $env:OneDrive = $folder
        Invoke-TcAssessment -Project $project | Out-Null
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'OneDrive' }
    }

    Context 'an interrupted run' {
        BeforeEach {
InModuleScope TenantConverge {
                Mock Get-TcCollector {
                    @{
                        Id = 'ENT-01'; Workload = 'Entra ID'; Title = 'Domains'; Service = 'Graph'
                        Collect = {
                            param($Role)
                            $global:TcCollectorRuns.Add("ENT-01 $Role")
                            Add-TcTable 'domains' @([ordered]@{ Domain = "$($Role.ToLowerInvariant()).example" })
                        }
                    }
                    @{
                        Id = 'ENT-03'; Workload = 'Entra ID'; Title = 'Users'; Service = 'Graph'
                        Collect = {
                            param($Role)
                            $global:TcCollectorRuns.Add("ENT-03 $Role")
                            Add-TcTable 'users' @()
                        }
                    }
                }
            }
            $global:TcCollectorRuns = [System.Collections.Generic.List[string]]::new()
            $global:TcStopAt = 2
            $global:TcStepCount = 0

            # The stop comes in the middle of S1, outside anything a collector can catch.
            Mock Write-TcStepStart -ModuleName TenantConverge {
                if ($Id -eq 'ENT-03') {
                    $global:TcStepCount++
                    if ($global:TcStepCount -eq $global:TcStopAt) { throw 'The run was stopped.' }
                }
            }
        }

        AfterEach {
            Remove-Variable -Name TcCollectorRuns, TcStopAt, TcStepCount -Scope Global -ErrorAction SilentlyContinue
        }

        It 'leaves a partial snapshot and resumes it without starting over' {
            try { Invoke-TcAssessment -Project $project | Out-Null } catch { Write-Verbose 'stopped' }

            $run = Get-ChildItem (Join-Path $folder 'output') -Directory | Select-Object -First 1
            Test-Path (Join-Path $run.FullName 'snapshot.partial.json') | Should -BeTrue
            Test-Path (Join-Path $run.FullName 'snapshot.json') | Should -BeFalse

            $global:TcStopAt = 0
            $global:TcCollectorRuns.Clear()
            $result = Invoke-TcAssessment -Project $project

            $result.Folder | Should -Be $run.FullName
            $global:TcCollectorRuns | Should -Not -Contain 'ENT-01 Target'
            $global:TcCollectorRuns | Should -Not -Contain 'ENT-03 Target'
            $global:TcCollectorRuns | Should -Not -Contain 'ENT-01 S1'
            $global:TcCollectorRuns | Should -Contain 'ENT-03 S1'
            $global:TcCollectorRuns | Should -Contain 'ENT-01 S2'
            Test-Path (Join-Path $run.FullName 'snapshot.json') | Should -BeTrue
            Test-Path (Join-Path $run.FullName 'snapshot.partial.json') | Should -BeFalse
            $snapshot = Get-Content $result.Snapshot -Raw | ConvertFrom-Json -AsHashtable
            @($snapshot.coverage | Where-Object role -EQ 'Target').Count | Should -Be 2
            $snapshot.tenants.Target.tables.Contains('domains') | Should -BeTrue
        }

        It 'keeps a tenant of the partial file that this run does not collect' {
            try { Invoke-TcAssessment -Project $project | Out-Null } catch { Write-Verbose 'stopped' }

            $global:TcStopAt = 0
            $global:TcCollectorRuns.Clear()
            $result = Invoke-TcAssessment -Project $project -Tenant S1

            $global:TcCollectorRuns | Should -Not -Contain 'ENT-01 Target'
            $snapshot = Get-Content $result.Snapshot -Raw | ConvertFrom-Json -AsHashtable
            @($snapshot.coverage | Where-Object role -EQ 'Target').Count | Should -Be 2
            $snapshot.tenants.Target.tables.Contains('domains') | Should -BeTrue
            Test-Path (Join-Path $result.Folder 'exports/Target.domains.csv') | Should -BeTrue
        }

        It 'refuses to resume when a domain no longer matches the project, and points to -Fresh' {
            try { Invoke-TcAssessment -Project $project | Out-Null } catch { Write-Verbose 'stopped' }
            $run = Get-ChildItem (Join-Path $folder 'output') -Directory | Select-Object -First 1
            $data = Get-Content $project -Raw | ConvertFrom-Json
            $data.sources[0].primaryDomain = 'cedar.example'
            $data | ConvertTo-Json -Depth 6 | Set-Content $project

            $global:TcStopAt = 0
            $global:TcCollectorRuns.Clear()
            { Invoke-TcAssessment -Project $project } | Should -Throw '*alpine.example*cedar.example*-Fresh*'
            $global:TcCollectorRuns.Count | Should -Be 0
            Test-Path (Join-Path $run.FullName 'snapshot.partial.json') | Should -BeTrue
        }

        It 'refuses to resume when a tenant ID no longer matches the project' {
            try { Invoke-TcAssessment -Project $project | Out-Null } catch { Write-Verbose 'stopped' }
            $run = Get-ChildItem (Join-Path $folder 'output') -Directory | Select-Object -First 1
            $file = Join-Path $run.FullName 'snapshot.partial.json'
            $partial = Get-Content $file -Raw | ConvertFrom-Json -AsHashtable
            $partial['tenants']['S1']['tenantId'] = Get-TcTestTenantId 'dune'
            $partial | ConvertTo-Json -Depth 12 | Set-Content $file

            $global:TcStopAt = 0
            { Invoke-TcAssessment -Project $project } | Should -Throw '*-Fresh*'
        }

        It 'refuses to resume when a tenant of the partial file left the project' {
            $global:TcStopAt = 3
            try { Invoke-TcAssessment -Project $project | Out-Null } catch { Write-Verbose 'stopped' }
            $data = Get-Content $project -Raw | ConvertFrom-Json
            $data.sources = @($data.sources[0])
            $data | ConvertTo-Json -Depth 6 | Set-Content $project

            $global:TcStopAt = 0
            { Invoke-TcAssessment -Project $project } | Should -Throw '*S2*-Fresh*'
        }

        It 'does not refuse a tenant that was only renamed' {
            try { Invoke-TcAssessment -Project $project | Out-Null } catch { Write-Verbose 'stopped' }
            $data = Get-Content $project -Raw | ConvertFrom-Json
            $data.sources[0].displayName = 'Alpine Holdings'
            $data | ConvertTo-Json -Depth 6 | Set-Content $project

            $global:TcStopAt = 0
            $result = Invoke-TcAssessment -Project $project
            Test-Path $result.Snapshot | Should -BeTrue
        }

        It 'starts over with -Fresh after a refused resume' {
            try { Invoke-TcAssessment -Project $project | Out-Null } catch { Write-Verbose 'stopped' }
            $data = Get-Content $project -Raw | ConvertFrom-Json
            $data.sources[0].primaryDomain = 'cedar.example'
            $data | ConvertTo-Json -Depth 6 | Set-Content $project

            $global:TcStopAt = 0
            Start-Sleep -Milliseconds 1100
            $result = Invoke-TcAssessment -Project $project -Fresh
            (Get-Content $result.Snapshot -Raw | ConvertFrom-Json).tenants.S1.primaryDomain | Should -Be 'cedar.example'
        }

        It 'starts over with -Fresh' {
            try { Invoke-TcAssessment -Project $project | Out-Null } catch { Write-Verbose 'stopped' }
            $global:TcStopAt = 0
            $global:TcCollectorRuns.Clear()
            Start-Sleep -Milliseconds 1100
            $result = Invoke-TcAssessment -Project $project -Fresh
            $global:TcCollectorRuns | Should -Contain 'ENT-01 Target'
            @(Get-ChildItem (Join-Path $folder 'output') -Directory).Count | Should -Be 2
            Test-Path $result.Snapshot | Should -BeTrue
        }
    }
}

Describe 'Start-TenantConverge chains the steps' {
    BeforeEach {
        $folder = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory -Force $folder | Out-Null
        $project = New-TcTestProject -Folder $folder
        $script:calls = [System.Collections.Generic.List[string]]::new()
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Test-TcPrerequisite -ModuleName TenantConverge {
            $script:calls.Add('prerequisites')
            [pscustomobject]@{ Ready = $true; PowerShell = '7.4.6'; WindowsPowerShell = $true; Modules = @(); Missing = @() }
        }
        Mock Invoke-TcAssessment -ModuleName TenantConverge {
            $script:calls.Add('assessment')
            [pscustomobject]@{ Folder = 'run'; Snapshot = 'run/snapshot.json'; NotCollected = 0 }
        }
    }

    It 'checks prerequisites, then runs the assessment, with no question' {
        Mock Read-TcAnswer -ModuleName TenantConverge { throw 'no question expected' }
        Start-TenantConverge -Project $project | Out-Null
        $script:calls | Should -Be @('prerequisites', 'assessment')
    }

    It 'passes the project file to the assessment' {
        Start-TenantConverge -Project $project | Out-Null
        Should -Invoke Invoke-TcAssessment -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter { $Project -like '*project.json' }
    }

    It 'tells where the plan is' {
        Mock Invoke-TcAssessment -ModuleName TenantConverge { [pscustomobject]@{ Folder = 'run'; Snapshot = 'run/snapshot.json'; Plan = 'run/plan.json'; NotCollected = 0 } }
        Start-TenantConverge -Project $project | Out-Null
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Message -like '*run/plan.json*' }
    }

    It 'stops when PowerShell or Graph cannot work' {
        Mock Test-TcPrerequisite -ModuleName TenantConverge {
            [pscustomobject]@{ Ready = $false; PowerShell = '7.4.6'; WindowsPowerShell = $true; Modules = @(); Missing = @('Microsoft.Graph.Authentication') }
        }
        { Start-TenantConverge -Project $project } | Should -Throw '*Test-TcPrerequisite -Install*'
        Should -Invoke Invoke-TcAssessment -ModuleName TenantConverge -Times 0 -Exactly
    }

    It 'carries on without a module that only one workload needs: the coverage will say so' {
        Mock Test-TcPrerequisite -ModuleName TenantConverge {
            $script:calls.Add('prerequisites')
            [pscustomobject]@{ Ready = $false; PowerShell = '7.4.6'; WindowsPowerShell = $false; Modules = @(); Missing = @('MicrosoftTeams') }
        }
        Start-TenantConverge -Project $project | Out-Null
        $script:calls | Should -Be @('prerequisites', 'assessment')
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'MicrosoftTeams' }
    }

    It 'never installs anything without -Install' {
        Start-TenantConverge -Project $project | Out-Null
        Should -Invoke Test-TcPrerequisite -ModuleName TenantConverge -ParameterFilter { -not $Install }
    }

    It 'passes -Install to the prerequisites' {
        Start-TenantConverge -Project $project -Install | Out-Null
        Should -Invoke Test-TcPrerequisite -ModuleName TenantConverge -ParameterFilter { $Install }
    }

    It 'reminds about the application at the end in Application mode' {
        $application = New-TcTestProject -Folder $folder -Mode Application
        Start-TenantConverge -Project $application | Out-Null
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Message -match 'Remove-TcAccess' }
    }

    It 'continues into the assessment after the setup questions' {
        $path = Join-Path $folder 'new.json'
        $script:draft = Get-Content $project -Raw | ConvertFrom-Json
        Mock Invoke-TcWizard -ModuleName TenantConverge { $script:draft }
        Start-TenantConverge -Path $path | Out-Null
        $script:calls | Should -Be @('prerequisites', 'assessment')
        Test-Path $path | Should -BeTrue
    }
}

Describe 'README' {
    It 'says a real run is still to be done' {
        $readme = Get-Content (Join-Path $Root 'README.md') -Raw
        $readme | Should -Match 'never been run on a real tenant'
        $readme | Should -Match 'Invoke-TcAssessment'
        $readme | Should -Match 'Initialize-TcAccess'
        $readme | Should -Match 'Remove-TcAccess'
    }
}

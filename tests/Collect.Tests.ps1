BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/ServiceStubs.ps1')
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Source = Join-Path $Root 'src/TenantConverge'

    function Initialize-TcTestCollection {
        param([string]$Depth = 'Standard', [int]$SourceCount = 1)
        InModuleScope TenantConverge -Parameters @{ Depth = $Depth; SourceCount = $SourceCount } {
            param($Depth, $SourceCount)
            $sources = @(for ($i = 1; $i -le $SourceCount; $i++) { [pscustomobject]@{ role = "S$i"; displayName = "Source $i"; primaryDomain = "source$i.example"; tenantId = "id-$i" } })
            $project = [pscustomobject]@{
                target  = [pscustomobject]@{ displayName = 'Summit Holdings'; primaryDomain = 'summit.example'; tenantId = 'id-t' }
                sources = $sources
                access  = [pscustomobject]@{ mode = 'Browser' }
            }
            Initialize-TcSession -Project $project -Access @{}
            Initialize-TcCollection -Depth $Depth
            Select-TcCollectionTenant -Role Target
        }
    }
}

AfterAll {
    Remove-TcServiceStub
}

Describe 'Error classes' {
    It 'sorts <Text> into <Class>' -TestCases @(
        @{ Text = 'Response status code does not indicate success: Forbidden (Forbidden).'; Class = 'Insufficient access' }
        @{ Text = 'Authorization_RequestDenied : Insufficient privileges to complete the operation.'; Class = 'Insufficient access' }
        @{ Text = 'Tenant does not have a SPO license.'; Class = 'License or service missing' }
        @{ Text = "The term 'Get-CsOnlineUser' is not recognized as a name of a cmdlet"; Class = 'Module missing' }
        @{ Text = 'NOTCONFIGURED: this tenant has no PnP application'; Class = 'Not configured' }
        @{ Text = 'Something else broke'; Class = 'Failed' }
    ) {
        InModuleScope TenantConverge -Parameters @{ Text = $Text; Class = $Class } {
            param($Text, $Class)
            Clear-TcConnectionState
            Get-TcErrorClass -Text $Text | Should -Be $Class
        }
    }

    It 'reads <Text> as a missing license' -TestCases @(
        @{ Text = 'Tenant does not have a SPO license.' }
        @{ Text = 'This tenant has no Entra ID P2 license.' }
        @{ Text = "Neither tenant is B2C or tenant doesn't have premium license" }
        @{ Text = 'License is required for this operation.' }
        @{ Text = 'You need licenses for this feature.' }
        @{ Text = 'Licence absente pour ce service.' }
        @{ Text = 'User is not licensed for Exchange Online.' }
        @{ Text = 'This feature requires an Entra ID Premium P2.' }
        @{ Text = 'The service is not provisioned for this tenant.' }
    ) {
        InModuleScope TenantConverge -Parameters @{ Text = $Text } {
            param($Text)
            Clear-TcConnectionState
            Get-TcErrorClass -Text $Text | Should -Be 'License or service missing'
        }
    }

    It 'keeps a failure that only mentions a license as a failure: <Text>' -TestCases @(
        @{ Text = 'Service unavailable while reading the licenses of the organization' }
        @{ Text = 'The request for the license of the tenant timed out.' }
        @{ Text = 'Error 500 while listing every license.' }
        @{ Text = 'Could not load the license data: unexpected end of JSON.' }
        @{ Text = 'Request failed for the Entra ID Premium P2 report.' }
        @{ Text = 'TooManyRequests: reading the licenses was throttled.' }
    ) {
        InModuleScope TenantConverge -Parameters @{ Text = $Text } {
            param($Text)
            Clear-TcConnectionState
            Get-TcErrorClass -Text $Text | Should -Be 'Failed'
        }
    }

    It 'does not read a message that only quotes a name as a missing license: <Text>' -TestCases @(
        @{ Text = "Could not find a property named 'assignedLicenses' on type 'microsoft.graph.user'." }
        @{ Text = 'Invalid filter clause: assignedLicenses/any(x:x/skuId eq 1)' }
        @{ Text = 'Request failed: users?$select=id,licenseAssignmentStates' }
        @{ Text = 'Request failed: subscribedSkus?$select=licenses' }
        @{ Text = "Could not find a property named 'licenseDetails'." }
        @{ Text = "The property 'License count' cannot be found on this object." }
        @{ Text = "The property 'Licenses' cannot be found on this object." }
    ) {
        InModuleScope TenantConverge -Parameters @{ Text = $Text } {
            param($Text)
            Clear-TcConnectionState
            Get-TcErrorClass -Text $Text | Should -Be 'Failed'
        }
    }

    It 'treats a cmdlet missing from an Exchange session as a right, not a module' {
        InModuleScope TenantConverge {
            Clear-TcConnectionState
            $script:TcActive['Exo'] = 'Target'
            Get-TcErrorClass -Text "The term 'Get-Label' is not recognized as a name of a cmdlet" | Should -Be 'Insufficient access'
            Clear-TcConnectionState
        }
    }

    It 'tells how to register the PnP application' {
        Initialize-TcTestCollection
        InModuleScope TenantConverge {
            Get-TcRemedy -Service Pnp -Class 'Not configured' -Role Target | Should -Match 'Initialize-TcAccess.+DelegatedPnP'
            Get-TcRemedy -Service Teams -Class 'Module missing' -Role Target | Should -Match 'Install-Module MicrosoftTeams'
            Get-TcRemedy -Service Graph -Class 'Failed' -Role Target | Should -Match 'journal.log'
        }
    }
}

Describe 'Collector isolation' {
    BeforeEach {
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Write-TcLog -ModuleName TenantConverge
        Mock Connect-TcService -ModuleName TenantConverge
        Mock Test-TcServiceModule -ModuleName TenantConverge { @{ ok = $true } }
        Initialize-TcTestCollection
    }

    It 'notes a refused access and keeps going, with no table' {
        $result = InModuleScope TenantConverge {
            $collector = @{ Id = 'T-01'; Workload = 'Entra ID'; Title = 'Test'; Service = 'Graph'; Collect = { param($Role) throw 'Response status code does not indicate success: Forbidden (Forbidden).' } }
            Invoke-TcCollector -Collector $collector -Role Target -Rank 1 -Total 1
        }
        $result.status | Should -Be 'Insufficient access'
        $result.remedy | Should -Not -BeNullOrEmpty
        @($result.tables).Count | Should -Be 0
    }

    It 'says Insufficient access when the service cannot connect' {
        Mock Connect-TcService -ModuleName TenantConverge { throw 'AADSTS50020: sign-in cancelled' }
        $result = InModuleScope TenantConverge {
            $collector = @{ Id = 'T-02'; Workload = 'Entra ID'; Title = 'Test'; Service = 'Graph'; Collect = { param($Role) Add-TcTable 'domains' @() } }
            Invoke-TcCollector -Collector $collector -Role Target -Rank 1 -Total 1
        }
        $result.status | Should -Be 'Insufficient access'
        InModuleScope TenantConverge { $script:TcCurrentTenant['tables'].Contains('domains') | Should -BeFalse }
    }

    It 'says Insufficient access when a service has no way to connect' {
        Mock Connect-TcService -ModuleName TenantConverge { throw 'NOTCONFIGURED: this tenant has no PnP application for SharePoint (Target, summit.example).' }
        $result = InModuleScope TenantConverge {
            $collector = @{ Id = 'T-03'; Workload = 'SharePoint and OneDrive'; Title = 'Test'; Service = 'Pnp'; Collect = { param($Role) throw 'must not run' } }
            Invoke-TcCollector -Collector $collector -Role Target -Rank 1 -Total 1
        }
        $result.status | Should -Be 'Insufficient access'
        $result.message | Should -Not -Match 'NOTCONFIGURED'
        $result.remedy | Should -Match 'DelegatedPnP'
    }

    It 'never shows an empty table as a result when the collector failed' {
        InModuleScope TenantConverge {
            $collector = @{ Id = 'T-04'; Workload = 'Exchange Online'; Title = 'Test'; Service = 'Exo'; Collect = {
                    param($Role)
                    Add-TcTable 'protectionPolicies' @()
                    Invoke-TcCollectorPart 'Refused part' { throw '403 Forbidden' }
                }
            }
            $result = Invoke-TcCollector -Collector $collector -Role Target -Rank 1 -Total 1
            $result.status | Should -Be 'Insufficient access'
            @($result.tables).Count | Should -Be 0
            $script:TcCurrentTenant['tables'].Contains('protectionPolicies') | Should -BeFalse
        }
    }

    It 'keeps an empty table when the collector succeeded: the service is not used' {
        InModuleScope TenantConverge {
            $collector = @{ Id = 'T-05'; Workload = 'Teams Phone'; Title = 'Test'; Service = 'Teams'; Collect = { param($Role) Add-TcTable 'phoneNumbers' @() } }
            $result = Invoke-TcCollector -Collector $collector -Role Target -Rank 1 -Total 1
            $result.status | Should -Be 'OK'
            $result.tables | Should -Be @('phoneNumbers')
            $script:TcCurrentTenant['tables'].Contains('phoneNumbers') | Should -BeTrue
        }
    }

    It 'marks a collector partial without losing the rest' {
        $result = InModuleScope TenantConverge {
            $collector = @{ Id = 'T-06'; Workload = 'Entra ID'; Title = 'Test'; Service = 'Graph'; Collect = {
                    param($Role)
                    Add-TcTable 'domains' @([ordered]@{ Domain = 'a.example' }, [ordered]@{ Domain = 'b.example' })
                    Invoke-TcCollectorPart 'Refused part' { throw '403 Forbidden' }
                }
            }
            Invoke-TcCollector -Collector $collector -Role Target -Rank 1 -Total 1
        }
        $result.status | Should -Be 'Partial'
        $result.rows | Should -Be 2
        $result.message | Should -Match 'Refused part'
    }

    It 'reports a missing module with the install command and does not run the collector' {
        Mock Test-TcServiceModule -ModuleName TenantConverge {
            @{ ok = $false; status = 'Module missing'; message = 'Module MicrosoftTeams 6.0.0+ not found or too old'; remedy = 'Install-Module MicrosoftTeams -Scope CurrentUser' }
        }
        $result = InModuleScope TenantConverge {
            $collector = @{ Id = 'T-07'; Workload = 'Teams'; Title = 'Test'; Service = 'Teams'; Collect = { param($Role) throw 'must not run' } }
            Invoke-TcCollector -Collector $collector -Role Target -Rank 1 -Total 1
        }
        $result.status | Should -Be 'Module missing'
        $result.remedy | Should -Match 'Install-Module MicrosoftTeams'
    }

    It 'counts a table of one row as one row' {
        InModuleScope TenantConverge {
            Add-TcTable 'domains' @([ordered]@{ Domain = 'a.example'; Verified = $true; Default = $true })
            @(Get-TcTable 'domains').Count | Should -Be 1
        }
    }

    It 'adds rows with -Append and replaces them without it' {
        InModuleScope TenantConverge {
            Add-TcTable 'domains' @([ordered]@{ Domain = 'a.example' })
            Add-TcTable 'domains' -Append @([ordered]@{ Domain = 'b.example' })
            @(Get-TcTable 'domains').Count | Should -Be 2
            Add-TcTable 'domains' @([ordered]@{ Domain = 'c.example' })
            @(Get-TcTable 'domains').Count | Should -Be 1
        }
    }

    It 'skips a collector whose source table was not collected, and says why' {
        InModuleScope TenantConverge {
            $producer = @{ Id = 'EXO-02'; Workload = 'Exchange Online'; Title = 'Mailboxes'; Service = 'Exo'; Collect = { param($Role) throw '403 Forbidden' } }
            $dependent = @{ Id = 'EXO-04'; Workload = 'Exchange Online'; Title = 'Permissions'; Service = 'Exo'; Requires = @('mailboxes'); Collect = { param($Role) Add-TcTable 'mailboxPermissions' @() } }
            Invoke-TcCollector -Collector $producer -Role Target -Rank 1 -Total 2 | Out-Null
            $result = Invoke-TcCollector -Collector $dependent -Role Target -Rank 2 -Total 2
            $result.status | Should -Be 'Insufficient access'
            $result.message | Should -Match 'EXO-02'
            $script:TcCurrentTenant['tables'].Contains('mailboxPermissions') | Should -BeFalse
        }
    }

    It 'skips a collector whose source table came back empty from a partial collector' {
        InModuleScope TenantConverge {
            $producer = @{ Id = 'EXO-02'; Workload = 'Exchange Online'; Title = 'Mailboxes'; Service = 'Exo'; Collect = { param($Role) Add-TcTable 'mailboxes' @(); Add-TcCollectorLimit 'stopped early' } }
            $dependent = @{ Id = 'EXO-04'; Workload = 'Exchange Online'; Title = 'Permissions'; Service = 'Exo'; Requires = @('mailboxes'); Collect = { param($Role) Add-TcTable 'mailboxPermissions' @() } }
            (Invoke-TcCollector -Collector $producer -Role Target -Rank 1 -Total 2).status | Should -Be 'Partial'
            $result = Invoke-TcCollector -Collector $dependent -Role Target -Rank 2 -Total 2
            $result.status | Should -Be 'Failed'
            $result.message | Should -Match 'EXO-02'
            $script:TcCurrentTenant['tables'].Contains('mailboxPermissions') | Should -BeFalse
        }
    }

    It 'runs a collector on an empty source table from a complete collector' {
        InModuleScope TenantConverge {
            $producer = @{ Id = 'EXO-02'; Workload = 'Exchange Online'; Title = 'Mailboxes'; Service = 'Exo'; Collect = { param($Role) Add-TcTable 'mailboxes' @() } }
            $dependent = @{ Id = 'EXO-04'; Workload = 'Exchange Online'; Title = 'Permissions'; Service = 'Exo'; Requires = @('mailboxes'); Collect = { param($Role) Add-TcTable 'mailboxPermissions' @() } }
            Invoke-TcCollector -Collector $producer -Role Target -Rank 1 -Total 2 | Out-Null
            (Invoke-TcCollector -Collector $dependent -Role Target -Rank 2 -Total 2).status | Should -Be 'OK'
            $script:TcCurrentTenant['tables'].Contains('mailboxPermissions') | Should -BeTrue
        }
    }

    It 'runs a collector on the rows a partial collector returned' {
        InModuleScope TenantConverge {
            $producer = @{ Id = 'EXO-02'; Workload = 'Exchange Online'; Title = 'Mailboxes'; Service = 'Exo'; Collect = { param($Role) Add-TcTable 'mailboxes' @([ordered]@{ UPN = 'a@summit.example' }); Add-TcCollectorLimit 'stopped early' } }
            $dependent = @{ Id = 'EXO-04'; Workload = 'Exchange Online'; Title = 'Permissions'; Service = 'Exo'; Requires = @('mailboxes'); Collect = { param($Role) Add-TcTable 'mailboxPermissions' @() } }
            Invoke-TcCollector -Collector $producer -Role Target -Rank 1 -Total 2 | Out-Null
            (Invoke-TcCollector -Collector $dependent -Role Target -Rank 2 -Total 2).status | Should -Be 'OK'
        }
    }

    It 'masks a secret in the coverage message' {
        $result = InModuleScope TenantConverge {
            $collector = @{ Id = 'T-08'; Workload = 'Entra ID'; Title = 'Test'; Service = 'Graph'; Collect = { param($Role) throw 'Failure with client_secret=abc123XYZ' } }
            Invoke-TcCollector -Collector $collector -Role Target -Rank 1 -Total 1
        }
        $result.message | Should -Not -Match 'abc123XYZ'
    }
}

Describe 'Separate process' {
    BeforeEach {
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Write-TcLog -ModuleName TenantConverge
        Mock Connect-TcTenant -ModuleName TenantConverge
        Initialize-TcTestCollection
    }

    It 'runs PnP collectors in their own process' {
        InModuleScope TenantConverge { $script:TcIsolatedServices | Should -Contain 'Pnp' }
    }

    It 'marks a collector the process did not return as failed, and carries on' {
        Mock Invoke-TcIsolatedProcess -ModuleName TenantConverge { -1073741819 }
        InModuleScope TenantConverge {
            $collector = @{ Id = 'SPO-01'; Workload = 'SharePoint and OneDrive'; Title = 'Test'; Service = 'Pnp' }
            $missing = Invoke-TcIsolatedCollector -Collector @($collector) -Role Target -Rank @(1) -Total 1 -Folder ''
            $missing | Should -Be 1
            $line = $script:TcCurrentTenant['coverage'][0]
            $line['status'] | Should -Be 'Failed'
            $line['remedy'] | Should -Match 'SharePoint and OneDrive'
        }
    }

    It 'merges what the process returned' {
        Mock Invoke-TcIsolatedProcess -ModuleName TenantConverge {
            param($Arguments)
            if (-not (Test-Path -LiteralPath $Arguments[[array]::IndexOf($Arguments, '-File') + 1])) { throw 'The worker script is not where the module looks for it.' }
            $file = $Arguments[[array]::IndexOf($Arguments, '-OutFile') + 1]
            [ordered]@{
                coverage = @([ordered]@{ role = 'Target'; tenant = 'Summit'; id = 'SPO-02'; workload = 'SharePoint and OneDrive'; title = 'Sites'; service = 'PnP'; status = 'OK'; message = ''; remedy = ''; duration = 1; rows = 1; tables = @('sites') })
                tables   = [ordered]@{ sites = @([ordered]@{ Url = 'https://summit.sharepoint.com/' }) }
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $file
            0
        }
        InModuleScope TenantConverge {
            $collector = @{ Id = 'SPO-02'; Workload = 'SharePoint and OneDrive'; Title = 'Sites'; Service = 'Pnp' }
            Invoke-TcIsolatedCollector -Collector @($collector) -Role Target -Rank @(1) -Total 1 -Folder '' | Should -Be 0
            @(Get-TcTable 'sites').Count | Should -Be 1
        }
    }

    It 'runs the worker script in a real process without reaching a tenant' {
        $project = New-TcTestProject -Folder $TestDrive
        $out = Join-Path $TestDrive 'worker.json'
        $script = Join-Path $Source 'Scripts/Invoke-TcIsolatedCollection.ps1'
        & pwsh -NoProfile -File $script -ProjectPath $project -Role Target -CollectorId 'ZZZ-99' -Depth Standard -OutFile $out *> $null
        $LASTEXITCODE | Should -Be 0
        (Get-Content $out -Raw | ConvertFrom-Json).tables.PSObject.Properties.Name | Should -BeNullOrEmpty
    }
}

Describe 'Collection run' {
    BeforeEach {
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Write-TcLog -ModuleName TenantConverge
        Mock Connect-TcService -ModuleName TenantConverge
        Mock Disconnect-TcService -ModuleName TenantConverge
        Mock Test-TcServiceModule -ModuleName TenantConverge { @{ ok = $true } }
        Initialize-TcTestCollection
    }

    It 'keeps what was collected and redoes the rest when resuming' {
        $folder = Join-Path $TestDrive 'resume'
        New-Item -ItemType Directory -Force $folder | Out-Null
        InModuleScope TenantConverge -Parameters @{ Folder = $folder } {
            param($Folder)
            Mock Get-TcCollector {
                @{ Id = 'T-10'; Workload = 'Entra ID'; Title = 'Already done'; Service = 'None'; Collect = { param($Role) throw 'must not run again' } }
                @{ Id = 'T-11'; Workload = 'Entra ID'; Title = 'To redo'; Service = 'None'; Collect = { param($Role) Add-TcTable 'licenses' @([ordered]@{ SKU = 'NEW' }) } }
            }
            $script:TcResume = @{
                Target = [ordered]@{
                    tenantId = 'id-t'
                    coverage = @([ordered]@{ id = 'T-10'; status = 'OK'; tables = @('domains') }, [ordered]@{ id = 'T-11'; status = 'Failed'; tables = @() })
                    tables   = [ordered]@{ domains = @([ordered]@{ Domain = 'kept.example' }) }
                }
            }
            $missing = Invoke-TcCollection -Folder $Folder -Role Target -Workload 'Entra ID'
            $missing | Should -Be 0
            $tenant = $script:TcCollection['Target']
            @($tenant['coverage'] | ForEach-Object { $_['id'] }) | Should -Be @('T-10', 'T-11')
            @($tenant['coverage'] | ForEach-Object { $_['status'] }) | Should -Be @('OK', 'OK')
            @(Get-TcTable 'domains' 'Target').Count | Should -Be 1
            @(Get-TcTable 'licenses' 'Target').Count | Should -Be 1
            $script:TcResume = @{}
        }
        Test-Path (Join-Path $folder 'snapshot.partial.json') | Should -BeTrue
    }

    It 'keeps everything a role of the partial file said, failures included, when this run leaves it out' {
        InModuleScope TenantConverge {
            Mock Get-TcCollector {
                @{ Id = 'T-15'; Workload = 'Entra ID'; Title = 'One'; Service = 'None'; Collect = { param($Role) Add-TcTable 'domains' @([ordered]@{ Domain = 'a.example' }) } }
            }
            $script:TcResume = @{
                S1 = [ordered]@{
                    tenantId = 'id-1'
                    coverage = @([ordered]@{ id = 'T-16'; status = 'OK'; tables = @('licenses') }, [ordered]@{ id = 'T-17'; status = 'Failed'; tables = @() })
                    tables   = [ordered]@{ licenses = @([ordered]@{ SKU = 'KEPT' }) }
                }
            }
            Invoke-TcCollection -Folder '' -Role Target -Workload 'Entra ID' | Out-Null
            @($script:TcCollection['S1']['coverage'] | ForEach-Object { $_['id'] }) | Should -Be @('T-16', 'T-17')
            @(Get-TcTable 'licenses' 'S1').Count | Should -Be 1
            @(Get-TcTable 'domains' 'Target').Count | Should -Be 1
            $script:TcResume = @{}
        }
    }

    It 'leaves a partial snapshot after each tenant and can read it back' {
        $folder = Join-Path $TestDrive 'partial'
        New-Item -ItemType Directory -Force $folder | Out-Null
        InModuleScope TenantConverge -Parameters @{ Folder = $folder } {
            param($Folder)
            Mock Get-TcCollector {
                @{ Id = 'T-12'; Workload = 'Entra ID'; Title = 'One'; Service = 'None'; Collect = { param($Role) Add-TcTable 'domains' @([ordered]@{ Domain = 'a.example' }) } }
            }
            Invoke-TcCollection -Folder $Folder -Role Target -Workload 'Entra ID' | Out-Null
            $script:TcResume = @{}
            Import-TcPartialSnapshot -Folder $Folder | Should -Be 1
            @($script:TcResume['Target']['coverage']).Count | Should -Be 1
            $script:TcResume = @{}
        }
    }

    It 'skips Complete collectors at Standard depth' {
        InModuleScope TenantConverge {
            Mock Get-TcCollector {
                @{ Id = 'T-13'; Workload = 'Entra ID'; Title = 'Deep'; Service = 'None'; Depth = 'Complete'; Collect = { param($Role) throw 'must not run' } }
            }
            Invoke-TcCollection -Folder '' -Role Target -Workload 'Entra ID' | Should -Be 0
            @($script:TcCollection['Target']['coverage']).Count | Should -Be 0
        }
    }

    It 'counts the collectors that were not collected' {
        InModuleScope TenantConverge {
            Mock Get-TcCollector {
                @{ Id = 'T-14'; Workload = 'Entra ID'; Title = 'Bad'; Service = 'None'; Collect = { param($Role) throw '403' } }
            }
            Invoke-TcCollection -Folder '' -Role Target -Workload 'Entra ID' | Should -Be 1
        }
    }

    It 'runs the PnP collectors together, once, in the separate process' {
        Mock Invoke-TcIsolatedCollector -ModuleName TenantConverge { 1 }
        InModuleScope TenantConverge {
            Mock Get-TcCollector {
                @{ Id = 'T-20'; Workload = 'Entra ID'; Title = 'First'; Service = 'None'; Collect = { param($Role) Add-TcTable 'domains' @() } }
                @{ Id = 'SPO-01'; Workload = 'SharePoint and OneDrive'; Title = 'One'; Service = 'Pnp' }
                @{ Id = 'SPO-02'; Workload = 'SharePoint and OneDrive'; Title = 'Two'; Service = 'Pnp' }
            }
            Invoke-TcCollection -Folder '' -Role Target -Workload 'Entra ID', 'SharePoint and OneDrive' | Should -Be 1
        }
        Should -Invoke Invoke-TcIsolatedCollector -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter { @($Collector).Count -eq 2 -and ($Rank -join ',') -eq '2,3' -and $Total -eq 3 }
    }

    It 'writes one CSV per table and per tenant, and none for an empty table' {
        $folder = Join-Path $TestDrive 'csv'
        New-Item -ItemType Directory -Force (Join-Path $folder 'exports') | Out-Null
        InModuleScope TenantConverge -Parameters @{ Folder = $folder } {
            param($Folder)
            Add-TcTable 'domains' @([ordered]@{ Domain = 'a.example'; Verified = $true })
            Add-TcTable 'phoneNumbers' @()
            Export-TcTableCsv -Folder $Folder
        }
        $file = Join-Path $folder 'exports/Target.domains.csv'
        Test-Path $file | Should -BeTrue
        (Get-Content $file -TotalCount 1) | Should -Match '"Domain","Verified"'
        [System.IO.File]::ReadAllBytes($file)[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        Test-Path (Join-Path $folder 'exports/Target.phoneNumbers.csv') | Should -BeFalse
    }

    It 'neutralizes what Excel would read as a formula, and keeps real values readable' {
        $folder = Join-Path $TestDrive 'formula'
        New-Item -ItemType Directory -Force (Join-Path $folder 'exports') | Out-Null
        InModuleScope TenantConverge -Parameters @{ Folder = $folder } {
            param($Folder)
            Add-TcTable 'users' @([ordered]@{
                    Equals = '=HYPERLINK("http://bad.example","Open")'; Plus = '+1+cmd|calc'; Minus = '-2+3'; At = '@SUM(1,2)'; Spaced = '  =1+1'; Tabbed = "`t=1+1"; Wide = "$([char]0xFF1D)1+1"
                    Name = 'Ana Silva'; Inside = 'a=b+c'; Phone = '+15145550100'; Negative = '-1'; Number = -1; Flag = $true; Empty = $null
                })
            Export-TcTableCsv -Folder $Folder
        }
        $row = Import-Csv (Join-Path $folder 'exports/Target.users.csv')
        foreach ($column in 'Equals', 'Plus', 'Minus', 'At', 'Spaced', 'Tabbed', 'Wide') { $row.$column | Should -Match "^'" -Because $column }
        $row.Equals | Should -Be '''=HYPERLINK("http://bad.example","Open")'
        $row.Name | Should -Be 'Ana Silva'
        $row.Inside | Should -Be 'a=b+c'
        $row.Phone | Should -Be '+15145550100'
        $row.Negative | Should -Be '-1'
        $row.Number | Should -Be '-1'
        $row.Flag | Should -Be 'True'
        $row.Empty | Should -BeNullOrEmpty
    }

    It 'builds a snapshot that respects the format' {
        InModuleScope TenantConverge {
            $script:TcCollection = [ordered]@{}
            Select-TcCollectionTenant -Role Target
            Add-TcTable 'domains' @([ordered]@{ Domain = 'a.example'; Verified = $true })
            $snapshot = Get-TcCollectionSnapshot -ProjectName 'Summit' -Started '2026-01-15T08:00:00' -Finished '2026-01-15T09:00:00'
            @(Test-TcSnapshot -Snapshot $snapshot) | Should -BeNullOrEmpty
            $snapshot['tenants']['Target']['displayName'] | Should -Be 'Summit Holdings'
        }
    }
}

Describe 'Collector list' {
    BeforeAll {
        $script:Dictionary = Get-Content (Join-Path $Source 'Data/tables.json') -Raw | ConvertFrom-Json -AsHashtable
        $script:Collectors = InModuleScope TenantConverge { @(Get-TcCollector) }
        $files = @(Get-ChildItem (Join-Path $Source 'Private/Collect') -Filter 'Get-Tc*Collector.ps1' | Where-Object Name -NE 'Get-TcCollector.ps1')
        $script:CollectorAst = foreach ($file in $files) { [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null) }
        $script:TableCalls = @($CollectorAst | ForEach-Object {
                $_.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-TcTable' }, $true)
            })
    }

    It 'keeps all 56 collectors of the old inventory' {
        $Collectors.Count | Should -Be 56
        @($Collectors.Id | Group-Object | Where-Object Count -GT 1) | Should -BeNullOrEmpty
    }

    It 'splits collectors by workload, one file each' {
        $workloads = @($Collectors | ForEach-Object { $_['Workload'] } | Select-Object -Unique)
        $workloads | Should -Be @('Entra ID', 'Exchange Online', 'Domains and DNS', 'SharePoint and OneDrive', 'Teams', 'Teams Phone', 'Intune', 'Purview', 'Power Platform', 'Azure', 'Other services')
        @(Get-ChildItem (Join-Path $Source 'Private/Collect') -Filter 'Get-Tc*Collector.ps1' | Where-Object Name -NE 'Get-TcCollector.ps1').Count | Should -Be 11
    }

    It 'names the collectors of the dictionary, and only those' {
        $declared = @($Dictionary.tables | ForEach-Object { $_.collectors } | Sort-Object -Unique)
        $real = @($Collectors | ForEach-Object { $_['Id'] } | Sort-Object)
        $declared | Should -Be @($real | Where-Object { $_ -in $declared })
        # AUT-05-like collectors that keep no table do not exist: every collector feeds at least one table.
        $declared.Count | Should -Be 56
    }

    It 'writes every table of the dictionary, and no other' {
        $written = @($TableCalls | ForEach-Object { $_.CommandElements[1].Value } | Sort-Object -Unique)
        $expected = @($Dictionary.tables.key | Sort-Object)
        $written | Should -Be $expected
    }

    It 'reads only tables of the dictionary' {
        $reads = @($CollectorAst | ForEach-Object {
                $_.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-TcTable' }, $true)
            } | ForEach-Object { $_.CommandElements[1].Value } | Sort-Object -Unique)
        @($reads | Where-Object { $_ -notin $Dictionary.tables.key }) | Should -BeNullOrEmpty
    }

    It 'requires only tables another collector writes first' {
        $seen = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($collector in $Collectors) {
            foreach ($table in @($collector['Requires'] | Where-Object { $_ })) {
                $table | Should -BeIn $Dictionary.tables.key
                $producers = @(($Dictionary.tables | Where-Object key -EQ $table).collectors)
                @($producers | Where-Object { $seen.Contains($_) }).Count | Should -BeGreaterThan 0 -Because "$($collector['Id']) needs $table"
            }
            [void]$seen.Add($collector['Id'])
        }
    }

    It 'writes only columns of the dictionary' {
        $known = [System.Collections.Generic.HashSet[string]]::new([string[]]@($Dictionary.tables | ForEach-Object { $_.columns }))
        $keys = @($CollectorAst | ForEach-Object {
                $_.FindAll({ param($n) $n -is [Management.Automation.Language.ConvertExpressionAst] -and $n.Type.TypeName.Name -eq 'ordered' }, $true)
            } | ForEach-Object { $_.Child.KeyValuePairs } | ForEach-Object { $_.Item1.Value } | Sort-Object -Unique)
        $settings = 'CsOnlineDialInConferencingTenantSettings', 'CsTeamsAcsFederationConfiguration', 'CsTeamsClientConfiguration', 'CsTeamsGuestCallingConfiguration',
            'CsTeamsGuestMeetingConfiguration', 'CsTeamsGuestMessagingConfiguration', 'CsTeamsMeetingConfiguration', 'CsTenantFederationConfiguration', 'AntiPhishPolicy',
            'HostedConnectionFilterPolicy', 'HostedContentFilterPolicy', 'HostedOutboundSpamFilterPolicy', 'MalwareFilterPolicy', 'QuarantinePolicy', 'SafeAttachmentPolicy', 'SafeLinksPolicy',
            'Administrative template', 'Configuration', 'Endpoint security', 'Proactive remediation', 'Script', 'Settings catalog'
        @($keys | Where-Object { -not $known.Contains($_) -and $_ -notin $settings }) | Should -BeNullOrEmpty
    }

    It 'has a title and a service on every collector' {
        foreach ($collector in $Collectors) {
            $collector['Title'] | Should -Not -BeNullOrEmpty
            $collector['Service'] | Should -BeIn @('Graph', 'Exo', 'Ipps', 'Teams', 'Pnp', 'Azure', 'PowerPlatform', 'None')
            $collector['Collect'] | Should -BeOfType [scriptblock]
        }
    }

    It 'keeps collector code in plain English text' {
        $bad = Get-ChildItem (Join-Path $Source 'Private/Collect') -Filter '*.ps1' | Select-String -Pattern '[^\x00-\x7F]'
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'Public DNS' {
    BeforeAll {
        # Answers like the real command: a name with no record, a query that fails, or a record.
        function global:Resolve-DnsName {
            [CmdletBinding()]
            param($Name, $Type, [switch]$DnsOnly, [switch]$NoHostsFile, $Server)
            $global:TcDnsCalls.Add("$Name|$Type|$Server")
            switch (& $global:TcDnsAnswer $Name $Type $Server) {
                'NoSuchName' {
                    $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                            [System.ComponentModel.Win32Exception]::new(9003, "$Name : DNS name does not exist."),
                            'DNS_ERROR_RCODE_NAME_ERROR,Microsoft.DnsClient.Commands.ResolveDnsName', 'ResourceUnavailable', $Name))
                }
                'Timeout' {
                    $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                            [System.ComponentModel.Win32Exception]::new(1460, "$Name : This operation returned because the timeout period expired."),
                            'ERROR_TIMEOUT,Microsoft.DnsClient.Commands.ResolveDnsName', 'OperationTimeout', $Name))
                }
                'Empty' { return }
                default {
                    [pscustomobject]@{ Type = $Type; NameHost = 'ns.host.example'; NameExchange = 'mx.host.example'; Preference = 10; Strings = @($(if ($Name -like '_dmarc.*') { 'v=DMARC1; p=reject' } else { 'v=spf1 -all' })); TTL = 300; NameTarget = 'sip.host.example'; Port = 5061 }
                }
            }
        }

        function Invoke-TcDnsCollector {
            <# Runs DNS-01 on one domain of the target and returns its coverage line. #>
            InModuleScope TenantConverge {
                Add-TcTable 'domains' @([ordered]@{ Domain = 'summit.example'; Verified = $true })
                $collector = @(Get-TcCollector | Where-Object { $_['Id'] -eq 'DNS-01' })[0]
                Invoke-TcCollector -Collector $collector -Role Target
            }
        }

        function Get-TcDnsSummary { InModuleScope TenantConverge { @(Get-TcTable 'dnsSummary')[0] } }
    }

    AfterAll {
        Remove-Item -Path 'Function:\Resolve-DnsName' -ErrorAction SilentlyContinue
        Remove-Variable -Name TcDnsAnswer, TcDnsCalls -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Write-TcLog -ModuleName TenantConverge
        Mock Connect-TcService -ModuleName TenantConverge
        Mock Test-TcServiceModule -ModuleName TenantConverge { @{ ok = $true } }
        Initialize-TcTestCollection
        $global:TcDnsCalls = [System.Collections.Generic.List[string]]::new()
    }

    It 'reads a name with no such record as an answer: Missing, status OK' {
        $global:TcDnsAnswer = { param($Name, $Type, $Server) if ($Name -like '_dmarc.*') { 'NoSuchName' } elseif ($Type -eq 'TXT') { 'Empty' } else { 'Record' } }
        (Invoke-TcDnsCollector)['status'] | Should -Be 'OK'
        $row = Get-TcDnsSummary
        $row['SPF'] | Should -Be 'Missing'
        $row['DMARC'] | Should -Be 'Missing'
    }

    It 'never reads SPF or DMARC as Missing when the query failed' {
        $global:TcDnsAnswer = { param($Name, $Type, $Server) if ($Type -eq 'TXT') { 'Timeout' } else { 'Record' } }
        $line = Invoke-TcDnsCollector
        $line['status'] | Should -Be 'Partial'
        $line['message'] | Should -Match 'summit\.example'
        $row = Get-TcDnsSummary
        $row['SPF'] | Should -Be 'Unknown'
        $row['DMARC'] | Should -Be 'Unknown'
        $row['Microsoft SPF'] | Should -BeNullOrEmpty
        $row['MX'] | Should -Be 'mx.host.example'
    }

    It 'never reads no MX, no DKIM or no Autodiscover from a failed query' {
        $global:TcDnsAnswer = { param($Name, $Type, $Server) if ($Type -in 'MX', 'CNAME', 'SRV') { 'Timeout' } else { 'Record' } }
        Invoke-TcDnsCollector | Out-Null
        $row = Get-TcDnsSummary
        $row['Inbound mail flow'] | Should -Be 'Unknown'
        $row['Autodiscover'] | Should -Be 'Unknown'
        $row['DKIM published'] | Should -BeNullOrEmpty
        $row['Teams or legacy Skype'] | Should -BeNullOrEmpty
        $row['Intune enrollment'] | Should -BeNullOrEmpty
    }

    It 'fires no SPF or DMARC finding on an unknown value' {
        $row = @{ Domain = 'summit.example'; SPF = 'Unknown'; DMARC = 'Unknown'; 'MX TTL' = $null; 'DNS host' = 'Unknown'; 'Inbound mail flow' = 'Unknown' }
        . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')
        $ids = @((Invoke-TcRuleSet -Snapshot (New-TcRuleSnapshot -Given @{ S1 = @{ dnsSummary = @($row) } }))['findings'] | ForEach-Object { $_['id'] })
        $ids | Should -Not -Contain 'DNS-SPF'
        $ids | Should -Not -Contain 'DNS-DMARC'
    }

    It 'falls back to the system resolver when the server cannot be reached, and says so' {
        $global:TcDnsAnswer = { param($Name, $Type, $Server) if ($Server) { 'Timeout' } else { 'Record' } }
        $line = Invoke-TcDnsCollector
        $line['status'] | Should -Be 'OK'
        $line['message'] | Should -Match 'system resolver'
        (Get-TcDnsSummary)['SPF'] | Should -Be 'v=spf1 -all'
    }

    It 'stops asking a server that does not answer' {
        $global:TcDnsAnswer = { param($Name, $Type, $Server) if ($Server) { 'Timeout' } else { 'Record' } }
        Invoke-TcDnsCollector | Out-Null
        @($global:TcDnsCalls | Where-Object { $_ -match '\|1\.1\.1\.1$' }).Count | Should -Be 1
    }

    It 'reports a total failure through the coverage and leaves no empty table' {
        $global:TcDnsAnswer = { param($Name, $Type, $Server) 'Timeout' }
        $line = Invoke-TcDnsCollector
        $line['status'] | Should -Be 'Failed'
        $line['message'] | Should -Match 'summit\.example'
        $line['remedy'] | Should -Not -BeNullOrEmpty
        InModuleScope TenantConverge {
            $script:TcCurrentTenant['tables'].Contains('publicDns') | Should -BeFalse
            $script:TcCurrentTenant['tables'].Contains('dnsSummary') | Should -BeFalse
        }
    }

    It 'keeps the domains that answered when another one fails entirely' {
        $global:TcDnsAnswer = { param($Name, $Type, $Server) if ($Name -match 'broken') { 'Timeout' } else { 'Record' } }
        $line = InModuleScope TenantConverge {
            Add-TcTable 'domains' @([ordered]@{ Domain = 'summit.example'; Verified = $true }, [ordered]@{ Domain = 'broken.example'; Verified = $true })
            $collector = @(Get-TcCollector | Where-Object { $_['Id'] -eq 'DNS-01' })[0]
            Invoke-TcCollector -Collector $collector -Role Target
        }
        $line['status'] | Should -Be 'Partial'
        InModuleScope TenantConverge { @(Get-TcTable 'dnsSummary' | ForEach-Object { $_['Domain'] }) | Should -Be 'summit.example' }
    }
}

Describe 'Read-only guard' {
    BeforeAll {
        function Find-TcWriteCall {
            <# Lists every call that could change a tenant in a piece of code. #>
            param([Parameter(Mandatory)][string]$Code)

            $found = [System.Collections.Generic.List[string]]::new()
            $ast = [Management.Automation.Language.Parser]::ParseInput($Code, [ref]$null, [ref]$null)
            $local = '^(New-(Item|Object|TemporaryFile|TimeSpan)|Set-(Content|StrictMode|Location|Variable|Item)|Remove-(Item|Variable)|Add-(Content|Member|Type)|Update-(TypeData|FormatData)|Enable-|Disable-)$'
            $signIn = '^(Add-PowerAppsAccount|Set-AzContext)$'
            # The only calls of these verbs the assessment may use. The web calls are also checked below.
            $webReads = 'Invoke-MgGraphRequest', 'Invoke-RestMethod', 'Invoke-WebRequest', 'Invoke-PnPSPRestMethod'
            $allowed = @($webReads) + 'Start-Sleep', 'Move-Item', 'Invoke-Item'
            $ownFunctions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object Name)

            foreach ($call in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
                $name = $call.GetCommandName()
                if (-not $name) {
                    # A dynamic command: only a Get- is allowed.
                    if ($call.InvocationOperator -ne 'None' -and $call.CommandElements[0] -is [Management.Automation.Language.ExpandableStringExpressionAst] -and $call.CommandElements[0].Value -notmatch '^Get-') {
                        $found.Add($call.Extent.Text)
                    }
                    continue
                }
                if ($name -in $ownFunctions) { continue }
                if ($name -match '^(New|Set|Remove|Add|Update|Grant|Revoke|Enable|Disable|Register|Unregister|Invoke|Send|Start|Clear|Move)-' -and $name -notmatch '-Tc' -and $name -notmatch $local -and $name -notmatch $signIn -and $name -notin $allowed) {
                    $found.Add($name)
                }
                if ($name -in $webReads) {
                    # Graph must say GET. The others default to it, so a method is only checked when given. A splat hides it.
                    $text = $call.Extent.Text
                    $isGet = $text -match '-Method[:\s]+[''"]?GET\b'
                    if ($text -match '\s@\w' -or ($name -eq 'Invoke-MgGraphRequest' -and -not $isGet) -or ($text -match '-Method\b' -and -not $isGet)) { $found.Add($text) }
                }
            }

            # Code handed to another process is held in here-strings: it is checked the same way.
            $hereStrings = $ast.FindAll({
                    param($n)
                    ($n -is [Management.Automation.Language.StringConstantExpressionAst] -or $n -is [Management.Automation.Language.ExpandableStringExpressionAst]) -and
                    $n.StringConstantType -in 'SingleQuotedHereString', 'DoubleQuotedHereString'
                }, $true)
            foreach ($string in $hereStrings) {
                foreach ($item in Find-TcWriteCall -Code $string.Value) { $found.Add($item) }
            }
            $found
        }

        $script:WriterFiles = 'Initialize-TcAccess.ps1', 'Remove-TcAccess.ps1'
        # The scripts and the engine of the remediations write on purpose, behind their confirmations.
        $script:ReadOnlyFiles = @(Get-ChildItem $Source -Filter '*.ps1' -Recurse | Where-Object { $_.Name -notin $WriterFiles -and $_.FullName -notmatch '[/\\]Remediation[/\\]' })
    }

    It 'catches a planted write' -TestCases @(
        @{ Code = 'Set-Mailbox -Identity x' }
        @{ Code = 'New-MgUser -DisplayName x' }
        @{ Code = 'Remove-PnPSite -Identity x' }
        @{ Code = 'Add-MailboxPermission -Identity x' }
        @{ Code = 'Update-MgGroup -GroupId x' }
        @{ Code = 'Grant-CsTeamsMeetingPolicy -Identity x' }
        @{ Code = 'Revoke-AzRoleAssignment x' }
        @{ Code = 'Enable-AzContextAutosave -Scope Process; Disable-Mailbox x' }
        @{ Code = 'Invoke-MgGraphRequest -Method POST -Uri x' }
        @{ Code = 'Invoke-MgGraphRequest -Uri x' }
        @{ Code = 'Invoke-MgGraphRequest @request' }
        @{ Code = 'Invoke-MgInviteUser -BodyParameter x' }
        @{ Code = 'Invoke-PnPSPRestMethod -Method Post -Url x' }
        @{ Code = 'Invoke-PnPSPRestMethod -Method:Delete -Url x' }
        @{ Code = 'Invoke-RestMethod -Uri x -Method Patch' }
        @{ Code = 'Invoke-RestMethod @request' }
        @{ Code = 'Invoke-WebRequest -Uri x -Method ''Post''' }
        @{ Code = 'Send-MgUserMail -UserId x' }
        @{ Code = 'Send-MailMessage -To x' }
        @{ Code = 'Start-ManagedFolderAssistant -Identity x' }
        @{ Code = 'Clear-MobileDevice -Identity x' }
        @{ Code = 'Move-CsUser -Identity x' }
        @{ Code = '& "Set-$kind" -Identity x' }
        @{ Code = '$code = @''
Set-Mailbox -Identity x
''@' }
        @{ Code = '$code = @"
Set-Mailbox -Identity x
"@' }
        @{ Code = '$code = @"
Set-Mailbox -Identity $name
"@' }
    ) {
        @(Find-TcWriteCall -Code $Code).Count | Should -BeGreaterThan 0
    }

    It 'lets reads through' {
        Find-TcWriteCall -Code 'Get-Mailbox; New-Item x; Set-Content x y; Add-TcTable x; & "Get-$kind"; Invoke-MgGraphRequest -Method GET -Uri x' | Should -BeNullOrEmpty
    }

    It 'lets the read calls of its allow list through' {
        Find-TcWriteCall -Code 'Invoke-RestMethod -Uri x -TimeoutSec 20; Invoke-RestMethod -Method Get -Uri x; Invoke-PnPSPRestMethod -Method Get -Url x; Invoke-PnPSPRestMethod -Url x; Invoke-WebRequest -Uri x; Start-Sleep -Seconds 1; Move-Item a b' | Should -BeNullOrEmpty
    }

    It 'fails on the real code as soon as a write is planted in it' {
        $collector = @($ReadOnlyFiles | Where-Object Name -EQ 'Get-TcDnsCollector.ps1')[0]
        $code = Get-Content $collector.FullName -Raw
        @(Find-TcWriteCall -Code $code) | Should -BeNullOrEmpty
        @(Find-TcWriteCall -Code ($code + "`nSend-MgUserMail -UserId x")) | Should -Be 'Send-MgUserMail'

        $azure = @($ReadOnlyFiles | Where-Object Name -EQ 'Get-TcAzureCollector.ps1')[0]
        $code = Get-Content $azure.FullName -Raw
        @(Find-TcWriteCall -Code $code) | Should -BeNullOrEmpty
        $planted = $code.Replace("`$ErrorActionPreference = 'Stop'", "Start-AzVM -Name x`n`$ErrorActionPreference = 'Stop'")
        $planted | Should -Not -Be $code
        @(Find-TcWriteCall -Code $planted) | Should -Be 'Start-AzVM'
    }

    It 'finds no write in the assessment code' {
        $ReadOnlyFiles.Count | Should -BeGreaterThan 50
        foreach ($file in $ReadOnlyFiles) {
            @(Find-TcWriteCall -Code (Get-Content $file.FullName -Raw)) | Should -BeNullOrEmpty -Because $file.Name
        }
    }

    It 'exempts only the remediation folders and the access commands' {
        $exempt = @(Get-ChildItem $Source -Filter '*.ps1' -Recurse | Where-Object FullName -NotIn $ReadOnlyFiles.FullName)
        @($exempt | Where-Object { $_.Name -notin $WriterFiles -and $_.FullName -notmatch '[/\\](Private[/\\])?Remediation[/\\]' }) | Should -BeNullOrEmpty
        $ReadOnlyFiles.Name | Should -Contain 'Invoke-TcRemediation.ps1'
        $ReadOnlyFiles.Name | Should -Contain 'Undo-TcRemediation.ps1'
        $ReadOnlyFiles.Name | Should -Contain 'Get-TcRemediation.ps1'
    }

    It 'gives the Graph read helper no way to choose a method' {
        (Get-Command Invoke-TcGraphRead -Module TenantConverge -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
        InModuleScope TenantConverge { (Get-Command Invoke-TcGraphRead).Parameters.Keys | Should -Not -Contain 'Method' }
    }

    It 'keeps the rule list of the plan' {
        foreach ($verb in 'New', 'Set', 'Remove', 'Add', 'Update', 'Grant', 'Revoke', 'Enable', 'Disable', 'Invoke', 'Send', 'Start', 'Clear', 'Move') {
            @(Find-TcWriteCall -Code "$verb-MgThing -Id x").Count | Should -Be 1 -Because $verb
        }
    }
}

Describe 'Every collector under strict mode' {
    BeforeAll {
        # Sparse answers: a read of a field that is not there must not stop a collector.
        $script:Sparse = [pscustomobject]@{
            Name = 'Fictional'; DisplayName = 'Fictional'; Title = 'Fictional'; Identity = 'Global'; Id = 'id-1'; GroupId = 'group-1'; Url = 'https://summit.sharepoint.com/sites/a'
            SiteUrl = 'https://summit.sharepoint.com/sites/a'; PrimarySmtpAddress = 'a@summit.example'; UserPrincipalName = 'a@summit.example'; RecipientTypeDetails = 'UserMailbox'
            ArchiveStatus = 'Active'; EmailAddresses = @('smtp:a@summit.example'); Role = 'owner'; MembershipType = 'Standard'; DomainName = 'summit.example'
        }

        $files = @(Get-ChildItem (Join-Path $Source 'Private/Collect') -Filter 'Get-Tc*Collector.ps1' | Where-Object Name -NE 'Get-TcCollector.ps1')
        $names = [System.Collections.Generic.HashSet[string]]::new()
        foreach ($file in $files) {
            $ast = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($call in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)) {
                $name = $call.GetCommandName()
                if ($name -and $name -notmatch '-Tc' -and -not (Get-Command $name -CommandType Cmdlet, Function, Alias -Module Microsoft.PowerShell.* -ErrorAction SilentlyContinue)) { [void]$names.Add($name) }
            }
        }
        foreach ($extra in 'Get-HostedContentFilterPolicy', 'Get-SafeLinksPolicy', 'Get-CsTenantFederationConfiguration', 'Get-CsTeamsMeetingPolicy', 'Get-CsTeamsMessagingPolicy') { [void]$names.Add($extra) }
        foreach ($skip in 'Get-Command', 'Write-Verbose', 'Where-Object', 'ForEach-Object', 'Select-Object', 'Sort-Object', 'Measure-Object', 'Group-Object', 'Out-Null', 'Import-Csv',
            'Get-Date', 'Get-Content', 'Set-Content', 'Remove-Item', 'Test-Path', 'Join-Path', 'Start-Sleep', 'powershell.exe', 'pwsh', 'Invoke-MgGraphRequest', 'ConvertFrom-Json', 'Add-Member') { [void]$names.Remove($skip) }

        $script:StubNames = @($names)
        foreach ($name in $script:StubNames) {
            Set-Item -Path "Function:\global:$name" -Value {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments)]$Rest, $Top, $Skip, $First)
                $global:TcSparse
            }
        }
        $global:TcSparse = $script:Sparse

        function global:Invoke-MgGraphRequest {
            [CmdletBinding()]
            param($Method, $Uri, $Body, $ContentType, $OutputType, $OutputFilePath, $Headers)
            if ($Method -ne 'GET') { throw "Refused: $Method" }
            if ($global:TcGraphRefused -and $Uri -match $global:TcGraphRefused) { throw '403 Forbidden' }
            if ($global:TcGraphPaged -and $Uri -match $global:TcGraphPaged) { return @{ value = @(@{ id = 'id-1' }); '@odata.nextLink' = $Uri } }
            if ($OutputFilePath) {
                Set-Content -LiteralPath $OutputFilePath -Value "Report Refresh Date,User Principal Name,Site URL`n2026-01-01,a@summit.example,https://summit.sharepoint.com/"
                return
            }
            if ($Uri -match '/\$count$') { return '3' }
            @{ value = @(@{ id = 'id-1'; displayName = 'Fictional' }); id = 'id-1' }
        }

        function global:Resolve-DnsName {
            [CmdletBinding()]
            param($Name, $Type, [switch]$DnsOnly, [switch]$NoHostsFile, $Server)
            [pscustomobject]@{ Type = $Type; NameHost = 'host.example'; NameExchange = 'mx.example'; Preference = 10; Strings = @('v=spf1 -all'); TTL = 3600; NameTarget = 'sip.example'; Port = 5061 }
        }
    }

    AfterAll {
        foreach ($name in $script:StubNames + 'Resolve-DnsName') { Remove-Item -Path "Function:\$name" -ErrorAction SilentlyContinue }
        Remove-Variable -Name TcSparse, TcGraphRefused, TcGraphPaged -Scope Global -ErrorAction SilentlyContinue
    }

    It 'survives sparse answers, keeps to the dictionary and reports no strict mode error' {
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Connect-TcService -ModuleName TenantConverge
        Mock Test-TcServiceModule -ModuleName TenantConverge { @{ ok = $true } }
        Mock Start-Sleep -ModuleName TenantConverge
        Initialize-TcTestCollection -Depth Complete

        $results = InModuleScope TenantConverge {
            $script:TcTenants['Target']['tenantId'] = 'id-t'
            foreach ($collector in @(Get-TcCollector | Where-Object { $_['Service'] -notin 'PowerPlatform', 'Azure' })) {
                Invoke-TcCollector -Collector $collector -Role Target -Rank 1 -Total 1
            }
        }

        $results.Count | Should -Be 54
        $broken = @($results | Where-Object { $_['message'] -match 'cannot be found on this object|Cannot index into|null-valued|null array|outside the bounds|not set to an instance' -or $_['status'] -eq 'Failed' })
        ($broken | ForEach-Object { "$($_['id']): $($_['status']) $($_['message'])" }) | Should -BeNullOrEmpty

        $snapshotProblems = InModuleScope TenantConverge {
            @(Test-TcSnapshot -Snapshot (Get-TcCollectionSnapshot -ProjectName 'Summit' -Started 'x' -Finished 'y'))
        }
        ($snapshotProblems | ForEach-Object { $_.Message }) | Should -BeNullOrEmpty
    }

    Context 'A read refused inside a collector' {
        BeforeEach {
            Mock Write-TcMessage -ModuleName TenantConverge
            Mock Write-TcLog -ModuleName TenantConverge
            Mock Connect-TcService -ModuleName TenantConverge
            Mock Test-TcServiceModule -ModuleName TenantConverge { @{ ok = $true } }
            Initialize-TcTestCollection -Depth Complete
        }

        It '<Id> does not read OK when <Refused> is refused' -ForEach @(
            @{ Id = 'EXO-08'; Refused = 'Get-InboxRule'; Label = 'Inbox rules of' }
            @{ Id = 'EXO-03'; Refused = 'Get-DistributionGroupMember'; Label = 'Members of' }
            @{ Id = 'PUR-03'; Refused = 'Get-CaseHoldPolicy'; Label = 'Holds of' }
            @{ Id = 'SPO-01'; Refused = 'Get-PnPHomeSite'; Label = 'Home site' }
            @{ Id = 'SPO-04'; Refused = 'Get-PnPTerm'; Label = 'Terms of' }
            @{ Id = 'ENT-03'; Refused = 'subscribedSkus'; Label = 'License names' }
            @{ Id = 'ENT-04'; Refused = 'members/\$count'; Label = 'Member count of' }
            @{ Id = 'ENT-07'; Refused = 'identitySynchronization'; Label = 'Identity synchronization' }
            @{ Id = 'ENT-07'; Refused = 'findTenantInformationByTenantId'; Label = 'Name of partner' }
            @{ Id = 'ENT-12'; Refused = 'select=appRoles'; Label = 'Permission names' }
            @{ Id = 'AUT-03'; Refused = 'planner/plans'; Label = 'Plans of' }
        ) {
            $command = if ($Refused -like 'Get-*') { Get-Command $Refused -CommandType Function }
            $original = if ($command) { $command.ScriptBlock }
            try {
                if ($command) {
                    Set-Item -Path "Function:\global:$Refused" -Value {
                        [CmdletBinding()]
                        param([Parameter(ValueFromRemainingArguments)]$Rest)
                        throw '403 Forbidden'
                    }
                }
                else { $global:TcGraphRefused = $Refused }

                $line = InModuleScope TenantConverge -Parameters @{ Id = $Id } {
                    param($Id)
                    Add-TcTable 'mailboxes' @([ordered]@{ Name = 'Ana'; Type = 'UserMailbox'; 'Primary address' = 'a@summit.example' })
                    Add-TcTable 'acceptedDomains' @([ordered]@{ Domain = 'summit.example' })
                    Add-TcTable 'groups' @([ordered]@{ Id = 'g1'; Name = 'Finance'; Type = 'Microsoft 365' })
                    Add-TcTable 'servicePrincipals' @([ordered]@{ Id = 's1'; Name = 'Vendor'; Origin = 'Third party' })
                    $collector = @(Get-TcCollector | Where-Object { $_['Id'] -eq $Id })[0]
                    Invoke-TcCollector -Collector $collector -Role Target
                }
            }
            finally {
                $global:TcGraphRefused = $null
                if ($command) { Set-Item -Path "Function:\global:$Refused" -Value $original }
            }

            $line['status'] | Should -Not -Be 'OK'
            $line['message'] | Should -Match $Label
        }
    }

    Context 'A row limit reached' {
        BeforeEach {
            Mock Write-TcMessage -ModuleName TenantConverge
            Mock Write-TcLog -ModuleName TenantConverge
            Mock Connect-TcService -ModuleName TenantConverge
            Mock Test-TcServiceModule -ModuleName TenantConverge { @{ ok = $true } }
            Initialize-TcTestCollection -Depth Complete
            function Invoke-TcLimitedCollector {
                param([string]$Id, [string]$Limit, [int]$Value)
                InModuleScope TenantConverge -Parameters @{ Id = $Id; Limit = $Limit; Value = $Value } {
                    param($Id, $Limit, $Value)
                    $script:TcCollectionSettings[$Limit] = $Value
                    Add-TcTable 'mailboxes' @([ordered]@{ Type = 'UserMailbox'; 'Primary address' = 'a@summit.example' }, [ordered]@{ Type = 'UserMailbox'; 'Primary address' = 'b@summit.example' })
                    Add-TcTable 'acceptedDomains' @([ordered]@{ Domain = 'summit.example' })
                    Add-TcTable 'teams' @([ordered]@{ Id = 't1'; Name = 'One' }, [ordered]@{ Id = 't2'; Name = 'Two' })
                    Add-TcTable 'groups' @([ordered]@{ Id = 'g1'; Name = 'One'; Type = 'Microsoft 365' }, [ordered]@{ Id = 'g2'; Name = 'Two'; Type = 'Microsoft 365' })
                    Add-TcTable 'servicePrincipals' @([ordered]@{ Id = 's1'; Name = 'One'; Origin = 'Third party' }, [ordered]@{ Id = 's2'; Name = 'Two'; Origin = 'Internal' })
                    Add-TcTable 'sites' @([ordered]@{ Url = 'https://summit.sharepoint.com/sites/a'; Template = 'STS#0' }, [ordered]@{ Url = 'https://summit.sharepoint.com/sites/b'; Template = 'STS#0' })
                    Add-TcTable 'teamsUsers' @([ordered]@{ UPN = 'a@summit.example'; 'Enterprise Voice' = $true }, [ordered]@{ UPN = 'b@summit.example'; 'Enterprise Voice' = $true })
                    $collector = @(Get-TcCollector | Where-Object { $_['Id'] -eq $Id })[0]
                    Invoke-TcCollector -Collector $collector -Role Target
                }
            }
        }

        It '<Id> reads Partial and says so when <Limit> cuts its rows' -ForEach @(
            @{ Id = 'EXO-08'; Limit = 'maxInboxRuleMailboxes'; Value = 1 }
            @{ Id = 'EXO-10'; Limit = 'maxPublicFolders'; Value = 1 }
            @{ Id = 'TMS-02'; Limit = 'maxTeamDetails'; Value = 1 }
            @{ Id = 'ENT-04'; Limit = 'maxGroupMemberCounts'; Value = 0 }
            @{ Id = 'ENT-12'; Limit = 'maxPermissionApps'; Value = 1 }
            @{ Id = 'SPO-06'; Limit = 'maxSiteDetails'; Value = 1 }
            @{ Id = 'TEL-05'; Limit = 'maxCallingUsers'; Value = 1 }
            @{ Id = 'AUT-03'; Limit = 'maxPlannerGroups'; Value = 1 }
        ) {
            $line = Invoke-TcLimitedCollector $Id $Limit $Value
            $line['status'] | Should -Be 'Partial'
            $line['message'] | Should -Match 'Limit reached'
            $line['remedy'] | Should -Not -BeNullOrEmpty
        }

        It 'SPO-07 reads Partial when the pages stop at maxExternalUsers' {
            $original = (Get-Command Get-PnPExternalUser -CommandType Function).ScriptBlock
            Set-Item -Path 'Function:\global:Get-PnPExternalUser' -Value {
                [CmdletBinding()]
                param([Parameter(ValueFromRemainingArguments)]$Rest)
                1..50 | ForEach-Object { $global:TcSparse }
            }
            try { $line = Invoke-TcLimitedCollector 'SPO-07' 'maxExternalUsers' 50 }
            finally { Set-Item -Path 'Function:\global:Get-PnPExternalUser' -Value $original }
            $line['status'] | Should -Be 'Partial'
            $line['message'] | Should -Match 'Limit reached'
        }

        It 'ENT-11 reads Partial when the sign-ins stop at maxSignInPages' {
            $global:TcGraphPaged = 'auditLogs/signIns'
            try { $line = Invoke-TcLimitedCollector 'ENT-11' 'maxSignInPages' 1 }
            finally { $global:TcGraphPaged = $null }
            $line['status'] | Should -Be 'Partial'
            $line['message'] | Should -Match 'Limit reached'
        }

        It 'keeps an empty table when the limit cut what could have filled it' {
            Invoke-TcLimitedCollector 'EXO-08' 'maxInboxRuleMailboxes' 1 | Out-Null
            InModuleScope TenantConverge { $script:TcCurrentTenant['tables'].Contains('inboxRules') | Should -BeTrue }
        }

        It 'stays OK when the rows just fit' {
            (Invoke-TcLimitedCollector 'EXO-08' 'maxInboxRuleMailboxes' 2)['status'] | Should -Be 'OK'
        }

        It 'keeps the worse status of a collector that also failed' {
            $original = (Get-Command Get-InboxRule -CommandType Function).ScriptBlock
            Set-Item -Path 'Function:\global:Get-InboxRule' -Value { [CmdletBinding()] param([Parameter(ValueFromRemainingArguments)]$Rest) throw '403 Forbidden' }
            try { $line = Invoke-TcLimitedCollector 'EXO-08' 'maxInboxRuleMailboxes' 1 }
            finally { Set-Item -Path 'Function:\global:Get-InboxRule' -Value $original }
            $line['status'] | Should -Be 'Insufficient access'
            $line['message'] | Should -Match 'Limit reached'
        }
    }

    Context 'Power Platform and Azure, which run in their own process' {
        BeforeAll {
            function global:powershell.exe {
                param([Parameter(ValueFromRemainingArguments)]$Rest)
                $file = $Rest[[array]::IndexOf($Rest, '-OutFile') + 1]
                $global:TcChildAnswer | Set-Content -LiteralPath $file
            }
            function global:pwsh {
                param([Parameter(ValueFromRemainingArguments)]$Rest)
                $file = $Rest[[array]::IndexOf($Rest, '-OutFile') + 1]
                $global:TcChildAnswer | Set-Content -LiteralPath $file
            }
        }

        AfterAll {
            foreach ($name in 'powershell.exe', 'pwsh') { Remove-Item -Path "Function:\$name" -ErrorAction SilentlyContinue }
            Remove-Variable -Name TcChildAnswer -Scope Global -ErrorAction SilentlyContinue
        }

        BeforeEach {
            Mock Write-TcMessage -ModuleName TenantConverge
            Mock Connect-TcService -ModuleName TenantConverge
            Mock Test-TcServiceModule -ModuleName TenantConverge { @{ ok = $true } }
            Initialize-TcTestCollection
        }

        It 'reads Power Platform and resolves names' {
            $global:TcChildAnswer = '{"errors":[],"environments":[{"Name":"Prod","Id":"e1","Type":"Production","Region":"canada","IsDefault":false,"Dataverse":"Standard","Created":"2025"}],"apps":[{"Name":"Claims","Environment":"e1","Owner":"a@summit.example","Modified":"2025"}],"flows":[{"Name":"Approve","Environment":"e1","Owner":"u1","Enabled":true,"Modified":"2025"}],"dlp":[{"Name":"Tenant","Scope":"All","Environments":""}]}'
            $line = InModuleScope TenantConverge {
                Add-TcTable 'users' @([ordered]@{ Id = 'u1'; UPN = 'a@summit.example' })
                $collector = @(Get-TcCollector | Where-Object { $_['Id'] -eq 'POW-01' })[0]
                $line = Invoke-TcCollector -Collector $collector -Role Target
                @(Get-TcTable 'powerFlows')[0]['Owner'] | Should -Be 'a@summit.example'
                @(Get-TcTable 'powerApps')[0]['Environment'] | Should -Be 'Prod'
                @(Get-TcTable 'powerEnvironments')[0]['Dataverse'] | Should -BeTrue
                $line
            }
            $line.status | Should -Be 'OK'
            $line.rows | Should -BeGreaterThan 3
        }

        It 'marks Power Platform partial when one list was refused, and leaves that table out' {
            $global:TcChildAnswer = '{"errors":["Flows: 403 Forbidden"],"environments":[{"Name":"Prod","Id":"e1","Type":"Production","Region":"canada","IsDefault":false,"Dataverse":"None","Created":"2025"}]}'
            InModuleScope TenantConverge {
                $collector = @(Get-TcCollector | Where-Object { $_['Id'] -eq 'POW-01' })[0]
                $line = Invoke-TcCollector -Collector $collector -Role Target
                $line['status'] | Should -Be 'Partial'
                $script:TcCurrentTenant['tables'].Contains('powerFlows') | Should -BeFalse
            }
        }

        It 'refuses the Power Platform window in an unattended run' {
            InModuleScope TenantConverge {
                $script:TcUnattended = $true
                $collector = @(Get-TcCollector | Where-Object { $_['Id'] -eq 'POW-01' })[0]
                $line = Invoke-TcCollector -Collector $collector -Role Target
                $script:TcUnattended = $false
                $line['status'] | Should -Be 'Insufficient access'
                $script:TcCurrentTenant['tables'].Contains('powerEnvironments') | Should -BeFalse
            }
        }

        It 'reads no visible subscription as not collected, since it cannot be told from no subscription' {
            $global:TcChildAnswer = '{"subscriptions":[],"resources":[],"errors":[]}'
            InModuleScope TenantConverge {
                $collector = @(Get-TcCollector | Where-Object { $_['Id'] -eq 'AZR-01' })[0]
                $line = Invoke-TcCollector -Collector $collector -Role Target
                $line['status'] | Should -Be 'Insufficient access'
                $line['message'] | Should -Match 'No subscription is visible'
                $line['message'] | Should -Not -Match 'NOTCONFIGURED'
                $line['remedy'] | Should -Match '-ExtendedAccess Azure'
                $script:TcCurrentTenant['tables'].Contains('azureSubscriptions') | Should -BeFalse
                $script:TcCurrentTenant['tables'].Contains('azureResources') | Should -BeFalse
            }
        }

        It 'says the same of a read-only application with no Azure role, or with one that sees nothing' -ForEach @(
            @{ Granted = $false; Text = 'it has no Azure role' }
            @{ Granted = $true; Text = 'although it received the Reader role' }
        ) {
            $global:TcChildAnswer = '{"subscriptions":[],"resources":[],"errors":[]}'
            InModuleScope TenantConverge -Parameters @{ Granted = $Granted; Text = $Text } {
                param($Granted, $Text)
                Mock Get-TcApplicationAuth { @{ clientId = 'app'; thumbprint = 'AB12' } }
                Mock Test-TcApplicationGrant { $Granted }
                $collector = @(Get-TcCollector | Where-Object { $_['Id'] -eq 'AZR-01' })[0]
                $line = Invoke-TcCollector -Collector $collector -Role Target
                $line['status'] | Should -Be 'Insufficient access'
                $line['message'] | Should -Match $Text
                $line['remedy'] | Should -Match '-ExtendedAccess Azure'
            }
        }

        It 'reads Azure subscriptions and resources' {
            $global:TcChildAnswer = '{"subscriptions":[{"Name":"Main","Id":"s1","State":"Enabled","Assignments":3}],"resources":[{"Subscription":"Main","Type":"Microsoft.Compute/virtualMachines","Count":2,"Regions":"canadacentral"}],"errors":[]}'
            InModuleScope TenantConverge {
                $collector = @(Get-TcCollector | Where-Object { $_['Id'] -eq 'AZR-01' })[0]
                Invoke-TcCollector -Collector $collector -Role Target | Out-Null
                @(Get-TcTable 'azureSubscriptions')[0]['RBAC assignments'] | Should -Be 3
                @(Get-TcTable 'azureResources')[0]['Count'] | Should -Be 2
            }
        }
    }
}

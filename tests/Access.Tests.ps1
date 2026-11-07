BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/ServiceStubs.ps1')

    $script:TargetId = '11111111-1111-4111-8111-111111111111'
    $script:SourceId = '22222222-2222-4222-8222-222222222222'

    function Set-TcTestSession {
        param([string]$Mode = 'Browser', [hashtable]$Access = @{}, [switch]$Unattended, $TargetTenantId = $null)
        InModuleScope TenantConverge -Parameters @{ Mode = $Mode; Access = $Access; Unattended = [bool]$Unattended; Id = $TargetTenantId } {
            param($Mode, $Access, $Unattended, $Id)
            $project = [pscustomobject]@{
                target  = [pscustomobject]@{ displayName = 'Summit Holdings'; primaryDomain = 'summit.example'; tenantId = $Id }
                sources = @([pscustomobject]@{ role = 'S1'; displayName = 'Alpine Group'; primaryDomain = 'alpine.example'; tenantId = $null })
                access  = [pscustomobject]@{ mode = $Mode }
            }
            Initialize-TcSession -Project $project -Access $Access -Unattended:$Unattended
        }
    }

    function Get-TcGraphAnswer {
        param([string]$TenantId = $script:TargetId, [string]$Domain = 'summit.example')
        @{ value = @(@{
                    id              = $TenantId
                    displayName     = 'Summit Holdings'
                    verifiedDomains = @(
                        @{ name = $Domain; isInitial = $false }
                        @{ name = 'summit.onmicrosoft.com'; isInitial = $true }
                    )
                }) }
    }
}

AfterAll {
    Remove-TcServiceStub
}

Describe 'Get-TcTenantId' {
    It 'reads the tenant from the sign-in metadata of the domain' {
        Mock Invoke-RestMethod -ModuleName TenantConverge {
            [pscustomobject]@{ issuer = "https://login.microsoftonline.com/$($script:TargetId)/v2.0" }
        }
        InModuleScope TenantConverge -Parameters @{ Expected = $script:TargetId } {
            param($Expected)
            Get-TcTenantId -Domain 'summit.example' | Should -Be $Expected
        }
        Should -Invoke Invoke-RestMethod -ModuleName TenantConverge -ParameterFilter { $Uri -like '*/summit.example/v2.0/.well-known/openid-configuration' }
    }

    It 'stops when the domain has no tenant' {
        Mock Invoke-RestMethod -ModuleName TenantConverge { [pscustomobject]@{ issuer = 'https://elsewhere.example/' } }
        InModuleScope TenantConverge {
            { Get-TcTenantId -Domain 'nowhere.example' } | Should -Throw '*No tenant was found*'
        }
    }
}

Describe 'Connect-TcTenant' {
    BeforeEach {
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Write-TcLog -ModuleName TenantConverge
        Mock Invoke-RestMethod -ModuleName TenantConverge { [pscustomobject]@{ issuer = "https://login.microsoftonline.com/$($script:TargetId)/v2.0" } }
        Mock Connect-MgGraph -ModuleName TenantConverge
        Mock Disconnect-MgGraph -ModuleName TenantConverge
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge { Get-TcGraphAnswer }
    }

    It 'signs in with read scopes in Browser mode' {
        Set-TcTestSession
        InModuleScope TenantConverge { Connect-TcTenant -Role Target }
        Should -Invoke Connect-MgGraph -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter {
            $TenantId -eq $script:TargetId -and $Scopes -contains 'User.Read.All' -and -not (@($Scopes) -match 'ReadWrite')
        }
    }

    It 'uses the application and its certificate in Application mode' {
        Set-TcTestSession -Mode Application -Access @{ Target = @{ clientId = 'app-id'; thumbprint = 'AB12'; grants = @('Graph') } }
        InModuleScope TenantConverge { Connect-TcTenant -Role Target }
        Should -Invoke Connect-MgGraph -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter {
            $ClientId -eq 'app-id' -and $CertificateThumbprint -eq 'AB12' -and $TenantId -eq $script:TargetId
        }
    }

    It 'falls back to the base read scopes when consent is refused' {
        $script:calls = 0
        Mock Connect-MgGraph -ModuleName TenantConverge {
            $script:calls++
            if ($script:calls -eq 1) { throw 'AADSTS65001 consent required' }
        }
        Set-TcTestSession
        InModuleScope TenantConverge { Connect-TcTenant -Role Target }
        Should -Invoke Connect-MgGraph -ModuleName TenantConverge -Times 2 -Exactly
    }

    It 'connects only once for the same tenant' {
        Set-TcTestSession
        InModuleScope TenantConverge { Connect-TcTenant -Role Target; Connect-TcTenant -Role Target }
        Should -Invoke Connect-MgGraph -ModuleName TenantConverge -Times 1 -Exactly
    }

    It 'rejects a sign-in to another tenant' {
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge { Get-TcGraphAnswer -TenantId $script:SourceId }
        Set-TcTestSession
        InModuleScope TenantConverge { { Connect-TcTenant -Role Target } | Should -Throw '*wrong tenant*' }
        Should -Invoke Disconnect-MgGraph -ModuleName TenantConverge
    }

    It 'rejects a tenant that does not own the domain' {
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge { Get-TcGraphAnswer -Domain 'other.example' }
        Set-TcTestSession
        InModuleScope TenantConverge { { Connect-TcTenant -Role Target } | Should -Throw '*summit.example*not a verified domain*' }
    }

    It 'rejects a project tenant ID that does not match the domain' {
        Set-TcTestSession -TargetTenantId $script:SourceId
        InModuleScope TenantConverge { { Connect-TcTenant -Role Target } | Should -Throw '*does not match*' }
        Should -Invoke Connect-MgGraph -ModuleName TenantConverge -Times 0 -Exactly
    }

    It 'remembers the initial domain' {
        Set-TcTestSession
        InModuleScope TenantConverge {
            Connect-TcTenant -Role Target
            $script:TcTenants['Target']['initialDomain'] | Should -Be 'summit.onmicrosoft.com'
        }
    }

    It 'connects Exchange with the initial domain and checks it' {
        Mock Connect-ExchangeOnline -ModuleName TenantConverge
        Mock Get-AcceptedDomain -ModuleName TenantConverge { [pscustomobject]@{ DomainName = 'summit.onmicrosoft.com' } }
        Set-TcTestSession
        InModuleScope TenantConverge { Connect-TcTenant -Role Target -Exchange }
        Should -Invoke Connect-ExchangeOnline -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter { $Organization -eq 'summit.onmicrosoft.com' }
    }

    It 'rejects an Exchange session on another tenant' {
        Mock Connect-ExchangeOnline -ModuleName TenantConverge
        Mock Disconnect-ExchangeOnline -ModuleName TenantConverge
        Mock Get-AcceptedDomain -ModuleName TenantConverge { [pscustomobject]@{ DomainName = 'elsewhere.onmicrosoft.com' } }
        Set-TcTestSession
        InModuleScope TenantConverge { { Connect-TcTenant -Role Target -Exchange } | Should -Throw '*wrong tenant*' }
    }

    It 'refuses a sign-in window in an unattended run' {
        Set-TcTestSession -Unattended
        InModuleScope TenantConverge { { Connect-TcTenant -Role Target } | Should -Throw 'NOTCONFIGURED*' }
        Should -Invoke Connect-MgGraph -ModuleName TenantConverge -Times 0 -Exactly
    }
}

Describe 'Connect-TcService' {
    BeforeEach {
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Connect-TcTenant -ModuleName TenantConverge
        Mock Connect-PnPOnline -ModuleName TenantConverge { 'pnp-connection' }
    }

    It 'does nothing for a collector that needs no service' {
        Set-TcTestSession
        InModuleScope TenantConverge { Connect-TcService -Service None -Role Target }
        Should -Invoke Connect-TcTenant -ModuleName TenantConverge -Times 0 -Exactly
    }

    It 'reports SharePoint as not configured without a PnP application' {
        Set-TcTestSession
        InModuleScope TenantConverge {
            $script:TcTenants['Target']['initialDomain'] = 'summit.onmicrosoft.com'
            { Connect-TcService -Service Pnp -Role Target } | Should -Throw 'NOTCONFIGURED*PnP*'
        }
        Should -Invoke Connect-PnPOnline -ModuleName TenantConverge -Times 0 -Exactly
    }

    It 'uses the delegated PnP application of the tenant' {
        Set-TcTestSession -Access @{ Target = @{ pnpClientId = 'pnp-app' } }
        InModuleScope TenantConverge {
            $script:TcTenants['Target']['initialDomain'] = 'summit.onmicrosoft.com'
            Connect-TcService -Service Pnp -Role Target
            $script:TcPnpConnection | Should -Be 'pnp-connection'
        }
        Should -Invoke Connect-PnPOnline -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter {
            $Url -eq 'https://summit-admin.sharepoint.com' -and $ClientId -eq 'pnp-app' -and $Interactive
        }
    }

    It 'uses the read-only application when SharePoint was granted' {
        Set-TcTestSession -Mode Application -Access @{ Target = @{ clientId = 'app-id'; thumbprint = 'AB12'; grants = @('Graph', 'SharePoint') } }
        InModuleScope TenantConverge {
            $script:TcTenants['Target']['initialDomain'] = 'summit.onmicrosoft.com'
            Connect-TcService -Service Pnp -Role Target
        }
        Should -Invoke Connect-PnPOnline -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter {
            $ClientId -eq 'app-id' -and $Thumbprint -eq 'AB12' -and $Tenant -eq 'summit.onmicrosoft.com'
        }
    }

    It 'refuses a PnP sign-in window in an unattended run' {
        Set-TcTestSession -Unattended -Access @{ Target = @{ pnpClientId = 'pnp-app' } }
        InModuleScope TenantConverge {
            $script:TcTenants['Target']['initialDomain'] = 'summit.onmicrosoft.com'
            { Connect-TcService -Service Pnp -Role Target } | Should -Throw 'NOTCONFIGURED*'
        }
    }

    Context 'Purview in a browser' {
        BeforeEach {
            Mock Connect-IPPSSession -ModuleName TenantConverge
            Mock Disconnect-ExchangeOnline -ModuleName TenantConverge
            Set-TcTestSession -TargetTenantId $script:TargetId
            InModuleScope TenantConverge { $script:TcActive['Exo'] = 'Target' }
            # The Exchange session of the same tenant comes first: it must not stand in for the Purview one.
            $script:ExchangeLine = [pscustomobject]@{ ConnectionUri = 'https://outlook.office365.com'; TenantID = $script:TargetId }
        }

        It 'accepts a session on the tenant of the role' {
            Mock Get-ConnectionInformation -ModuleName TenantConverge {
                $script:ExchangeLine
                [pscustomobject]@{ ConnectionUri = 'https://nam01b.ps.compliance.protection.outlook.com'; TenantID = $script:TargetId }
            }
            InModuleScope TenantConverge {
                Connect-TcService -Service Ipps -Role Target
                $script:TcServiceConnections['Ipps'] | Should -Be 'Target'
            }
        }

        It 'refuses a cached account of another tenant, and closes the session' {
            Mock Get-ConnectionInformation -ModuleName TenantConverge {
                $script:ExchangeLine
                [pscustomobject]@{ ConnectionUri = 'https://nam01b.ps.compliance.protection.outlook.com'; TenantID = $script:SourceId }
            }
            InModuleScope TenantConverge {
                { Connect-TcService -Service Ipps -Role Target } | Should -Throw '*wrong tenant*'
                $script:TcServiceConnections['Ipps'] | Should -BeNullOrEmpty
                $script:TcActive['Exo'] | Should -BeNullOrEmpty
            }
            Should -Invoke Disconnect-ExchangeOnline -ModuleName TenantConverge -Times 1 -Exactly
        }

        It 'refuses a session it cannot check' {
            Mock Get-ConnectionInformation -ModuleName TenantConverge { $script:ExchangeLine }
            InModuleScope TenantConverge { { Connect-TcService -Service Ipps -Role Target } | Should -Throw '*wrong tenant*' }
        }

        It 'leaves the check out with the read-only application, whose organization is explicit' {
            Mock Get-ConnectionInformation -ModuleName TenantConverge { throw 'not expected' }
            Set-TcTestSession -Mode Application -Access @{ Target = @{ clientId = 'app-id'; thumbprint = 'AB12'; grants = @('Graph') } } -TargetTenantId $script:TargetId
            InModuleScope TenantConverge {
                $script:TcTenants['Target']['initialDomain'] = 'summit.onmicrosoft.com'
                Connect-TcService -Service Ipps -Role Target
            }
            Should -Invoke Connect-IPPSSession -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter { $Organization -eq 'summit.onmicrosoft.com' }
        }
    }

    It 'connects Teams and checks the tenant' {
        Mock Connect-MicrosoftTeams -ModuleName TenantConverge
        Mock Get-CsTenant -ModuleName TenantConverge { [pscustomobject]@{ TenantId = 'other-tenant' } }
        Set-TcTestSession
        InModuleScope TenantConverge {
            $script:TcTenants['Target']['tenantId'] = 'expected-tenant'
            { Connect-TcService -Service Teams -Role Target } | Should -Throw '*wrong tenant*'
        }
    }
}

Describe 'Graph reads' {
    BeforeEach {
        Mock Start-Sleep -ModuleName TenantConverge
    }

    It 'follows the next link and returns every row' {
        $script:page = 0
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge {
            $script:page++
            if ($script:page -eq 1) { @{ value = @(@{ id = 1 }, @{ id = 2 }); '@odata.nextLink' = 'https://graph.microsoft.com/next' } }
            else { @{ value = @(@{ id = 3 }) } }
        }
        InModuleScope TenantConverge { @(Get-TcGraphList 'v1.0/users').Count | Should -Be 3 }
        Should -Invoke Invoke-MgGraphRequest -ModuleName TenantConverge -Times 2 -Exactly -ParameterFilter { $Method -eq 'GET' }
    }

    It 'adds the Graph address to a relative path' {
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge { @{ id = 'one' } }
        InModuleScope TenantConverge { Get-TcGraphObject 'v1.0/organization' | Out-Null }
        Should -Invoke Invoke-MgGraphRequest -ModuleName TenantConverge -ParameterFilter { $Uri -eq 'https://graph.microsoft.com/v1.0/organization' }
    }

    It 'retries when throttled, waiting for Retry-After when the service sends it' {
        $script:tries = 0
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge {
            $script:tries++
            if ($script:tries -lt 3) { throw 'TooManyRequests: 429 Retry-After: 7' }
            @{ value = @() }
        }
        InModuleScope TenantConverge { Get-TcGraphObject 'v1.0/users' | Out-Null }
        Should -Invoke Invoke-MgGraphRequest -ModuleName TenantConverge -Times 3 -Exactly
        Should -Invoke Start-Sleep -ModuleName TenantConverge -Times 2 -Exactly -ParameterFilter { $Seconds -eq 7 }
    }

    It 'does not retry a refused access' {
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge { throw '403 Forbidden' }
        InModuleScope TenantConverge { { Get-TcGraphObject 'v1.0/users' } | Should -Throw '*Forbidden*' }
        Should -Invoke Invoke-MgGraphRequest -ModuleName TenantConverge -Times 1 -Exactly
    }

    It 'shortens the period of a usage report that times out' {
        $script:reportCalls = [System.Collections.Generic.List[string]]::new()
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge {
            $script:reportCalls.Add($Uri)
            if ($script:reportCalls.Count -eq 1) { throw 'The request timed out' }
            Set-Content -LiteralPath $OutputFilePath -Value "Report Refresh Date,User Principal Name`n2026-01-01,ana@summit.example"
        }
        InModuleScope TenantConverge {
            $script:TcCollectionSettings = @{ reportPeriod = 'D180' }
            $rows = @(Get-TcUsageReport 'getOffice365ActiveUserDetail')
            $rows.Count | Should -Be 1
            $rows[0].'User Principal Name' | Should -Be 'ana@summit.example'
        }
        $script:reportCalls[1] | Should -Match "period='D30'"
    }
}

Describe 'Access file' {
    It 'sits next to the project and git ignores it' {
        InModuleScope TenantConverge {
            Get-TcAccessPath -ProjectPath 'C:\work\project.json' | Should -Be 'C:\work\project.access.local.json'
        }
        $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
        git -C $root check-ignore -q 'project.access.local.json'
        $LASTEXITCODE | Should -Be 0
    }

    It 'returns nothing when the file does not exist' {
        $path = Join-Path $TestDrive 'none.json'
        InModuleScope TenantConverge -Parameters @{ Path = $path } {
            param($Path)
            (Read-TcAccessFile -ProjectPath $Path).Count | Should -Be 0
        }
    }

    It 'keeps each tenant apart and reads them back' {
        $path = Join-Path $TestDrive 'first.json'
        InModuleScope TenantConverge -Parameters @{ Path = $path } {
            param($Path)
            Write-TcAccessEntry -ProjectPath $Path -Role Target -Entry @{ clientId = 'a' }
            Write-TcAccessEntry -ProjectPath $Path -Role S1 -Entry @{ clientId = 'b' }
            $read = Read-TcAccessFile -ProjectPath $Path
            $read['Target']['clientId'] | Should -Be 'a'
            $read['S1']['clientId'] | Should -Be 'b'
            Write-TcAccessEntry -ProjectPath $Path -Role S1 -Entry $null
            (Read-TcAccessFile -ProjectPath $Path).Contains('S1') | Should -BeFalse
        }
    }
}

Describe 'Initialize-TcAccess' {
    BeforeAll {
        function New-TcTestGraph {
            <# A small fictional directory. Writes are recorded so tests can list them. #>
            $script:GraphWrites = [System.Collections.Generic.List[string]]::new()
            $script:GraphBodies = [System.Collections.Generic.List[string]]::new()
        }
    }

    BeforeEach {
        New-TcTestGraph
        $projectPath = New-TcTestProject -Folder $TestDrive -Mode Application
        Remove-Item (Join-Path $TestDrive 'project.access.local.json') -ErrorAction SilentlyContinue

        $script:certificate = [pscustomobject]@{ Thumbprint = 'AB12CD'; NotAfter = [datetime]'2027-01-01' } |
            Add-Member -MemberType ScriptMethod -Name GetCertHash -Value { [byte[]](1, 2, 3) } -PassThru
        $script:certificate | Add-Member -NotePropertyName RawData -NotePropertyValue ([byte[]](4, 5, 6))

        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Get-TcReadCertificate -ModuleName TenantConverge { $script:certificate }
        Mock Invoke-RestMethod -ModuleName TenantConverge { [pscustomobject]@{ issuer = "https://login.microsoftonline.com/$($script:TargetId)/v2.0" } }
        Mock Connect-MgGraph -ModuleName TenantConverge
        Mock Disconnect-MgGraph -ModuleName TenantConverge
        Mock Get-MgContext -ModuleName TenantConverge { [pscustomobject]@{ Account = 'admin@summit.example' } }
        Mock Invoke-TcAccessVerification -ModuleName TenantConverge { 0 }
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge {
            if ($Method -ne 'GET') {
                $script:GraphWrites.Add("$Method $($Uri -replace 'https://graph.microsoft.com/', '')")
                $script:GraphBodies.Add([string]$Body)
                if ($Uri -match '/applications$') { return @{ id = 'object-id'; appId = 'new-app-id' } }
                if ($Uri -match '/servicePrincipals$') { return @{ id = 'principal-id' } }
                return @{}
            }
            switch -Regex ($Uri) {
                '/organization$' { return (Get-TcGraphAnswer) }
                '/applications\?' { return @{ value = @() } }
                '/applications/object-id' { return @{ keyCredentials = @() } }
                "servicePrincipals\?.*00000003-0000-0000-c000-000000000000" {
                    return @{ value = @(@{ id = 'graph-sp'; appRoles = @(@{ id = 'role-user'; value = 'User.Read.All'; allowedMemberTypes = @('Application') }) }) }
                }
                "servicePrincipals\?.*00000002-0000-0ff1-ce00-000000000000" {
                    return @{ value = @(@{ id = 'exo-sp'; appRoles = @(@{ id = 'role-exo'; value = 'Exchange.ManageAsApp'; allowedMemberTypes = @('Application') }) }) }
                }
                "servicePrincipals\?.*00000007-0000-0ff1-ce00-000000000000" {
                    return @{ value = @(@{ id = 'eop-sp'; appRoles = @(@{ id = 'role-eop'; value = 'Exchange.ManageAsApp'; allowedMemberTypes = @('Application') }) }) }
                }
                "servicePrincipals\?.*00000003-0000-0ff1-ce00-000000000000" {
                    return @{ value = @(@{ id = 'spo-sp'; appRoles = @(@{ id = 'role-spo'; value = 'Sites.FullControl.All'; allowedMemberTypes = @('Application') }) }) }
                }
                'servicePrincipals\?' { return @{ value = @() } }
                'appRoleAssignments' { return @{ value = @() } }
                'roleAssignments' { return @{ value = @() } }
                default { throw "Unexpected read: $Uri" }
            }
        }
    }

    It 'creates the application under its neutral name' {
        Initialize-TcAccess -Project $projectPath -Tenant Target -Confirm:$false
        $script:GraphWrites | Should -Contain 'POST v1.0/applications'
        $script:GraphBodies[0] | Should -Match '"displayName":\s*"TenantConverge Read-Only"'
    }

    It 'grants nothing without -GrantAdminConsent' {
        $result = Initialize-TcAccess -Project $projectPath -Tenant Target -Confirm:$false
        @($script:GraphWrites | Where-Object { $_ -match 'appRoleAssignments|roleAssignments' }) | Should -BeNullOrEmpty
        @($result.Grants).Count | Should -Be 0
        $result.Consent | Should -Be 'Pending'
    }

    It 'grants the read permissions and Global Reader with -GrantAdminConsent' {
        $result = Initialize-TcAccess -Project $projectPath -Tenant Target -GrantAdminConsent -Confirm:$false
        @($script:GraphWrites | Where-Object { $_ -match 'appRoleAssignments$' }).Count | Should -Be 3
        $script:GraphWrites | Should -Contain 'POST v1.0/roleManagement/directory/roleAssignments'
        ($script:GraphBodies -join ' ') | Should -Match 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
        $result.Grants | Should -Be @('Graph', 'Exchange', 'Purview', 'Teams')
    }

    It 'adds Sites.FullControl.All only when SharePoint access is given' {
        Initialize-TcAccess -Project $projectPath -Tenant Target -GrantAdminConsent -Confirm:$false
        ($script:GraphBodies -join ' ') | Should -Not -Match 'role-spo'
        New-TcTestGraph
        $result = Initialize-TcAccess -Project $projectPath -Tenant Target -GrantAdminConsent -ExtendedAccess SharePoint -Confirm:$false
        ($script:GraphBodies -join ' ') | Should -Match 'role-spo'
        $result.Grants | Should -Contain 'SharePoint'
    }

    It 'writes only the application, its permissions and its role' {
        Initialize-TcAccess -Project $projectPath -Tenant Target -GrantAdminConsent -ExtendedAccess SharePoint -Confirm:$false
        $script:GraphWrites | Should -Not -BeNullOrEmpty
        @($script:GraphWrites | Where-Object { $_ -notmatch '^(POST|PATCH|DELETE) v1\.0/(applications|servicePrincipals|roleManagement/directory/roleAssignments)' }) | Should -BeNullOrEmpty
    }

    It 'keeps the identifiers out of project.json' {
        $before = Get-Content $projectPath -Raw
        Initialize-TcAccess -Project $projectPath -Tenant Target -GrantAdminConsent -Confirm:$false
        (Get-Content $projectPath -Raw) | Should -Be $before
        $file = Get-Content (Join-Path $TestDrive 'project.access.local.json') -Raw | ConvertFrom-Json
        $file.tenants.Target.clientId | Should -Be 'new-app-id'
        $file.tenants.Target.thumbprint | Should -Be 'AB12CD'
        $file.tenants.Target.tenantId | Should -Be $script:TargetId
        $file.tenants.Target.initialDomain | Should -Be 'summit.onmicrosoft.com'
    }

    It 'changes nothing under -WhatIf' {
        Initialize-TcAccess -Project $projectPath -Tenant Target -GrantAdminConsent -WhatIf
        Should -Invoke Connect-MgGraph -ModuleName TenantConverge -Times 0 -Exactly
        $script:GraphWrites.Count | Should -Be 0
        Test-Path (Join-Path $TestDrive 'project.access.local.json') | Should -BeFalse
    }

    Context 'an application already carries the name' {
        BeforeEach {
            $script:AppDetails = @{ keyCredentials = @(); passwordCredentials = @() }
            Mock Invoke-MgGraphRequest -ModuleName TenantConverge {
                if ($Method -ne 'GET') { $script:GraphWrites.Add("$Method $Uri"); return @{} }
                switch -Regex ($Uri) {
                    '/organization$' { return (Get-TcGraphAnswer) }
                    '/applications\?' { return @{ value = @(@{ id = 'object-id'; appId = 'existing-app' }) } }
                    '/applications/object-id' { return $script:AppDetails }
                    default { return @{ value = @(@{ id = 'found'; appRoles = @() }) } }
                }
            }
        }

        It 'reuses it when this project created it' {
            InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
                param($Path)
                Write-TcAccessEntry -ProjectPath $Path -Role Target -Entry @{ clientId = 'existing-app'; thumbprint = 'AB12CD'; tenantId = 'id' }
            }
            $result = Initialize-TcAccess -Project $projectPath -Tenant Target -Confirm:$false
            $result.ApplicationId | Should -Be 'existing-app'
            @($script:GraphWrites | Where-Object { $_ -match 'POST .*/applications$' }) | Should -BeNullOrEmpty
        }

        It 'stops and writes nothing when this project did not create it' {
            $result = Initialize-TcAccess -Project $projectPath -Tenant Target -GrantAdminConsent -Confirm:$false
            $result.Consent | Should -Be 'Failed'
            $script:GraphWrites.Count | Should -Be 0
            Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'existing-app' -and $Message -match 'did not create' }
        }

        It 'stops and writes nothing when the project knows another application' {
            InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
                param($Path)
                Write-TcAccessEntry -ProjectPath $Path -Role Target -Entry @{ clientId = 'another-app'; thumbprint = 'AB12CD'; tenantId = 'id' }
            }
            $result = Initialize-TcAccess -Project $projectPath -Tenant Target -GrantAdminConsent -Confirm:$false
            $result.Consent | Should -Be 'Failed'
            $script:GraphWrites.Count | Should -Be 0
        }

        It 'stops and writes nothing when its application holds a client secret' {
            InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
                param($Path)
                Write-TcAccessEntry -ProjectPath $Path -Role Target -Entry @{ clientId = 'existing-app'; thumbprint = 'AB12CD'; tenantId = 'id' }
            }
            $script:AppDetails = @{ keyCredentials = @(); passwordCredentials = @(@{ displayName = 'added later' }) }
            $result = Initialize-TcAccess -Project $projectPath -Tenant Target -GrantAdminConsent -Confirm:$false
            $result.Consent | Should -Be 'Failed'
            $script:GraphWrites.Count | Should -Be 0
            Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'credential' }
        }

        It 'stops and writes nothing when its application holds a key it did not add' {
            InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
                param($Path)
                Write-TcAccessEntry -ProjectPath $Path -Role Target -Entry @{ clientId = 'existing-app'; thumbprint = 'AB12CD'; tenantId = 'id' }
            }
            $script:AppDetails = @{ keyCredentials = @(@{ displayName = 'CN=someone else' }); passwordCredentials = @() }
            $result = Initialize-TcAccess -Project $projectPath -Tenant Target -GrantAdminConsent -Confirm:$false
            $result.Consent | Should -Be 'Failed'
            $script:GraphWrites.Count | Should -Be 0
        }

        It 'keeps an older certificate of its own, so that a renewal goes through' {
            InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
                param($Path)
                Write-TcAccessEntry -ProjectPath $Path -Role Target -Entry @{ clientId = 'existing-app'; thumbprint = 'OLD'; tenantId = 'id' }
            }
            $subject = & (Get-Module TenantConverge) { $script:TcCertificateSubject }
            $script:AppDetails = @{ keyCredentials = @(@{ displayName = $subject }); passwordCredentials = @() }
            $result = Initialize-TcAccess -Project $projectPath -Tenant Target -Confirm:$false
            $result.ApplicationId | Should -Be 'existing-app'
        }
    }

    It 'remembers a new application at once, so that a run stopped halfway can go on' {
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge {
            if ($Method -ne 'GET') {
                if ($Uri -match '/applications$') { return @{ id = 'object-id'; appId = 'new-app-id' } }
                throw 'Service unavailable'
            }
            switch -Regex ($Uri) {
                '/organization$' { return (Get-TcGraphAnswer) }
                default { return @{ value = @() } }
            }
        }
        (Initialize-TcAccess -Project $projectPath -Tenant Target -Confirm:$false).Consent | Should -Be 'Failed'
        InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
            param($Path)
            (Read-TcAccessFile -ProjectPath $Path)['Target']['clientId'] | Should -Be 'new-app-id'
        }
    }

    Context '-DelegatedPnP' {
        BeforeEach {
            Mock Invoke-TcAdminProcess -ModuleName TenantConverge { @{ clientId = 'pnp-app' } }
        }

        It 'registers the PnP application and nothing else in a browser project' {
            $browser = New-TcTestProject -Folder $TestDrive -Mode Browser
            $result = Initialize-TcAccess -Project $browser -Tenant Target -DelegatedPnP -Confirm:$false
            $result.ApplicationId | Should -Be 'pnp-app'
            $result.Consent | Should -Be 'Delegated'
            $script:GraphWrites.Count | Should -Be 0
            Should -Invoke Get-TcReadCertificate -ModuleName TenantConverge -Times 0 -Exactly
            Should -Invoke Invoke-TcAccessVerification -ModuleName TenantConverge -Times 0 -Exactly
            Should -Invoke Connect-MgGraph -ModuleName TenantConverge -ParameterFilter { -not ($Scopes -match 'ReadWrite') }
            Should -Invoke Invoke-TcAdminProcess -ModuleName TenantConverge -Times 1 -Exactly
        }

        It 'saves what a later SharePoint read needs, in a browser project' {
            $browser = New-TcTestProject -Folder $TestDrive -Mode Browser
            Initialize-TcAccess -Project $browser -Tenant Target -DelegatedPnP -Confirm:$false | Out-Null
            InModuleScope TenantConverge -Parameters @{ Path = $browser } {
                param($Path)
                $entry = (Read-TcAccessFile -ProjectPath $Path)['Target']
                $entry['pnpClientId'] | Should -Be 'pnp-app'
                $entry['initialDomain'] | Should -Not -BeNullOrEmpty
                Get-TcProperty $entry 'clientId' | Should -BeNullOrEmpty
                Get-TcProperty $entry 'thumbprint' | Should -BeNullOrEmpty
            }
        }

        It 'comes on top of the read-only application in an application project' {
            Initialize-TcAccess -Project $projectPath -Tenant Target -DelegatedPnP -Confirm:$false | Out-Null
            $script:GraphWrites | Should -Contain 'POST v1.0/applications'
            Should -Invoke Invoke-TcAdminProcess -ModuleName TenantConverge -Times 1 -Exactly
        }

        It 'changes nothing under -WhatIf in a browser project' {
            $browser = New-TcTestProject -Folder $TestDrive -Mode Browser
            Initialize-TcAccess -Project $browser -Tenant Target -DelegatedPnP -WhatIf
            Should -Invoke Connect-MgGraph -ModuleName TenantConverge -Times 0 -Exactly
            Should -Invoke Invoke-TcAdminProcess -ModuleName TenantConverge -Times 0 -Exactly
        }
    }

    It 'rejects a sign-in to another tenant before it writes anything' {
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge {
            if ($Method -ne 'GET') { $script:GraphWrites.Add("$Method $Uri") }
            Get-TcGraphAnswer -TenantId $script:SourceId
        }
        $result = Initialize-TcAccess -Project $projectPath -Tenant Target -Confirm:$false -ErrorAction SilentlyContinue
        $script:GraphWrites.Count | Should -Be 0
        $result.Consent | Should -Be 'Failed'
    }

    It 'continues with the next tenant when one fails' {
        $projectPath = New-TcTestProject -Folder $TestDrive -Mode Application -SourceCount 1
        Mock Connect-MgGraph -ModuleName TenantConverge { if ($TenantId -eq $script:SourceId) { throw 'declined' } }
        Mock Invoke-RestMethod -ModuleName TenantConverge {
            $id = if ($Uri -match 'alpine') { $script:SourceId } else { $script:TargetId }
            [pscustomobject]@{ issuer = "https://login.microsoftonline.com/$id/v2.0" }
        }
        $results = @(Initialize-TcAccess -Project $projectPath -Confirm:$false -ErrorAction SilentlyContinue)
        $results.Count | Should -Be 2
        ($results | Where-Object Role -EQ 'S1').Consent | Should -Be 'Failed'
        ($results | Where-Object Role -EQ 'Target').Consent | Should -Be 'Pending'
    }

    It 'tells the administrator not to consent for the organization in the sign-in window' {
        Initialize-TcAccess -Project $projectPath -Tenant Target -Confirm:$false
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Message -match 'Do not tick' }
    }

    It 'verifies without creating anything' {
        Mock Test-TcTenantAccess -ModuleName TenantConverge { [pscustomobject]@{ Tenant = 'Summit Holdings'; Service = 'Graph'; Result = 'OK' } }
        $rows = @(Initialize-TcAccess -Project $projectPath -Tenant Target -Verify)
        $rows.Count | Should -Be 1
        Should -Invoke Connect-MgGraph -ModuleName TenantConverge -Times 0 -Exactly
        $script:GraphWrites.Count | Should -Be 0
    }
}

Describe 'Application permissions' {
    It 'asks only for read permissions' {
        InModuleScope TenantConverge {
            $all = @(Get-TcApplicationPermission) + @(Get-TcGraphScope -Kind Assessment) + @(Get-TcGraphScope -Kind Base)
            $all.Count | Should -BeGreaterThan 30
            @($all | Where-Object { $_ -notmatch '\.Read(Basic)?(\.|$)' }) | Should -BeNullOrEmpty
        }
    }

    It 'uses the application form of a delegated-only permission' {
        InModuleScope TenantConverge {
            @(Get-TcApplicationPermission) | Should -Contain 'Tasks.Read.All'
            @(Get-TcApplicationPermission) | Should -Not -Contain 'Tasks.Read'
        }
    }
}

Describe 'Test-TcTenantAccess' {
    BeforeEach {
        Mock Start-Sleep -ModuleName TenantConverge
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Connect-MgGraph -ModuleName TenantConverge
        Mock Disconnect-MgGraph -ModuleName TenantConverge
        Mock Disconnect-MicrosoftTeams -ModuleName TenantConverge
        Mock Disconnect-ExchangeOnline -ModuleName TenantConverge
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge { Get-TcGraphAnswer }
    }

    It 'says when a tenant has no application yet' {
        InModuleScope TenantConverge {
            $row = Test-TcTenantAccess -Tenant ([ordered]@{ role = 'Target'; displayName = 'Summit'; primaryDomain = 'summit.example' }) -Service Graph
            $row.Result | Should -Be 'Not initialized'
        }
    }

    It 'retries while permissions propagate and reports the result' {
        $script:attempts = 0
        Mock Connect-MgGraph -ModuleName TenantConverge {
            $script:attempts++
            if ($script:attempts -lt 2) { throw 'not ready yet' }
        }
        InModuleScope TenantConverge {
            $tenant = [ordered]@{
                role = 'Target'; displayName = 'Summit'; primaryDomain = 'summit.example'; tenantId = 'id'; mode = 'Application'
                access = @{ clientId = 'app'; thumbprint = 'AB'; grants = @('Graph'); initialDomain = 'summit.onmicrosoft.com' }
            }
            $row = @(Test-TcTenantAccess -Tenant $tenant -Service Graph)[0]
            $row.Result | Should -Match '^OK'
        }
        Should -Invoke Start-Sleep -ModuleName TenantConverge -Times 1 -Exactly
    }
}

Describe 'Remove-TcAccess' {
    BeforeEach {
        $script:GraphWrites = [System.Collections.Generic.List[string]]::new()
        $projectPath = New-TcTestProject -Folder $TestDrive -Mode Application
        InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
            param($Path)
            Write-TcAccessEntry -ProjectPath $Path -Role Target -Entry @{ clientId = 'app'; thumbprint = 'AB12'; tenantId = 'id' }
        }
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Remove-TcReadCertificate -ModuleName TenantConverge
        Mock Invoke-RestMethod -ModuleName TenantConverge { [pscustomobject]@{ issuer = "https://login.microsoftonline.com/$($script:TargetId)/v2.0" } }
        Mock Connect-MgGraph -ModuleName TenantConverge
        Mock Disconnect-MgGraph -ModuleName TenantConverge
        Mock Get-MgContext -ModuleName TenantConverge { [pscustomobject]@{ Account = 'admin@summit.example' } }
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge {
            if ($Method -ne 'GET') { $script:GraphWrites.Add("$Method $($Uri -replace 'https://graph.microsoft.com/', '')"); return @{} }
            if ($Uri -match '/organization$') { return (Get-TcGraphAnswer) }
            if ($Uri -match 'PnP') { return @{ value = @($script:PnpApplications) } }
            @{ value = @(@{ id = 'object-id'; appId = 'app' }) }
        }
        $script:PnpApplications = @()
    }

    It 'deletes the application and forgets the identifiers' {
        Remove-TcAccess -Project $projectPath -Tenant Target -Confirm:$false
        $script:GraphWrites | Should -Be @('DELETE v1.0/applications/object-id')
        InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
            param($Path)
            (Read-TcAccessFile -ProjectPath $Path).Contains('Target') | Should -BeFalse
        }
    }

    It 'deletes the delegated PnP application too, by the name it was registered with' {
        $script:PnpApplications = @(@{ id = 'pnp-object'; appId = 'pnp-app' })
        InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
            param($Path)
            Write-TcAccessEntry -ProjectPath $Path -Role Target -Entry @{ clientId = 'app'; thumbprint = 'AB12'; tenantId = 'id'; pnpClientId = 'pnp-app' }
        }
        Remove-TcAccess -Project $projectPath -Tenant Target -Confirm:$false
        $script:GraphWrites | Should -Be @('DELETE v1.0/applications/object-id', 'DELETE v1.0/applications/pnp-object')
        Should -Invoke Invoke-MgGraphRequest -ModuleName TenantConverge -ParameterFilter { $Uri -match [regex]::Escape([uri]::EscapeDataString("displayName eq 'TenantConverge PnP'")) }
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -Times 0 -Exactly -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'pnp-app' }
    }

    It 'leaves an application of that name this project did not create, and says so' {
        Mock Invoke-MgGraphRequest -ModuleName TenantConverge {
            if ($Method -ne 'GET') { $script:GraphWrites.Add("$Method $($Uri -replace 'https://graph.microsoft.com/', '')"); return @{} }
            if ($Uri -match '/organization$') { return (Get-TcGraphAnswer) }
            if ($Uri -match 'PnP') { return @{ value = @() } }
            @{ value = @(@{ id = 'object-id'; appId = 'app' }, @{ id = 'other-object'; appId = 'someone-else' }) }
        }
        Remove-TcAccess -Project $projectPath -Tenant Target -Confirm:$false
        $script:GraphWrites | Should -Be @('DELETE v1.0/applications/object-id')
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'someone-else' }
    }

    It 'deletes nothing when the access file knows no application' {
        InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
            param($Path)
            Write-TcAccessEntry -ProjectPath $Path -Role Target -Entry $null
        }
        Remove-TcAccess -Project $projectPath -Tenant Target -Confirm:$false
        $script:GraphWrites.Count | Should -Be 0
    }

    It 'says so when the PnP client ID of the access file is not an application it created' {
        InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
            param($Path)
            Write-TcAccessEntry -ProjectPath $Path -Role Target -Entry @{ clientId = 'app'; thumbprint = 'AB12'; tenantId = 'id'; pnpClientId = 'typed-by-hand' }
        }
        Remove-TcAccess -Project $projectPath -Tenant Target -Confirm:$false
        $script:GraphWrites | Should -Be @('DELETE v1.0/applications/object-id')
        Should -Invoke Write-TcMessage -ModuleName TenantConverge -ParameterFilter { $Level -eq 'Warning' -and $Message -match 'typed-by-hand' }
    }

    It 'registers the PnP application under the name it deletes' {
        Mock Invoke-TcAdminProcess -ModuleName TenantConverge { @{ clientId = 'pnp-app' } }
        InModuleScope TenantConverge -Parameters @{ Path = $projectPath } {
            param($Path)
            Register-TcDelegatedPnP -ProjectPath $Path -Role Target -Tenant ([ordered]@{ displayName = 'Summit'; initialDomain = 'summit.onmicrosoft.com'; access = @{} })
        }
        Should -Invoke Invoke-TcAdminProcess -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter { $Arguments['ApplicationName'] -eq 'TenantConverge PnP' -and $Code -match '-ApplicationName \$ApplicationName' }
    }

    It 'removes the certificate when no tenant uses it any more' {
        Remove-TcAccess -Project $projectPath -Tenant Target -Confirm:$false
        Should -Invoke Remove-TcReadCertificate -ModuleName TenantConverge -Times 1 -Exactly
    }

    It 'changes nothing under -WhatIf' {
        Remove-TcAccess -Project $projectPath -Tenant Target -WhatIf
        $script:GraphWrites.Count | Should -Be 0
        Should -Invoke Connect-MgGraph -ModuleName TenantConverge -Times 0 -Exactly
    }
}

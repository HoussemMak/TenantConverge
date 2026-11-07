BeforeAll {
    # The real connection code, on fake service commands. They live in the module, where its calls find them first.
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    Import-Module (Join-Path $Root 'src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RemediationBench.ps1')
    $snapshot = & (Join-Path $Root 'tools/New-TcFakeSnapshot.ps1') -SourceCount 1 -Seed 3
    $project = New-TcBenchProject -Snapshot $snapshot -Output (Join-Path $TestDrive 'output')
    $script:TenantId = [string]$snapshot['tenants']['Target']['tenantId']
    $script:Module = Get-Module TenantConverge

    & $Module {
        param($Project, $Snapshot)
        $entry = Get-TcRemediationEntry -Id 'SPO-SHARING'
        $script:TcRemediationRun = New-TcRemediationRun -Entry $entry -Project $Project -Snapshot $Snapshot -Plan ([ordered]@{ actions = @() }) -Apply $true -Acknowledged $true -Setting @{ PnpClientId = 'client-id' } -Output (Join-Path $Project.output.path 'run')
        $script:TcFake = @{ TenantId = ''; PnpConnections = 0; TeamsDisconnected = 0; Commands = [System.Collections.Generic.List[string]]::new() }

        function script:Connect-PnPOnline { [CmdletBinding()] param($Url, $ClientId, [switch]$Interactive, [switch]$ReturnConnection) $script:TcFake['PnpConnections']++; [pscustomobject]@{ Url = $Url } }
        function script:Get-PnPTenantId { [CmdletBinding()] param($Connection) $script:TcFake['TenantId'] }
        function script:Connect-MicrosoftTeams { [CmdletBinding()] param($TenantId) }
        function script:Get-CsTenant { [CmdletBinding()] param() [pscustomobject]@{ TenantId = $script:TcFake['TenantId'] } }
        function script:Disconnect-MicrosoftTeams { [CmdletBinding()] param() $script:TcFake['TeamsDisconnected']++ }
        ${function:script:Invoke-TcCommandTransport} = { param([string]$Service, [string]$Command, [hashtable]$Parameters, $Connection) $script:TcFake['Commands'].Add($Command) }
    } $project $snapshot

    function Set-TcFakeTenant {
        param([string]$Id)
        & $Module {
            param($Value)
            $script:TcFake['TenantId'] = $Value; $script:TcFake['PnpConnections'] = 0; $script:TcFake['TeamsDisconnected'] = 0; $script:TcFake['Commands'].Clear()
            $script:TcRemediationRun['Connections'] = @{}
        } $Id
    }

    function Get-TcFake { param([string]$Name) & $Module { param($Key) $script:TcFake[$Key] } $Name }
}

AfterAll {
    Remove-Module TenantConverge -Force -ErrorAction SilentlyContinue
}

Describe 'A connection is read back' {
    It 'reaches the fake commands, never a real one' {
        foreach ($name in 'Connect-PnPOnline', 'Get-PnPTenantId', 'Connect-MicrosoftTeams', 'Get-CsTenant', 'Disconnect-MicrosoftTeams') {
            (& $Module { param($Lookup) Microsoft.PowerShell.Core\Get-Command -Name $Lookup } $name).CommandType | Should -Be 'Function'
        }
    }

    Context 'SharePoint' {
        It 'refuses a session on another tenant, and names what it expected' {
            Set-TcFakeTenant -Id '00000000-0000-0000-0000-000000000099'
            { & $Module { Connect-TcRemediationService -Tenant 'Target' -Service Pnp } } | Should -Throw "*wrong tenant*$TenantId*"
        }

        It 'keeps no session after a refusal' {
            Set-TcFakeTenant -Id '00000000-0000-0000-0000-000000000099'
            try { & $Module { Connect-TcRemediationService -Tenant 'Target' -Service Pnp } } catch { $null = $_ }
            @(& $Module { $script:TcRemediationRun['Connections'].Keys }) | Should -BeNullOrEmpty
        }

        It 'runs no command on a session it refused' {
            Set-TcFakeTenant -Id '00000000-0000-0000-0000-000000000099'
            & $Module { $script:TcRemediationRun['ConfirmedTenants'] = @('Target') }
            { & $Module { Invoke-TcServiceCommand -Tenant 'Target' -Service Pnp -Command 'Set-PnPTenant' } } | Should -Throw '*wrong tenant*'
            Get-TcFake -Name Commands | Should -BeNullOrEmpty
        }

        It 'accepts the tenant of the project, in any case, and connects once' {
            Set-TcFakeTenant -Id $TenantId.ToUpperInvariant()
            & $Module { Connect-TcRemediationService -Tenant 'Target' -Service Pnp } | Should -Not -BeNullOrEmpty
            & $Module { Connect-TcRemediationService -Tenant 'Target' -Service Pnp } | Should -Not -BeNullOrEmpty
            Get-TcFake -Name PnpConnections | Should -Be 1
        }
    }

    Context 'Teams' {
        It 'disconnects before it refuses a session on another tenant' {
            Set-TcFakeTenant -Id '00000000-0000-0000-0000-000000000099'
            { & $Module { Connect-TcRemediationService -Tenant 'Target' -Service Teams } } | Should -Throw '*wrong tenant*'
            Get-TcFake -Name TeamsDisconnected | Should -Be 1
        }

        It 'stays connected on the tenant of the project' {
            Set-TcFakeTenant -Id $TenantId
            & $Module { Connect-TcRemediationService -Tenant 'Target' -Service Teams }
            Get-TcFake -Name TeamsDisconnected | Should -Be 0
            & $Module { $script:TcRemediationRun['Connections']['Teams'] } | Should -Be 'Target'
        }
    }
}

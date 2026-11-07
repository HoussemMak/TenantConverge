Describe 'Test-TcPrerequisite' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    }

    BeforeEach {
        InModuleScope TenantConverge { $script:TcModuleVersions = @{} }
        Mock Write-TcMessage -ModuleName TenantConverge
        Mock Test-TcWindowsPowerShell -ModuleName TenantConverge { $true }
        Mock Install-TcRequiredModule -ModuleName TenantConverge
    }

    It 'reports a module that is present at the minimum version or above' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { [version]'99.0.0' }
        $result = Test-TcPrerequisite -Service Graph
        $result.Ready | Should -BeTrue
        @($result.Modules).Count | Should -Be 1
        $result.Modules[0].Name | Should -Be 'Microsoft.Graph.Authentication'
        $result.Modules[0].Status | Should -Be 'Present'
        @($result.Missing).Count | Should -Be 0
    }

    It 'reports a missing module with its install command and installs nothing' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { $null }
        $result = Test-TcPrerequisite -Service Teams
        $result.Ready | Should -BeFalse
        $teams = $result.Modules | Where-Object Name -EQ 'MicrosoftTeams'
        $teams.Status | Should -Be 'Missing'
        $teams.InstallCommand | Should -Match 'Install-Module MicrosoftTeams -Scope CurrentUser'
        $result.Missing | Should -Contain 'MicrosoftTeams'
        Should -Invoke Install-TcRequiredModule -ModuleName TenantConverge -Times 0 -Exactly
    }

    It 'reports a module older than the minimum and installs nothing' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge {
            if ($Name -eq 'ExchangeOnlineManagement') { [version]'3.0.0' } else { [version]'99.0.0' }
        }
        $result = Test-TcPrerequisite -Service Exo
        $result.Ready | Should -BeFalse
        ($result.Modules | Where-Object Name -EQ 'ExchangeOnlineManagement').Status | Should -Be 'Outdated'
        Should -Invoke Install-TcRequiredModule -ModuleName TenantConverge -Times 0 -Exactly
    }

    It 'only needs the modules of the requested services' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { [version]'99.0.0' }
        $names = @((Test-TcPrerequisite -Service Teams).Modules.Name)
        $names | Should -Contain 'MicrosoftTeams'
        $names | Should -Contain 'Microsoft.Graph.Authentication'
        $names | Should -Not -Contain 'PnP.PowerShell'
    }

    It 'installs a missing module with -Install' {
        $script:installed = $false
        Mock Install-TcRequiredModule -ModuleName TenantConverge { $script:installed = $true }
        Mock Get-TcModuleVersion -ModuleName TenantConverge { if ($script:installed) { [version]'99.0.0' } else { $null } }
        $result = Test-TcPrerequisite -Service Graph -Install
        Should -Invoke Install-TcRequiredModule -ModuleName TenantConverge -Times 1 -Exactly
        $result.Modules[0].Status | Should -Be 'Installed'
        $result.Ready | Should -BeTrue
    }

    It 'updates an outdated module with -Install' {
        $script:installed = $false
        Mock Install-TcRequiredModule -ModuleName TenantConverge { $script:installed = $true }
        Mock Get-TcModuleVersion -ModuleName TenantConverge { if ($script:installed) { [version]'99.0.0' } else { [version]'0.1.0' } }
        (Test-TcPrerequisite -Service Graph -Install).Modules[0].Status | Should -Be 'Updated'
    }

    It 'stays not ready when the installation fails' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { $null }
        Mock Install-TcRequiredModule -ModuleName TenantConverge { throw 'gallery unreachable' }
        $result = Test-TcPrerequisite -Service Graph -Install
        $result.Modules[0].Status | Should -Be 'Failed'
        $result.Ready | Should -BeFalse
    }

    It 'installs nothing under -WhatIf' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { $null }
        $result = Test-TcPrerequisite -Service Graph -Install -WhatIf
        Should -Invoke Install-TcRequiredModule -ModuleName TenantConverge -Times 0 -Exactly
        $result.Ready | Should -BeFalse
    }

    It 'checks Power Platform in Windows PowerShell' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { [version]'99.0.0' }
        $result = Test-TcPrerequisite -Service PowerPlatform
        $result.WindowsPowerShell | Should -BeTrue
        Should -Invoke Get-TcModuleVersion -ModuleName TenantConverge -ParameterFilter {
            $Name -eq 'Microsoft.PowerApps.Administration.PowerShell' -and $WindowsPowerShell
        }
    }

    It 'is not ready when Power Platform needs a missing Windows PowerShell' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { [version]'99.0.0' }
        Mock Test-TcWindowsPowerShell -ModuleName TenantConverge { $false }
        $result = Test-TcPrerequisite -Service PowerPlatform
        $result.WindowsPowerShell | Should -BeFalse
        $result.Ready | Should -BeFalse
        $result.Missing | Should -Contain 'Windows PowerShell 5.1'
    }

    It 'does not ask for Windows PowerShell without Power Platform' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { [version]'99.0.0' }
        Mock Test-TcWindowsPowerShell -ModuleName TenantConverge { $false }
        (Test-TcPrerequisite -Service Graph).Ready | Should -BeTrue
    }

    It 'reports the PowerShell version' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { [version]'99.0.0' }
        (Test-TcPrerequisite -Service Graph).PowerShell | Should -Be ([string]$PSVersionTable.PSVersion)
    }

    It 'caches a module version until asked to refresh' {
        InModuleScope TenantConverge {
            Mock Get-Module { [pscustomobject]@{ Version = [version]'2.0.0' } }
            Get-TcModuleVersion -Name 'Fictional.Module' | Should -Be ([version]'2.0.0')
            Get-TcModuleVersion -Name 'Fictional.Module' | Should -Be ([version]'2.0.0')
            Should -Invoke Get-Module -Times 1 -Exactly
            Get-TcModuleVersion -Name 'Fictional.Module' -Refresh | Should -Be ([version]'2.0.0')
            Should -Invoke Get-Module -Times 2 -Exactly
        }
    }

    It 'keeps the minimum versions of the assessment' {
        InModuleScope TenantConverge {
            $modules = @(Get-TcRequiredModule)
            ($modules | ForEach-Object { '{0} {1}' -f $_['Name'], $_['Minimum'] }) | Should -Be @(
                'Microsoft.Graph.Authentication 2.10.0'
                'ExchangeOnlineManagement 3.7.0'
                'MicrosoftTeams 6.0.0'
                'PnP.PowerShell 2.12.0'
                'Az.Accounts 3.0.0'
                'Az.Resources 7.0.0'
                'Microsoft.PowerApps.Administration.PowerShell 2.0.0'
                'ImportExcel 7.8.10'
            )
        }
    }

    It 'reports ImportExcel as what the workbook needs, and installs nothing' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { $null }
        $result = Test-TcPrerequisite -Service Workbook
        @($result.Modules | ForEach-Object Name) | Should -Be @('ImportExcel')
        $result.Modules[0].Status | Should -Be 'Missing'
        $result.Modules[0].InstallCommand | Should -Match 'Install-Module ImportExcel -Scope CurrentUser'
        $result.Missing | Should -Contain 'ImportExcel'
        Should -Invoke Install-TcRequiredModule -ModuleName TenantConverge -Times 0 -Exactly
    }

    It 'checks ImportExcel by default' {
        Mock Get-TcModuleVersion -ModuleName TenantConverge { [version]'99.0.0' }
        @((Test-TcPrerequisite).Modules | ForEach-Object Name) | Should -Contain 'ImportExcel'
    }

    It 'installs ImportExcel with -Install' {
        $script:installed = $false
        Mock Get-TcModuleVersion -ModuleName TenantConverge { if ($script:installed) { [version]'7.8.10' } else { $null } }
        Mock Install-TcRequiredModule -ModuleName TenantConverge { $script:installed = $true }
        $result = Test-TcPrerequisite -Service Workbook -Install
        $result.Modules[0].Status | Should -Be 'Installed'
        $result.Ready | Should -BeTrue
        Should -Invoke Install-TcRequiredModule -ModuleName TenantConverge -Times 1 -Exactly -ParameterFilter { $Module['Name'] -eq 'ImportExcel' }
    }

    It 'keeps ImportExcel out of what a collector needs' {
        InModuleScope TenantConverge {
            foreach ($service in 'Graph', 'Exo', 'Ipps', 'Teams', 'Pnp', 'Azure', 'PowerPlatform') {
                @(Get-TcRequiredModule -Service $service | ForEach-Object { $_['Name'] }) | Should -Not -Contain 'ImportExcel'
            }
        }
    }
}

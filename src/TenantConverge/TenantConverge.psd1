@{
    RootModule           = 'TenantConverge.psm1'
    ModuleVersion        = '0.9.0'
    GUID                 = '99353b19-e6b5-45a3-849f-41ac72258e8c'
    Author               = 'The TenantConverge Authors'
    CompanyName          = 'The TenantConverge Authors'
    Copyright            = 'Copyright 2026 The TenantConverge Authors. Licensed under Apache-2.0.'
    Description          = 'Prepares the consolidation of 1, 2 or 3 Microsoft 365 source tenants into 1 target tenant: a read-only assessment, a report, a planning workbook, and remediation scripts marked UNTESTED. A beta: it has never run on a real tenant.'
    PowerShellVersion    = '7.4'
    CompatiblePSEditions = @('Core')
    FunctionsToExport    = @('Get-TcReadiness', 'Get-TcRemediation', 'Initialize-TcAccess', 'Invoke-TcAssessment', 'Invoke-TcRemediation', 'Invoke-TcRuleSet', 'New-TcPlan', 'New-TcProject', 'New-TcReport', 'New-TcWorkbook', 'Remove-TcAccess', 'Start-TenantConverge', 'Test-TcPrerequisite', 'Test-TcProject', 'Undo-TcRemediation')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Prerelease   = 'beta1'
            Tags         = @('Microsoft365', 'M365', 'Tenant', 'TenantToTenant', 'Migration', 'Consolidation', 'Assessment', 'EntraID', 'ExchangeOnline', 'SharePoint', 'Teams', 'Windows')
            ProjectUri   = 'https://github.com/HoussemMak/TenantConverge'
            LicenseUri   = 'https://github.com/HoussemMak/TenantConverge/blob/main/LICENSE'
            ReleaseNotes = 'First public version, a beta. Nothing in it has ever run against a real tenant, and each remediation script is marked UNTESTED. See CHANGELOG.md in the project.'
        }
    }
}

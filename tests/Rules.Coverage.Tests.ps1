BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    . (Join-Path $PSScriptRoot 'Support/RuleFixtures.ps1')

    $script:Fired = @{}
    foreach ($count in 1, 2, 3) {
        foreach ($finding in (Invoke-TcRuleSet -Snapshot (Get-TcFakeSnapshot -SourceCount $count -Folder $TestDrive))['findings']) {
            $script:Fired[$finding['id']] = 1
        }
    }
    $script:Catalog = InModuleScope TenantConverge { Get-TcRuleCatalog }
}

Describe 'The fictional data' {
    It 'triggers at least 90 % of the rules' {
        $ratio = $script:Fired.Count / $script:Catalog.Count
        $ratio | Should -BeGreaterOrEqual 0.9 -Because "$($script:Fired.Count) of $($script:Catalog.Count) rules fire"
    }

    It 'only fires rules of the catalog' {
        foreach ($id in $script:Fired.Keys) { $script:Catalog.Contains($id) | Should -BeTrue -Because $id }
    }
}

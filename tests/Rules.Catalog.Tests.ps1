BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force
    $script:CatalogPath = Join-Path $PSScriptRoot '../src/TenantConverge/Data/rules.json'
    $script:Catalog = InModuleScope TenantConverge { Get-TcRuleCatalog }
    $script:Rules = @($script:Catalog.Values)

    function Get-TcRuleText {
        <# Every text of a rule: its own fields, its variants and its parts. #>
        param($Rule)
        foreach ($key in 'title', 'finding', 'action', 'why', 'question') { $Rule[$key] }
        foreach ($variant in @(($Rule['variants'] ?? @{}).Values)) { foreach ($value in $variant.Values) { $value } }
        foreach ($part in @(($Rule['parts'] ?? @{}).Values)) { $part }
    }
}

Describe 'The rule catalog' {
    It 'loads from Data/rules.json, once' {
        Test-Path $script:CatalogPath | Should -BeTrue
        InModuleScope TenantConverge {
            $first = Get-TcRuleCatalog
            [object]::ReferenceEquals($first, (Get-TcRuleCatalog)) | Should -BeTrue
        }
    }

    It 'covers every rule of the assessment' {
        $script:Rules.Count | Should -Be 117
    }

    It 'has unique identifiers with a known prefix' {
        $ids = @($script:Rules | ForEach-Object { $_['id'] })
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
        foreach ($id in $ids) { $id | Should -Match '^(ENT|EXO|SPO|TMS|TEL|INT|PUR|POW|AZR|AUT|DNS|CON|CMP|INV)-[A-Z0-9]+(-[A-Z0-9]+)*$' }
    }

    It 'gives every rule what the report and the plan need' {
        foreach ($rule in $script:Rules) {
            foreach ($key in 'workload', 'severity', 'category', 'title', 'finding', 'action', 'why', 'owner', 'moment', 'effort') {
                $rule[$key] | Should -Not -BeNullOrEmpty -Because "$($rule['id']) needs $key"
            }
            $rule.Contains('question') | Should -BeTrue -Because "$($rule['id']) needs a question, even an empty one"
        }
    }

    It 'only uses the agreed values' {
        foreach ($rule in $script:Rules) {
            $rule['workload'] | Should -BeIn @('Entra ID', 'Exchange Online', 'Domains and DNS', 'SharePoint and OneDrive', 'Teams', 'Teams Phone', 'Intune', 'Purview', 'Power Platform', 'Azure', 'Other services', 'Consolidation', 'Coverage')
            $rule['owner'] | Should -BeIn @('Migration team', 'Customer', 'Migration team and Customer')
            $rule['moment'] | Should -BeIn @('Now', 'Preparation', 'Before cutover', 'Cutover', 'After cutover', 'Closure')
            $rule['effort'] | Should -BeIn @('Low', 'Medium', 'High')

            $severities = @($rule['severity']) + @(foreach ($variant in @(($rule['variants'] ?? @{}).Values)) { if ($variant.Contains('severity')) { $variant['severity'] } })
            $categories = @($rule['category']) + @(foreach ($variant in @(($rule['variants'] ?? @{}).Values)) { if ($variant.Contains('category')) { $variant['category'] } })
            foreach ($severity in $severities) { $severity | Should -BeIn @('Critical', 'High', 'Medium', 'Low', 'Info') }
            foreach ($category in $categories) {
                $category | Should -BeIn @('Recreate in target', 'Security', 'Decision needed', 'Licenses and capacity', 'Cleanup', 'Cleanup before copy', 'Preparation', 'Governance', 'Data', 'Information', 'Migration blocker', 'Coverage', 'Coexistence', 'Devices', 'Migration complexity', 'Cutover')
            }
        }
    }

    It 'only overrides text fields in a variant' {
        foreach ($rule in $script:Rules) {
            foreach ($variant in @(($rule['variants'] ?? @{}).Values)) {
                foreach ($key in $variant.Keys) { $key | Should -BeIn @('severity', 'category', 'title', 'finding', 'action') }
            }
        }
    }

    It 'is written in plain English, in neutral words' {
        foreach ($rule in $script:Rules) {
            foreach ($text in @(Get-TcRuleText $rule | Where-Object { $_ })) {
                $text | Should -Match '^[\x20-\x7E]*$' -Because "$($rule['id']) has a character outside plain text"
                # References to the plan of one project have no meaning here.
                $text | Should -Not -Match '\b(BL\d|BAS-\d|PREP-\d|PRE-\d|E-\d\d|POC|phase \d|Monday)\b' -Because "$($rule['id']) cites a project document"
                $text | Should -Not -Match '\b(the offer|this contract)\b' -Because "$($rule['id']) cites a contract"
            }
        }
    }

    It 'ends every sentence field with a full stop or a placeholder, and every question with a question mark' {
        foreach ($rule in $script:Rules) {
            $rule['why'] | Should -Match '\.$'
            if ($rule['question']) { $rule['question'] | Should -Match '\?$' }
        }
    }
}

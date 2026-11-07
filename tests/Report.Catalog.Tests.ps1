BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../src/TenantConverge/TenantConverge.psd1') -Force

    function Get-Catalog {
        InModuleScope TenantConverge { $copy = Get-Content (Join-Path $PSScriptRoot '../src/TenantConverge/Data/products.json') -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 50; , $copy }
    }

    function Get-Fault {
        param($Catalog)
        InModuleScope TenantConverge -Parameters @{ Catalog = $Catalog } {
            param($Catalog)
            @(Test-TcReportReference -Catalog $Catalog)
        }
    }

    function Get-Fact {
        <# Every dated claim of the catalog, with where it sits. #>
        param($Catalog)
        foreach ($product in $Catalog['products']) {
            foreach ($key in 'license', 'rights', 'dataLocation') { if ($product[$key]) { $product[$key] } }
            foreach ($limit in @($product['limits'])) { if ($limit) { $limit } }
        }
        foreach ($need in $Catalog['copyMatrix']) { foreach ($cell in $need['cells'].Values) { if ($cell['state'] -ne 'check') { $cell } } }
        foreach ($key in 'milestones', 'dependencies') { foreach ($item in $Catalog['ews'][$key]) { $item } }
    }

    function Get-Text {
        <# Every string of a value, walked in full. #>
        param($Value)
        if ($Value -is [string]) { $Value }
        elseif ($Value -is [System.Collections.IDictionary]) { foreach ($item in $Value.Values) { Get-Text $item } }
        elseif ($Value -is [System.Collections.IEnumerable]) { foreach ($item in $Value) { Get-Text $item } }
    }

    $script:Catalog = Get-Catalog
}

Describe 'The product catalog' {
    It 'keeps the 25 products' {
        @($script:Catalog['products']).Count | Should -Be 25
    }

    It 'gives each product a unique identifier' {
        $ids = @($script:Catalog['products'] | ForEach-Object { $_['id'] })
        @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
    }

    It 'dates every product and every fact' {
        foreach ($item in @($script:Catalog['products']) + @(Get-Fact $script:Catalog)) {
            $item['verifiedOn'] | Should -Match '^\d{4}-\d{2}-\d{2}$' -Because ($item['id'] ?? $item['text'])
        }
    }

    It 'gives every fact a source' {
        foreach ($fact in Get-Fact $script:Catalog) { $fact['source'] | Should -Not -BeNullOrEmpty -Because $fact['text'] }
    }

    It 'flags as unconfirmed what the last check could not read' {
        $confirmed = $script:Catalog['checkedOn']
        foreach ($item in @($script:Catalog['products']) + @(Get-Fact $script:Catalog)) {
            if ($item['verifiedOn'] -ne $confirmed) { $item['recheck'] | Should -BeTrue -Because ($item['id'] ?? $item['text']) }
        }
    }

    It 'holds no price' {
        $text = @(Get-Text $script:Catalog) -join "`n"
        $text | Should -Not -Match '[$€£]\s?\d|\d\s?[$€£]|(?i)\b(USD|CAD|EUR)\b|(?i)\bper (month|year)\b|(?i)/\s?(month|mo|year|yr)\b'
    }

    It 'links only to https addresses' {
        $urls = @($script:Catalog['sources'].Values | ForEach-Object { $_['url'] }) + @($script:Catalog['products'] | ForEach-Object { $_['link'] } | Where-Object { $_ })
        $urls | Should -Not -BeNullOrEmpty
        foreach ($url in $urls) { $url | Should -Match '^https://[^\s<>"]+$' }
    }

    It 'has no source that is only a project document' {
        foreach ($source in $script:Catalog['sources'].Values) { $source['url'] | Should -Not -BeNullOrEmpty -Because $source['title'] }
    }

    It 'searches with patterns that compile and do not match everything' {
        foreach ($product in $script:Catalog['products']) {
            $pattern = $product['detection']
            if (-not $pattern) { continue }
            $regex = [regex]::new($pattern, 'IgnoreCase')
            $regex.IsMatch('') | Should -BeFalse -Because $product['id']
            $regex.IsMatch('Contoso Payroll Portal') | Should -BeFalse -Because $product['id']
        }
    }
}

Describe 'A fact says no more than the page it cites' {
    # These sentences were read on the cited pages. The catalog is public, so a stricter wording is not polish.
    BeforeAll {
        $script:Facts = @(Get-Fact $script:Catalog)
        $script:CrossTenant = @($script:Catalog['products'] | Where-Object { $_['id'] -eq 'microsoft-xt' })[0]
    }

    It 'keeps conversations and messages apart, as the ShareGate page does' {
        $fact = @($script:Facts | Where-Object { $_['source'] -eq 'sg-teams' -and $_['text'] -match 'Posts' })[0]
        $fact['text'] | Should -Match '50 most recent conversations'
        $fact['text'] | Should -Match 'up to 500 messages'
        $fact['text'] | Should -Not -Match '500 by PowerShell'
    }

    It 'cites the page that names the per-user license' {
        $license = $script:CrossTenant['license']
        $license['text'] | Should -Match 'Cross Tenant User Data Migration'
        $license['text'] | Should -Match 'one-time'
        $license['source'] | Should -Be 'ms-mailboxes'
    }

    It 'gives the SharePoint license its own fact, on the SharePoint page' {
        $fact = @($script:Facts | Where-Object { $_['text'] -match 'Cross-Tenant Shared Data Migration' })
        $fact.Count | Should -Be 1
        $fact[0]['source'] | Should -Be 'ms-sharepoint'
        $fact[0]['text'] | Should -Match 'per 100 GB'
        $fact[0]['text'] | Should -Match 'Enterprise Agreement'
    }

    It 'puts nothing on the SharePoint page that it does not say' {
        foreach ($fact in @($script:Facts | Where-Object { $_['source'] -eq 'ms-sharepoint' })) {
            $fact['text'] | Should -Not -Match 'Cross Tenant User Data Migration|one-time'
        }
    }
}

Describe 'The reference check' {
    It 'finds nothing wrong in the catalog' {
        Get-Fault (Get-Catalog) | Should -BeNullOrEmpty
    }

    It 'catches <Name>' -ForEach @(
        @{ Name = 'a task that does not exist'; Plant = { param($c) $c['products'][0]['tasks'] += 'NOPE-01' }; Expected = 'NOPE-01' }
        @{ Name = 'a decision that does not exist'; Plant = { param($c) $c['products'][0]['decisions'] += 'NOPE-02' }; Expected = 'NOPE-02' }
        @{ Name = 'a task used as a decision that has none'; Plant = { param($c) $c['products'][0]['decisions'] += 'ASSESS-01' }; Expected = 'ASSESS-01' }
        @{ Name = 'a source that does not exist on a limit'; Plant = { param($c) $c['products'][0]['limits'][0]['source'] = 'nope-3' }; Expected = 'nope-3' }
        @{ Name = 'a source that does not exist on a license'; Plant = { param($c) $c['products'][0]['license']['source'] = 'nope-4' }; Expected = 'nope-4' }
        @{ Name = 'a family that does not exist'; Plant = { param($c) $c['products'][0]['family'] = 'nope-5' }; Expected = 'nope-5' }
        @{ Name = 'a matrix tool with no product'; Plant = { param($c) $c['copyTools'][0]['id'] = 'nope-6' }; Expected = 'nope-6' }
        @{ Name = 'a matrix row that misses a tool'; Plant = { param($c) $c['copyMatrix'][0]['cells'].Remove('sharegate') }; Expected = 'sharegate' }
        @{ Name = 'a matrix state that does not exist'; Plant = { param($c) $c['copyMatrix'][0]['cells']['sharegate']['state'] = 'nope-7' }; Expected = 'nope-7' }
        @{ Name = 'a source that does not exist in the matrix'; Plant = { param($c) $c['copyMatrix'][0]['cells']['sharegate']['source'] = 'nope-8' }; Expected = 'nope-8' }
        @{ Name = 'an exposure that does not exist in the matrix'; Plant = { param($c) $c['copyMatrix'][0]['exposure'] = 'nope-9' }; Expected = 'nope-9' }
        @{ Name = 'a source that does not exist in the EWS part'; Plant = { param($c) $c['ews']['milestones'][0]['source'] = 'nope-10' }; Expected = 'nope-10' }
        @{ Name = 'a source that does not exist on an exposure'; Plant = { param($c) $c['exposure'][0]['source'] = 'nope-11' }; Expected = 'nope-11' }
    ) {
        $catalog = Get-Catalog
        & $Plant $catalog
        (Get-Fault $catalog) -join "`n" | Should -Match ([regex]::Escape($Expected))
    }
}

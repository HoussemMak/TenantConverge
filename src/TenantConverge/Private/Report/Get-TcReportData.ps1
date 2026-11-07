function Get-TcReportData {
    <#
    .SYNOPSIS
    Gathers what the report shows, from the project, the snapshot, the rules and the plan.

    .DESCRIPTION
    Returns Data, read when the page opens, and Tables, the rows of the snapshot, read at the first need.
    Everything is computed here and only shown in the page, so the numbers have one source. A role that the
    project does not have never appears. What was not read stays empty, with its state beside it.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'The data of the report is one thing.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Project,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RuleSet,
        [AllowEmptyCollection()][object[]]$Readiness = @(),
        [AllowEmptyCollection()][string[]]$Log = @(),
        [AllowEmptyString()][string]$TrackingText = '',
        [string]$TrackingName = 'team-tracking.csv',
        [AllowEmptyCollection()][string[]]$IgnoreNameSuffix = @()
    )

    $target = Get-TcProperty $Project 'target'
    $sources = @(@(Get-TcProperty $Project 'sources' @()) | Sort-Object { Get-TcProperty $_ 'role' })
    $sourceRoles = @($sources | ForEach-Object { [string](Get-TcProperty $_ 'role') })
    $roles = @('Target') + $sourceRoles
    $tenantData = Get-TcProperty $Snapshot 'tenants'
    $coverage = @(Get-TcProperty $Snapshot 'coverage' @())
    $meta = Get-TcProperty $Snapshot 'meta'
    $dictionary = Get-TcTableDictionary
    $catalog = Get-TcProductCatalog

    $names = @{ Target = [string](Get-TcProperty $target 'displayName') }
    foreach ($source in $sources) { $names[[string](Get-TcProperty $source 'role')] = [string](Get-TcProperty $source 'displayName') }

    $date = {
        param($Value)
        if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture) }
        $parsed = [datetime]::MinValue
        if ($Value -and [datetime]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsed)) { return $parsed.ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture) }
        [string]$Value
    }

    # Get-TcTableState walks the coverage: give it only the lines of the tenant, as the tables number in the hundreds.
    $tableStates = [ordered]@{}
    foreach ($role in $roles) {
        $scoped = @{ tenants = $tenantData; coverage = @($coverage | Where-Object { (Get-TcProperty $_ 'role') -eq $role }) }
        $states = [ordered]@{}
        foreach ($table in $dictionary.Keys) {
            $state = Get-TcTableState -Snapshot $scoped -Role $role -Table $table
            $states[$table] = [ordered]@{ state = $state.State; status = $state.Status; rows = $state.Rows; message = $state.Message; remedy = $state.Remedy }
        }
        $tableStates[$role] = $states
    }

    $tenants = foreach ($role in $roles) {
        $definition = if ($role -eq 'Target') { $target } else { @($sources | Where-Object { (Get-TcProperty $_ 'role') -eq $role })[0] }
        $present = $null -ne $tenantData -and $tenantData.Contains($role)
        $lines = @($coverage | Where-Object { (Get-TcProperty $_ 'role') -eq $role })
        $worked = @($lines | Where-Object { (Get-TcProperty $_ 'status') -in 'OK', 'Partial' })
        $clean = @($lines | Where-Object { (Get-TcProperty $_ 'status') -eq 'OK' })
        $tables = Get-TcProperty (Get-TcProperty $tenantData $role) 'tables'
        $rows = 0
        if ($tables) { foreach ($table in $tables.Keys) { $rows += @($tables[$table]).Count } }

        $domains = @(@(Get-TcProperty $tables 'domains' @()) | Where-Object { -not ([string](Get-TcProperty $_ 'Domain')).EndsWith('.onmicrosoft.com') } | ForEach-Object { [string](Get-TcProperty $_ 'Domain') })
        $initial = @(@(Get-TcProperty $tables 'domains' @()) | Where-Object { Get-TcProperty $_ 'Initial' $false } | ForEach-Object { [string](Get-TcProperty $_ 'Domain') }) | Select-Object -First 1
        $primary = [string](Get-TcProperty $definition 'primaryDomain')

        [ordered]@{
            role = $role; kind = $(if ($role -eq 'Target') { 'Target' } else { 'Source' }); name = $names[$role]; primaryDomain = $primary
            wave = Get-TcProperty $definition 'wave'; domains = @(if ($domains.Count) { $domains } else { $primary }); initialDomain = [string]$initial
            collection = $(if (-not $present) { 'Absent' } elseif (-not $worked.Count -and -not $rows) { 'Nothing' } elseif ($clean.Count -lt $lines.Count) { 'Partial' } else { 'Full' })
            collectors = $lines.Count; collected = $clean.Count; rows = $rows
        }
    }

    $actions = @(Get-TcProperty $Plan 'actions' @())

    $identity = [ordered]@{}
    foreach ($role in $sourceRoles) {
        $action = @($actions | Where-Object { $_['id'] -eq "$role-IDENTITY-MATRIX" }) | Select-Object -First 1
        $state = $tableStates[$role]['users']
        $sourceRead = $state['state'] -notin 'NotCollected', 'NotFullyRead'
        $targetThere = $null -ne $tenantData -and $tenantData.Contains('Target')
        if (-not $sourceRead -or -not $targetThere -or -not (Get-TcProperty $action 'drafted' $true)) {
            $identity[$role] = [ordered]@{
                drafted = $false; rows = @(); counts = [ordered]@{}
                reason = $(if ($action) { [string]$action['finding'] } else { "The accounts could not be read ($($state['status']))." })
                remedy = $(if ($action) { [string]$action['action'] } else { [string]$state['remedy'] })
            }
            continue
        }
        $rows = @(ConvertTo-TcIdentityMatrix -Snapshot $Snapshot -SourceRole $role -IgnoreNameSuffix $IgnoreNameSuffix)
        $counts = [ordered]@{}
        foreach ($decision in 'Create', 'Duplicate', 'To review') { $counts[$decision] = @($rows | Where-Object { $_['Decision'] -eq $decision }).Count }
        $counts['Bookings'] = @($rows | Where-Object { $_['Notes'] -match 'Bookings' }).Count
        $identity[$role] = [ordered]@{ drafted = $true; rows = $rows; counts = $counts; reason = ''; remedy = '' }
    }

    $dns = [ordered]@{}
    foreach ($role in $sourceRoles) {
        $tables = Get-TcProperty (Get-TcProperty $tenantData $role) 'tables'
        $dns[$role] = [ordered]@{
            summaryState = $tableStates[$role]['dnsSummary']; recordState = $tableStates[$role]['publicDns']
            summary = @(Get-TcProperty $tables 'dnsSummary' @()); records = @(Get-TcProperty $tables 'publicDns' @())
        }
    }

    $measures = @(Get-TcProperty $RuleSet 'measures' @())
    $exposure = Get-TcReportExposure -Snapshot $Snapshot -Catalog $catalog -Source $sourceRoles -TableState $tableStates -Measure $measures -Identity $identity -Name $names
    $found = Get-TcProductTrace -Snapshot $Snapshot -Catalog $catalog -Role $roles -TableState $tableStates

    $products = foreach ($product in $catalog['products']) {
        $copy = [ordered]@{}
        foreach ($key in $product.Keys) { if ($key -ne 'detection') { $copy[$key] = $product[$key] } }
        $copy['searched'] = [bool]$product['detection']
        $copy['traces'] = if ($product['detection']) { $found['Traces'][$product['id']] } else { [ordered]@{} }
        $copy
    }

    $ewsState = [ordered]@{}
    foreach ($role in $roles) {
        $tables = Get-TcProperty (Get-TcProperty $tenantData $role) 'tables'
        $settingsRead = $tableStates[$role]['exchangeSettings']['state'] -notin 'NotCollected', 'NotFullyRead'
        $protocolsRead = $tableStates[$role]['mailboxProtocols']['state'] -notin 'NotCollected', 'NotFullyRead'
        $line = @(Get-TcProperty $tables 'exchangeSettings' @()) | Where-Object { (Get-TcProperty $_ 'Setting') -eq 'Organization.EwsEnabled' } | Select-Object -First 1
        $protocols = @(Get-TcProperty $tables 'mailboxProtocols' @())
        $ewsState[$role] = [ordered]@{
            read = $settingsRead; found = [bool]$line; enabled = $(if ($line) { [string](Get-TcProperty $line 'Value') } else { $null })
            mailboxes = $(if ($protocolsRead) { $protocols.Count } else { $null })
            usingEws = $(if ($protocolsRead) { @($protocols | Where-Object { Test-TcRowTrue $_ 'EWS' }).Count } else { $null })
            status = $tableStates[$role]['exchangeSettings']['status']
        }
    }

    $tableLabels = [ordered]@{}
    foreach ($table in $dictionary.Keys) { $tableLabels[$table] = [ordered]@{ label = $dictionary[$table]['label']; workload = $dictionary[$table]['workload'] } }

    $findings = @(Get-TcProperty $RuleSet 'findings' @())
    $settingGaps = @(Get-TcProperty $RuleSet 'settingGaps' @())
    $rowCount = 0
    $tableCount = 0
    $tables = [ordered]@{}
    foreach ($role in $roles) {
        $mine = Get-TcProperty (Get-TcProperty $tenantData $role) 'tables'
        $tables[$role] = if ($mine) { $mine } else { [ordered]@{} }
        if ($mine) { foreach ($table in $mine.Keys) { $tableCount++; $rowCount += @($mine[$table]).Count } }
    }

    $now = [datetime]::UtcNow
    $data = [ordered]@{
        report         = [ordered]@{
            generated = $now.ToLocalTime().ToString('yyyy-MM-dd HH:mm', [cultureinfo]::InvariantCulture); generatedIso = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffZ', [cultureinfo]::InvariantCulture)
            moduleVersion = [string](Get-TcProperty $meta 'moduleVersion'); depth = [string](Get-TcProperty $meta 'depth')
            snapshotStarted = & $date (Get-TcProperty $meta 'started'); snapshotFinished = & $date (Get-TcProperty $meta 'finished')
        }
        project        = [ordered]@{
            name = [string](Get-TcProperty $Project 'name'); key = '{0}|{1}' -f (Get-TcProperty $Project 'name'), (Get-TcProperty $target 'primaryDomain')
            targetState = [string](Get-TcProperty $target 'state'); team = @(@(Get-TcProperty $Project 'team' @()) | Where-Object { $_ })
        }
        tenants        = @($tenants)
        waves          = @(Get-TcProperty $Plan 'waves' @())
        moments        = @(Get-TcProperty (Get-TcProperty $Plan 'meta') 'moments' @('Now', 'Preparation', 'Before cutover', 'Cutover', 'After cutover', 'Closure'))
        actions        = $actions
        tasks          = @(Get-TcProperty $Plan 'tasks' @())
        decisions      = @(Get-TcProperty $Plan 'decisions' @())
        configurations = @(Get-TcProperty $Plan 'targetConfigurations' @())
        procedures     = Get-TcProperty $Plan 'procedures' ([ordered]@{})
        remediations   = @(Get-TcProperty $Plan 'remediations' @())
        findings       = $findings
        measures       = $measures
        settingGaps    = $settingGaps
        unread         = @(Get-TcProperty $RuleSet 'unread' @())
        errors         = @(Get-TcProperty $RuleSet 'errors' @())
        coverage       = $coverage
        readiness      = @($Readiness)
        identity       = $identity
        dns            = $dns
        tableLabels    = $tableLabels
        tableStates    = $tableStates
        manualProducts = @(Get-TcProperty (Get-TcProperty (Get-TcProperty $tenantData 'Target') 'tables') 'manualProducts' @())
        summary        = [ordered]@{
            collectors = $coverage.Count; collected = @($coverage | Where-Object { (Get-TcProperty $_ 'status') -eq 'OK' }).Count
            partial = @($coverage | Where-Object { (Get-TcProperty $_ 'status') -eq 'Partial' }).Count
            missing = @($coverage | Where-Object { (Get-TcProperty $_ 'status') -notin 'OK', 'Partial' }).Count
            tables = $tableCount; rows = $rowCount; findings = $findings.Count; gaps = $settingGaps.Count
        }
        solutions      = [ordered]@{
            checkedOn = $catalog['checkedOn']; sources = $catalog['sources']; families = $catalog['families']; products = @($products)
            matrixStates = $catalog['matrixStates']; copyTools = $catalog['copyTools']; copyMatrix = $catalog['copyMatrix']; ews = $catalog['ews']
            ewsState = $ewsState; exposure = $exposure['Values']; exposureFacts = $exposure['Facts']; traceCoverage = $found['Coverage']
        }
        tracking       = [ordered]@{ fileName = $TrackingName; text = $TrackingText }
        log            = @($Log)
    }

    @{ Data = $data; Tables = $tables }
}

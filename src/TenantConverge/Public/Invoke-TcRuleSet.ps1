function Invoke-TcRuleSet {
    <#
    .SYNOPSIS
    Runs the rules on a snapshot and returns findings, measures and setting gaps.

    .DESCRIPTION
    Works from the snapshot alone, with no connection. Rules run on each tenant, then each source is
    compared with the target, then all the tenants are read together, for 1, 2 or 3 sources.

    The result has five keys. findings holds what the rules found, most severe first. measures holds one
    line per indicator. settingGaps holds the settings that differ between a source and the target.
    unread lists, by tenant and workload, the tables the rules needed and could not read. errors lists
    the rules, measures and setting comparisons that stopped, and it is empty in a normal run. One bad
    value stops only its own block, and a workload with an error counts as not fully read.

    .PARAMETER Snapshot
    The snapshot, as read from snapshot.json.

    .PARAMETER Threshold
    Replaces thresholds: inactiveDays, secretExpiryDays, mailboxThresholdGb, siteThresholdGb,
    oneDriveThresholdGb, maxTtlSeconds, storageMarginPercent.

    .PARAMETER LicenseSku
    The SKU migrated accounts are expected to get. The default is the most used SKU of the target.

    .PARAMETER SourcePrefix
    The prefix planned for each source, by role, to look for names already taken once prefixed.

    .PARAMETER HomeCountry
    The countries sign-ins are expected from. The default is the country of each tenant.

    .EXAMPLE
    $ruleSet = Invoke-TcRuleSet -Snapshot (Get-Content ./snapshot.json -Raw | ConvertFrom-Json -AsHashtable)

    Runs the rules on a saved snapshot.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [hashtable]$Threshold = @{},
        [string]$LicenseSku,
        [hashtable]$SourcePrefix = @{},
        [string[]]$HomeCountry = @()
    )

    $tenants = Get-TcProperty $Snapshot 'tenants'
    if ($null -eq $tenants) { throw 'This snapshot has no tenants.' }

    $thresholds = @{ inactiveDays = 90; secretExpiryDays = 60; mailboxThresholdGb = 45; siteThresholdGb = 100; oneDriveThresholdGb = 100; maxTtlSeconds = 300; storageMarginPercent = 15 }
    foreach ($key in $Threshold.Keys) {
        if (-not $thresholds.ContainsKey($key)) { throw "'$key' is not a rule threshold. Use one of: $(@($thresholds.Keys | Sort-Object) -join ', ')." }
        $thresholds[$key] = $Threshold[$key]
    }

    $roles = @('Target', 'S1', 'S2', 'S3' | Where-Object { $tenants.Contains($_) })
    $sources = @($roles | Where-Object { $_ -ne 'Target' })

    $script:TcRuleRun = @{
        Snapshot = $Snapshot; Tenants = $tenants; Roles = $roles; Sources = $sources; Thresholds = $thresholds
        LicenseSku = $LicenseSku; SourcePrefix = $SourcePrefix; HomeCountry = @($HomeCountry)
        Role = $null; Workload = $null; Source = $null
        Findings = [System.Collections.Generic.List[object]]::new()
        Unread = [System.Collections.Generic.List[object]]::new()
        UnreadKeys = [System.Collections.Generic.HashSet[string]]::new()
        Errors = [System.Collections.Generic.List[object]]::new()
    }
    $run = $script:TcRuleRun

    $invoke = {
        param([scriptblock]$Rule, [string]$Role, [object[]]$Arguments)
        try { & $Rule @Arguments }
        catch { Add-TcRuleError -Role $Role -Workload $run['Workload'] -ErrorRecord $_ }
    }

    try {
        $workloads = [ordered]@{
            'Entra ID' = 'Get-TcEntraIdRule'; 'Exchange Online' = 'Get-TcExchangeRule'; 'SharePoint and OneDrive' = 'Get-TcSharePointRule'; 'Teams' = 'Get-TcTeamsRule'
            'Teams Phone' = 'Get-TcTeamsPhoneRule'; 'Intune' = 'Get-TcIntuneRule'; 'Purview' = 'Get-TcPurviewRule'; 'Power Platform' = 'Get-TcPowerPlatformRule'
            'Azure' = 'Get-TcAzureRule'; 'Domains and DNS' = 'Get-TcDnsRule'; 'Other services' = 'Get-TcOtherServiceRule'; 'Coverage' = 'Get-TcCoverageRule'
        }
        foreach ($role in $roles) {
            $run['Role'] = $role
            foreach ($workload in $workloads.Keys) {
                $run['Workload'] = $workload
                foreach ($rule in & $workloads[$workload]) { & $invoke $rule $role @($role) }
            }
        }

        if ($tenants.Contains('Target')) {
            foreach ($source in $sources) {
                $run['Role'] = $source
                $run['Source'] = $source
                foreach ($rule in Get-TcComparisonRule) { & $invoke $rule $source @($source) }
            }
        }

        if ($roles.Count -ge 2) {
            $run['Role'] = 'All'
            $run['Workload'] = 'Consolidation'
            foreach ($rule in Get-TcConsolidationRule) { & $invoke $rule 'All' @() }
        }

        $run['Role'] = $null
        $run['Workload'] = $null
        $gaps = @(Get-TcSettingGap)

        foreach ($source in $sources) {
            $run['Source'] = $source
            $important = @($gaps | Where-Object { $_['important'] -and $_['different'] -contains $source })
            if ($important.Count) {
                Add-TcFinding 'CMP-SETTINGS' 'Both' -Values @{ count = $important.Count } -Items ($important | ForEach-Object { '{0} - {1}: {2} to {3}' -f $_['workload'], $_['setting'], $_['values'][$source], $_['values']['Target'] })
            }
        }

        if ($sources.Count -ge 2) {
            $between = @($gaps | Where-Object { $gap = $_; $gap['important'] -and @($sources | Where-Object { $gap['values'].Contains($_) } | ForEach-Object { $gap['values'][$_] } | Sort-Object -Unique).Count -ge 2 })
            if ($between.Count) {
                Add-TcFinding 'CON-SETTINGS' 'All' -Values @{ count = $between.Count } -Items ($between | ForEach-Object {
                        $gap = $_
                        '{0} - {1}: {2}' -f $gap['workload'], $gap['setting'], (@($gap['values'].Keys | ForEach-Object { '{0} {1}' -f (Get-TcRuleTenantName $_), $gap['values'][$_] }) -join ' - ')
                    })
            }
        }

        [ordered]@{
            findings    = @($run['Findings'] | Sort-Object -Stable { $_['order'] }, { $_['workload'] }, { $_['title'] })
            measures    = @(Get-TcMeasure)
            settingGaps = $gaps
            unread      = @($run['Unread'])
            errors      = @($run['Errors'])
        }
    }
    finally {
        $script:TcRuleRun = $null
    }
}

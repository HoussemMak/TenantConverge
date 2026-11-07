function Get-TcComparisonRule {
    <#
    .SYNOPSIS
    Returns the rules that compare one source with the target, as script blocks that take the source role.

    .DESCRIPTION
    A finding here belongs to the source: it is what stands between that source and the target. Each block
    names its workload first, so a table it misses counts against that workload of that source.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Cross-tenant access and guests that collide with migrated accounts
        param($Source)
        $script:TcRuleRun['Workload'] = 'Entra ID'
        $sourceId = [string](Get-TcProperty $script:TcRuleRun['Tenants'][$Source] 'tenantId')
        if (-not $sourceId) { $sourceId = Get-TcRuleSetting $Source 'organizationSettings' 'Tenant ID' }
        if ((Test-TcRuleTable 'Target' 'crossTenantPartners') -and $sourceId -and -not @(Get-TcRuleRow 'Target' 'crossTenantPartners' | Where-Object { (Get-TcProperty $_ 'Tenant') -eq $sourceId }).Count) {
            Add-TcFinding 'CMP-CROSS-TENANT' 'Both'
        }

        $domains = @(Get-TcSourceDomain $Source)
        if ($domains.Count) {
            $pattern = '(' + (@($domains | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')'
            $guests = @(Get-TcRuleRow 'Target' 'users' | Where-Object { (Get-TcProperty $_ 'Type') -eq 'Guest' -and ("$(Get-TcProperty $_ 'UPN') $(Get-TcProperty $_ 'Email')").ToLowerInvariant() -match $pattern })
            if ($guests.Count) { Add-TcFinding 'CMP-CROSS-GUESTS' 'Both' -Values @{ count = $guests.Count } -Items ($guests | ForEach-Object { '{0} - {1}' -f (Get-TcProperty $_ 'UPN'), (Get-TcProperty $_ 'Name') }) }
        }
    }

    { # Licenses for the accounts of this source
        param($Source)
        $script:TcRuleRun['Workload'] = 'Entra ID'
        $needed = @(Get-TcRuleRow $Source 'users' | Where-Object { (Get-TcProperty $_ 'Type') -eq 'Member' -and (Test-TcRowTrue $_ 'Enabled') -and (Get-TcRowInteger $_ 'License count') -gt 0 }).Count
        $sku = Get-TcRuleLicenseSku
        $license = Get-TcRuleRow 'Target' 'licenses' | Where-Object { (Get-TcProperty $_ 'SKU') -eq $sku } | Select-Object -First 1
        if ($needed -and (Test-TcRuleTable 'Target' 'licenses')) {
            $available = if ($license) { [int](Get-TcProperty $license 'Available') } else { 0 }
            if ($available -lt $needed) {
                Add-TcFinding 'CMP-LICENSES' 'Both' -Values @{ sku = $sku; available = $available; needed = $needed; missing = $needed - $available }
            }
        }
    }

    { # Teams Phone licenses for the voice users of this source
        param($Source)
        $script:TcRuleRun['Workload'] = 'Teams Phone'
        $voice = @(Get-TcRuleRow $Source 'teamsUsers' | Where-Object { Test-TcRowTrue $_ 'Enterprise Voice' }).Count
        if ($voice -and (Test-TcRuleTable 'Target' 'licenses')) {
            $available = (@(Get-TcRuleRow 'Target' 'licenses' | Where-Object { (Get-TcProperty $_ 'Plans') -match 'MCOEV' -and (Get-TcProperty $_ 'SKU') -notmatch 'VIRTUALUSER' } | ForEach-Object { [int](Get-TcProperty $_ 'Available') }) | Measure-Object -Sum).Sum
            if ($available -lt $voice) { Add-TcFinding 'CMP-VOICE-LICENSES' 'Both' -Values @{ available = [int]$available; needed = $voice } }
        }
    }

    { # Site addresses and storage
        param($Source)
        $script:TcRuleRun['Workload'] = 'SharePoint and OneDrive'
        $sourceSites = @(Get-TcRuleRow $Source 'sites')
        $targetSites = @(Get-TcRuleRow 'Target' 'sites')
        if (-not $sourceSites.Count -or -not $targetSites.Count) { return }

        $paths = @{}
        foreach ($site in $targetSites) { $paths[[string](Get-TcProperty $site 'Path')] = Get-TcProperty $site 'Url' }
        $prefix = [string]$script:TcRuleRun['SourcePrefix'][$Source]
        $taken = @($sourceSites | Where-Object { (Get-TcProperty $_ 'Path') -match '^/(sites|teams)/' -and $paths.ContainsKey([string](Get-TcProperty $_ 'Path')) })
        $takenPrefixed = @($sourceSites | Where-Object { (Get-TcProperty $_ 'Path') -match '^/(sites|teams)/([^/]+)$' -and $prefix -and $paths.ContainsKey(('/{0}/{1}-{2}' -f $Matches[1], $prefix.ToLowerInvariant(), $Matches[2])) })
        if ($taken.Count -or $takenPrefixed.Count) {
            $items = @($taken | ForEach-Object { '{0} - already exists: {1}' -f (Get-TcProperty $_ 'Url'), $paths[[string](Get-TcProperty $_ 'Path')] }) + @($takenPrefixed | ForEach-Object { '{0} - the prefixed form already exists' -f (Get-TcProperty $_ 'Url') })
            Add-TcFinding 'CMP-SITE-URLS' 'Both' -Values @{ count = $taken.Count + $takenPrefixed.Count } -Items $items
        }

        $quota = Get-TcRowNumber @{ q = Get-TcRuleSetting 'Target' 'sharePointSettings' 'StorageQuota' } 'q'
        $usedTarget = (@($targetSites | ForEach-Object { [double](Get-TcProperty $_ 'Storage MB') }) | Measure-Object -Sum).Sum
        $usedSource = (@($sourceSites | ForEach-Object { [double](Get-TcProperty $_ 'Storage MB') }) | Measure-Object -Sum).Sum
        $estimated = $false
        if (-not $quota) {
            $licensed = @(Get-TcRuleRow 'Target' 'users' | Where-Object { (Get-TcRowInteger $_ 'License count') -gt 0 }).Count
            if ($licensed) { $quota = (1024 * 1024) + (10 * 1024 * $licensed); $estimated = $true }
        }
        if ($quota) {
            $margin = [double](Get-TcRuleThreshold 'storageMarginPercent')
            $total = $usedTarget + $usedSource
            $severity = if ($total -gt $quota) { 'Critical' } elseif ($total -gt $quota * (1 - $margin / 100)) { 'High' } else { 'Info' }
            $values = @{
                total = Format-TcNumber ($total / 1024); quota = Format-TcNumber ($quota / 1024); used = Format-TcNumber ($usedTarget / 1024)
                source = Format-TcNumber ($usedSource / 1024); margin = $margin; estimated = $(if ($estimated) { Get-TcRulePart 'CMP-CAPACITY' 'estimated' } else { '' })
            }
            $variant = if ($severity -eq 'Info') { '' } else { 'short' }
            Add-TcFinding 'CMP-CAPACITY' 'Both' -Severity $severity -Variant $variant -Values $values
        }
    }

    { # Team names
        param($Source)
        $script:TcRuleRun['Workload'] = 'Teams'
        $sourceTeams = @(Get-TcRuleRow $Source 'teams')
        $targetTeams = @(Get-TcRuleRow 'Target' 'teams')
        if (-not $sourceTeams.Count -or -not $targetTeams.Count) { return }
        $prefix = ([string]$script:TcRuleRun['SourcePrefix'][$Source]).ToLowerInvariant()
        $names = @{}
        foreach ($team in $targetTeams) { $names[([string](Get-TcProperty $team 'Name')).ToLowerInvariant()] = 1 }
        $clashes = @($sourceTeams | Where-Object {
                $key = ([string](Get-TcProperty $_ 'Name')).ToLowerInvariant()
                $names.ContainsKey($key) -or ($prefix -and ($names.ContainsKey("$prefix-$key") -or $names.ContainsKey("$prefix - $key")))
            })
        if ($clashes.Count) { Add-TcFinding 'CMP-TEAM-NAMES' 'Both' -Values @{ count = $clashes.Count } -Items ($clashes | ForEach-Object { Get-TcProperty $_ 'Name' }) }
    }

    { # Teams federation during coexistence
        param($Source)
        $script:TcRuleRun['Workload'] = 'Teams'
        if (-not (Test-TcRuleTable 'Target' 'teamsSettings')) { return }
        $federation = Get-TcRuleSetting 'Target' 'teamsSettings' 'External access.AllowFederatedUsers'
        $allowed = [string](Get-TcRuleSetting 'Target' 'teamsSettings' 'External access.AllowedDomains')
        $domains = @(Get-TcSourceDomain $Source)
        $closed = ($null -ne $federation -and -not (Test-TcTrue $federation)) -or ($allowed -and $allowed -notmatch '(?i)AllowAllKnownDomains' -and @($domains | Where-Object { $allowed.ToLowerInvariant().Contains($_) }).Count -lt $domains.Count)
        if ($closed) {
            Add-TcFinding 'CMP-TEAMS-FEDERATION' 'Both' -Values @{ federation = $federation; domains = $(if ($allowed) { $allowed } else { Get-TcRulePart 'CMP-TEAMS-FEDERATION' 'allDomains' }) }
        }
    }

    { # Free/busy during coexistence
        param($Source)
        $script:TcRuleRun['Workload'] = 'Exchange Online'
        if (-not (Test-TcRuleTable 'Target' 'organizationRelationships')) { return }
        $domains = @(Get-TcSourceDomain $Source)
        $sharing = @(Get-TcRuleRow 'Target' 'organizationRelationships' | Where-Object {
                $names = ([string](Get-TcProperty $_ 'Domains')).ToLowerInvariant()
                (Test-TcRowTrue $_ 'Enabled') -and @($domains | Where-Object { $names.Contains($_) }).Count
            })
        if (-not $sharing.Count) { Add-TcFinding 'CMP-FREE-BUSY' 'Both' }
    }

    { # Shared mailboxes with a counterpart in the target
        param($Source)
        $script:TcRuleRun['Workload'] = 'Exchange Online'
        $sourceBoxes = @(Get-TcRuleRow $Source 'mailboxes' | Where-Object { (Get-TcProperty $_ 'Type') -in 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox' })
        $targetBoxes = @(Get-TcRuleRow 'Target' 'mailboxes')
        if (-not $sourceBoxes.Count -or -not $targetBoxes.Count) { return }
        $locals = @{}
        foreach ($box in $targetBoxes) {
            $part = Get-TcAddressPrefix ([string](Get-TcProperty $box 'Primary address'))
            if ($part) { $locals[$part.ToLowerInvariant()] = Get-TcProperty $box 'Primary address' }
        }
        $pairs = @($sourceBoxes | Where-Object { $locals.ContainsKey((Get-TcAddressPrefix ([string](Get-TcProperty $_ 'Primary address'))).ToLowerInvariant()) })
        if ($pairs.Count) {
            Add-TcFinding 'CMP-SHARED-MAILBOXES' 'Both' -Values @{ count = $pairs.Count } -Items ($pairs | ForEach-Object { '{0} and {1}' -f (Get-TcProperty $_ 'Primary address'), $locals[(Get-TcAddressPrefix ([string](Get-TcProperty $_ 'Primary address'))).ToLowerInvariant()] })
        }
    }

    { # Autopilot in the target
        param($Source)
        $script:TcRuleRun['Workload'] = 'Intune'
        if ((Test-TcRuleTable $Source 'autopilotDevices') -and @(Get-TcRuleRow $Source 'autopilotDevices').Count -and (Test-TcRuleTable 'Target' 'autopilotProfiles') -and -not @(Get-TcRuleRow 'Target' 'autopilotProfiles').Count) {
            Add-TcFinding 'CMP-AUTOPILOT-TARGET' 'Both' -Values @{ count = @(Get-TcRuleRow $Source 'autopilotDevices').Count }
        }
    }
}

function Get-TcConsolidationRule {
    <#
    .SYNOPSIS
    Returns the rules that look at every tenant at once, as script blocks.

    .DESCRIPTION
    The blocks work on the roles of the run, whatever their number: nothing here assumes that S2 or S3
    exist. A rule that needs two sources, like a site path shared by two sources, finds nothing with one.

    A total that misses a tenant is a minimum: storage, licenses and voice name what was not read and
    never conclude that there is enough. A shortage that is certain anyway is still reported.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # People with an account in several tenants
        $people = @{}
        foreach ($role in $script:TcRuleRun['Roles']) {
            foreach ($user in Get-TcRuleRow $role 'users' | Where-Object { (Get-TcProperty $_ 'Type') -eq 'Member' -and (Test-TcRowTrue $_ 'Enabled') }) {
                $first = Get-TcProperty $user 'First name'
                $last = Get-TcProperty $user 'Last name'
                $key = if ($first -and $last) { ConvertTo-TcPersonKey "$first $last" } else { ConvertTo-TcPersonKey (Get-TcProperty $user 'Name') }
                if ($key -notmatch '\s' -or $key.Length -lt 5) { continue }
                if (-not $people.ContainsKey($key)) { $people[$key] = [System.Collections.Generic.List[object]]::new() }
                $people[$key].Add(@{ role = $role; upn = Get-TcProperty $user 'UPN'; name = Get-TcProperty $user 'Name' })
            }
        }
        $duplicates = @($people.Keys | Where-Object { @($people[$_] | ForEach-Object { $_['role'] } | Sort-Object -Unique).Count -ge 2 } | Sort-Object)
        if ($duplicates.Count) {
            Add-TcFinding 'CON-IDENTITIES' 'All' -Values @{ count = $duplicates.Count } -Items ($duplicates | ForEach-Object {
                    $accounts = @($people[$_])
                    '{0}: {1}' -f $accounts[0]['name'], (@($accounts | ForEach-Object { '{0} ({1})' -f (Get-TcRuleTenantName $_['role']), $_['upn'] }) -join ', ')
                })
        }
    }

    { # Generic mailboxes and aliases in several tenants
        $boxes = @{}
        $aliases = @{}
        foreach ($role in $script:TcRuleRun['Roles']) {
            foreach ($box in Get-TcRuleRow $role 'mailboxes' | Where-Object { (Get-TcProperty $_ 'Type') -in 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox' }) {
                $key = (Get-TcAddressPrefix ([string](Get-TcProperty $box 'Primary address'))).ToLowerInvariant()
                if (-not $boxes.ContainsKey($key)) { $boxes[$key] = [System.Collections.Generic.List[object]]::new() }
                $boxes[$key].Add(@{ role = $role; address = Get-TcProperty $box 'Primary address' })
            }
            foreach ($table in 'mailboxes', 'groups', 'microsoft365Groups', 'distributionGroups') {
                foreach ($row in Get-TcRuleRow $role $table) {
                    $key = ([string](Get-TcProperty $row 'Alias')).ToLowerInvariant()
                    if (-not $key) { continue }
                    if (-not $aliases.ContainsKey($key)) { $aliases[$key] = @{} }
                    $aliases[$key][$role] = 1
                }
            }
        }

        $sharedBoxes = @($boxes.Keys | Where-Object { @($boxes[$_] | ForEach-Object { $_['role'] } | Sort-Object -Unique).Count -ge 2 } | Sort-Object)
        if ($sharedBoxes.Count) {
            Add-TcFinding 'CON-SHARED-MAILBOXES' 'All' -Values @{ count = $sharedBoxes.Count } -Items ($sharedBoxes | ForEach-Object { '{0}@: {1}' -f $_, (@($boxes[$_] | ForEach-Object { $_['address'] }) -join ', ') })
        }

        $sharedAliases = @($aliases.Keys | Where-Object { $aliases[$_].Count -ge 2 } | Sort-Object)
        if ($sharedAliases.Count) {
            Add-TcFinding 'CON-ALIASES' 'All' -Values @{ count = $sharedAliases.Count } -Items ($sharedAliases | ForEach-Object { '{0}: {1}' -f $_, (@($aliases[$_].Keys | ForEach-Object { Get-TcRuleTenantName $_ }) -join ', ') })
        }
    }

    { # Site paths and team names in several tenants
        $paths = @{}
        $names = @{}
        foreach ($role in $script:TcRuleRun['Sources']) {
            foreach ($site in Get-TcRuleRow $role 'sites' | Where-Object { (Get-TcProperty $_ 'Path') -match '^/(sites|teams)/' }) {
                $key = [string](Get-TcProperty $site 'Path')
                if (-not $paths.ContainsKey($key)) { $paths[$key] = @{} }
                $paths[$key][$role] = Get-TcProperty $site 'Url'
            }
        }
        foreach ($role in $script:TcRuleRun['Roles']) {
            foreach ($team in Get-TcRuleRow $role 'teams') {
                $key = ([string](Get-TcProperty $team 'Name')).ToLowerInvariant()
                if (-not $names.ContainsKey($key)) { $names[$key] = @{} }
                $names[$key][$role] = Get-TcProperty $team 'Name'
            }
        }

        $sharedPaths = @($paths.Keys | Where-Object { $paths[$_].Count -ge 2 } | Sort-Object)
        if ($sharedPaths.Count) {
            Add-TcFinding 'CON-SITES' 'All' -Values @{ count = $sharedPaths.Count } -Items ($sharedPaths | ForEach-Object { '{0}: {1}' -f $_, (@($paths[$_].Keys | ForEach-Object { Get-TcRuleTenantName $_ }) -join ', ') })
        }

        $sharedNames = @($names.Keys | Where-Object { $names[$_].Count -ge 2 } | Sort-Object)
        if ($sharedNames.Count) {
            Add-TcFinding 'CON-TEAMS' 'All' -Values @{ count = $sharedNames.Count } -Items ($sharedNames | ForEach-Object { '{0}: {1}' -f @($names[$_].Values)[0], (@($names[$_].Keys | ForEach-Object { Get-TcRuleTenantName $_ }) -join ', ') })
        }
    }

    { # Storage, licenses and voice across the sources
        $sources = @($script:TcRuleRun['Sources'])
        if (-not $script:TcRuleRun['Tenants'].Contains('Target') -or $sources.Count -lt 2) { return }

        $quota = Get-TcRowNumber @{ q = Get-TcRuleSetting 'Target' 'sharePointSettings' 'StorageQuota' } 'q'
        $estimated = $false
        if (-not $quota) {
            $licensed = @(Get-TcRuleRow 'Target' 'users' | Where-Object { (Get-TcRowInteger $_ 'License count') -gt 0 }).Count
            if ($licensed) { $quota = (1024 * 1024) + (10 * 1024 * $licensed); $estimated = $true }
        }
        $volumes = [ordered]@{ Target = (@(Get-TcRuleRow 'Target' 'sites' | ForEach-Object { [double](Get-TcProperty $_ 'Storage MB') }) | Measure-Object -Sum).Sum }
        foreach ($source in $sources) { $volumes[$source] = (@(Get-TcRuleRow $source 'sites' | ForEach-Object { [double](Get-TcProperty $_ 'Storage MB') }) | Measure-Object -Sum).Sum }
        $total = (@($volumes.Values) | Measure-Object -Sum).Sum
        if ($quota) {
            $unread = @(Get-TcRuleUnreadRole @($volumes.Keys) 'sites')
            $margin = [double](Get-TcRuleThreshold 'storageMarginPercent')
            $severity = if ($total -gt $quota) { 'Critical' } elseif ($total -gt $quota * (1 - $margin / 100)) { 'High' } else { 'Info' }
            $values = @{
                total = Format-TcNumber ($total / 1024); quota = Format-TcNumber ($quota / 1024); margin = $margin
                estimated = $(if ($estimated) { Get-TcRulePart 'CON-CAPACITY' 'estimated' } else { '' })
                breakdown = @($volumes.Keys | ForEach-Object { if ($_ -in $unread) { '{0} not read' -f (Get-TcRuleTenantName $_) } else { '{0} {1} GB' -f (Get-TcRuleTenantName $_), (Format-TcNumber ($volumes[$_] / 1024)) } }) -join ' - '
                missing = Format-TcNumber (($total - $quota * (1 - $margin / 100)) / 1024)
                unread = @($unread | ForEach-Object { Get-TcRuleTenantName $_ }) -join ', '
            }
            if ($unread.Count -and $severity -eq 'Info') { Add-TcFinding 'CON-CAPACITY' 'All' -Variant 'unread' -Values $values }
            elseif ($unread.Count) { Add-TcFinding 'CON-CAPACITY' 'All' -Severity $severity -Variant 'unreadShort' -Values $values }
            else {
                $variant = if ($severity -eq 'Info') { '' } else { 'short' }
                Add-TcFinding 'CON-CAPACITY' 'All' -Severity $severity -Variant $variant -Values $values
            }
        }

        $licensesRead = -not @(Get-TcRuleUnreadRole 'Target' 'licenses').Count
        $sku = Get-TcRuleLicenseSku
        $needs = [ordered]@{}
        foreach ($source in $sources) { $needs[$source] = @(Get-TcRuleRow $source 'users' | Where-Object { (Get-TcProperty $_ 'Type') -eq 'Member' -and (Test-TcRowTrue $_ 'Enabled') -and (Get-TcRowInteger $_ 'License count') -gt 0 }).Count }
        $needed = (@($needs.Values) | Measure-Object -Sum).Sum
        $license = Get-TcRuleRow 'Target' 'licenses' | Where-Object { (Get-TcProperty $_ 'SKU') -eq $sku } | Select-Object -First 1
        $available = if ($license) { [int](Get-TcProperty $license 'Available') } else { 0 }
        $unreadSources = @(Get-TcRuleUnreadRole $sources 'users')
        $unread = @($unreadSources) + @(if (-not $licensesRead) { 'Target' })
        if ($needed -or $unread.Count) {
            $breakdown = @($needs.Keys | ForEach-Object { if ($_ -in $unreadSources) { '{0} not read' -f (Get-TcRuleTenantName $_) } else { '{0} {1}' -f (Get-TcRuleTenantName $_), $needs[$_] } }) -join ' - '
            $values = @{
                sku = $(if ($sku) { $sku } else { 'Expected' }); needed = $needed; available = $(if ($licensesRead) { $available } else { 'unknown' }); breakdown = $breakdown; missing = $needed - $available
                unread = @($unread | ForEach-Object { Get-TcRuleTenantName $_ }) -join ', '
            }
            if ($unread.Count) { Add-TcFinding 'CON-LICENSES' 'All' -Variant $(if ($licensesRead -and $available -lt $needed) { 'unreadShort' } else { 'unread' }) -Values $values }
            elseif ($available -lt $needed) { Add-TcFinding 'CON-LICENSES' 'All' -Variant 'short' -Values $values }
            else { Add-TcFinding 'CON-LICENSES' 'All' -Values $values }
        }

        $voice = [ordered]@{}
        $numbers = @{}
        foreach ($source in $sources) {
            $voice[$source] = @(Get-TcRuleRow $source 'teamsUsers' | Where-Object { Test-TcRowTrue $_ 'Enterprise Voice' }).Count
            foreach ($number in Get-TcRuleRow $source 'phoneNumbers') { $type = [string](Get-TcProperty $number 'Type'); $numbers[$type] = 1 + [int]$numbers[$type] }
        }
        $voiceUsers = (@($voice.Values) | Measure-Object -Sum).Sum
        $unreadSources = @(Get-TcRuleUnreadRole $sources 'teamsUsers', 'phoneNumbers')
        if ($voiceUsers -or $numbers.Count -or $unreadSources.Count) {
            $phone = (@(Get-TcRuleRow 'Target' 'licenses' | Where-Object { (Get-TcProperty $_ 'Plans') -match 'MCOEV' -and (Get-TcProperty $_ 'SKU') -notmatch 'VIRTUALUSER' } | ForEach-Object { [int](Get-TcProperty $_ 'Available') }) | Measure-Object -Sum).Sum
            $unread = @($unreadSources) + @(if (-not $licensesRead) { 'Target' })
            $short = $licensesRead -and $phone -lt $voiceUsers
            $values = @{
                users = $voiceUsers; numbers = (@($numbers.Values) | Measure-Object -Sum).Sum; available = $(if ($licensesRead) { [int]$phone } else { 'unknown' })
                breakdown = @($voice.Keys | ForEach-Object { if ($_ -in $unreadSources) { '{0} not read' -f (Get-TcRuleTenantName $_) } else { '{0} {1}' -f (Get-TcRuleTenantName $_), $voice[$_] } }) -join ' - '
                types = @($numbers.Keys | ForEach-Object { '{0} {1}' -f $_, $numbers[$_] }) -join ' - '
                unread = @($unread | ForEach-Object { Get-TcRuleTenantName $_ }) -join ', '
            }
            if ($unread.Count) { Add-TcFinding 'CON-VOICE' 'All' -Severity $(if ($short) { 'High' } else { '' }) -Variant 'unread' -Values $values }
            else { Add-TcFinding 'CON-VOICE' 'All' -Severity $(if ($short) { 'High' } else { 'Info' }) -Values $values }
        }
    }

    { # Third-party applications across the sources
        $apps = @{}
        foreach ($source in $script:TcRuleRun['Sources']) {
            foreach ($app in Get-TcRuleRow $source 'servicePrincipals' | Where-Object { (Get-TcProperty $_ 'Origin') -eq 'Third party' -and (Test-TcRowTrue $_ 'Enabled') }) {
                $key = ([string](Get-TcProperty $app 'Name')).ToLowerInvariant()
                if (-not $apps.ContainsKey($key)) { $apps[$key] = @{ name = Get-TcProperty $app 'Name'; roles = @{} } }
                $apps[$key]['roles'][$source] = 1
            }
        }
        if (-not $apps.Count) { return }
        $inTarget = @{}
        foreach ($app in Get-TcRuleRow 'Target' 'servicePrincipals') { $inTarget[([string](Get-TcProperty $app 'Name')).ToLowerInvariant()] = 1 }
        $present = @($apps.Keys | Where-Object { $inTarget.ContainsKey($_) }).Count
        Add-TcFinding 'CON-APPLICATIONS' 'All' -Values @{ count = $apps.Count; present = $present } -Items ($apps.Keys | Sort-Object | ForEach-Object {
                '{0} - {1}{2}' -f $apps[$_]['name'], (@($apps[$_]['roles'].Keys | ForEach-Object { Get-TcRuleTenantName $_ }) -join ', '), $(if ($inTarget.ContainsKey($_)) { ' - already in the target' })
            })
    }

    { # Domains to move
        $sources = @($script:TcRuleRun['Sources'])
        if (-not $sources.Count) { return }
        $items = foreach ($source in $sources) {
            $dns = @{}
            foreach ($row in Get-TcRuleRow $source 'dnsSummary') { $dns[([string](Get-TcProperty $row 'Domain')).ToLowerInvariant()] = $row }
            foreach ($domain in Get-TcSourceDomain $source) {
                $row = $dns[$domain]
                '{0} - {1} - {2}{3}' -f (Get-TcRuleTenantName $source), $domain, $(if ($row) { Get-TcProperty $row 'DNS host' } else { 'host to confirm' }), $(if ($row) { " - flow $(Get-TcProperty $row 'Inbound mail flow') - MX TTL $(Get-TcProperty $row 'MX TTL')" })
            }
        }
        Add-TcFinding 'CON-DOMAINS' 'All' -Values @{ count = @($items).Count; sources = $sources.Count } -Items @($items)
    }

    { # Teams policy types customized in several places
        $policies = @{}
        foreach ($source in $script:TcRuleRun['Sources']) {
            foreach ($policy in Get-TcRuleRow $source 'teamsPolicies' | Where-Object { Test-TcRowTrue $_ 'Custom' }) {
                $type = [string](Get-TcProperty $policy 'Type')
                if (-not $policies.ContainsKey($type)) { $policies[$type] = [System.Collections.Generic.List[string]]::new() }
                $policies[$type].Add(('{0} ({1})' -f (([string](Get-TcProperty $policy 'Identity')) -replace '^Tag:', ''), (Get-TcRuleTenantName $source)))
            }
        }
        $several = @($policies.Keys | Where-Object { @($policies[$_]).Count -ge 2 } | Sort-Object)
        if ($several.Count) { Add-TcFinding 'CON-TEAMS-POLICIES' 'All' -Values @{ count = $several.Count } -Items ($several | ForEach-Object { '{0}: {1}' -f $_, (@($policies[$_]) -join ', ') }) }
    }
}

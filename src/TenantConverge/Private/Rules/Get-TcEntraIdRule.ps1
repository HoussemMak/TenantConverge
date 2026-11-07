function Get-TcEntraIdRule {
    <#
    .SYNOPSIS
    Returns the Entra ID rules, as script blocks that take the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Inactive members
        param($Role)
        if (-not (Test-TcRuleTable $Role 'users')) { return }
        $days = [int](Get-TcRuleThreshold 'inactiveDays')
        $members = @(Get-TcRuleRow $Role 'users' | Where-Object { (Get-TcProperty $_ 'Type') -eq 'Member' -and (Test-TcRowTrue $_ 'Enabled') -and $null -ne (Get-TcProperty $_ 'Days inactive') })
        if (-not $members.Count) { return }
        $inactive = @($members | Where-Object { $d = [int](Get-TcProperty $_ 'Days inactive'); ($d -ge $days -or $d -eq -1) -and (Get-TcRowInteger $_ 'Days since creation') -ge $days })
        if (-not $inactive.Count) { return }
        $never = @($inactive | Where-Object { [int](Get-TcProperty $_ 'Days inactive') -eq -1 }).Count
        $items = $inactive | ForEach-Object { $d = [int](Get-TcProperty $_ 'Days inactive'); '{0} - {1}' -f (Get-TcProperty $_ 'UPN'), $(if ($d -eq -1) { 'never signed in' } else { "$d days" }) }
        Add-TcFinding 'ENT-INACTIVE' $Role -Values @{ count = $inactive.Count; days = $days; members = $members.Count; never = $never } -Items $items
    }

    { # Disabled accounts that keep licenses
        param($Role)
        $rows = @(Get-TcRuleRow $Role 'users' | Where-Object { -not (Test-TcRowTrue $_ 'Enabled') -and (Get-TcRowInteger $_ 'License count') -gt 0 })
        if (-not $rows.Count) { return }
        $licenses = (@($rows | ForEach-Object { [int](Get-TcProperty $_ 'License count') }) | Measure-Object -Sum).Sum
        Add-TcFinding 'ENT-DISABLED-LICENSED' $Role -Values @{ count = $rows.Count; licenses = $licenses } -Items ($rows | ForEach-Object { '{0} - {1}' -f (Get-TcProperty $_ 'UPN'), (Get-TcProperty $_ 'Licenses') })
    }

    { # Guests
        param($Role)
        $guests = @(Get-TcRuleRow $Role 'users' | Where-Object { (Get-TcProperty $_ 'Type') -eq 'Guest' })
        if (-not $guests.Count) { return }
        $days = [int](Get-TcRuleThreshold 'inactiveDays')
        $stale = @($guests | Where-Object {
                $d = Get-TcProperty $_ 'Days inactive'
                (Get-TcProperty $_ 'Invitation state') -eq 'PendingAcceptance' -or ($null -ne $d -and ([int]$d -ge $days -or [int]$d -eq -1))
            })
        $values = @{ count = $guests.Count; stale = $stale.Count; days = $days }
        if ($Role -ne 'Target') {
            $describe = {
                $d = Get-TcProperty $_ 'Days inactive'
                if ((Get-TcProperty $_ 'Invitation state') -eq 'PendingAcceptance') { 'invitation never accepted' }
                elseif ($null -eq $d) { 'activity unknown' }
                elseif ([int]$d -eq -1) { 'never signed in' }
                else { "$d days" }
            }
            $sorted = $guests | Sort-Object { $d = Get-TcProperty $_ 'Days inactive'; if ("$d" -ne '') { [int]$d } else { 99999 } }
            Add-TcFinding 'ENT-GUESTS' $Role -Values $values -Items ($sorted | ForEach-Object { '{0} - {1}' -f (Get-TcProperty $_ 'UPN'), (& $describe) })
        }
        elseif ($stale.Count) {
            Add-TcFinding 'ENT-GUESTS' $Role -Values $values -Items ($stale | ForEach-Object { Get-TcProperty $_ 'UPN' })
        }
    }

    { # Global Administrators
        param($Role)
        if (-not (Test-TcRuleTable $Role 'adminRoles')) { return }
        $admins = @(Get-TcRuleRow $Role 'adminRoles' | Where-Object { (Get-TcProperty $_ 'Role') -eq 'Global Administrator' -and (Get-TcProperty $_ 'Assignment') -eq 'Active' })
        $external = @($admins | Where-Object { (Get-TcProperty $_ 'Principal') -match '#EXT#' })
        if ($admins.Count -gt 5 -or $admins.Count -lt 2 -or $external.Count) {
            $severity = if ($admins.Count -gt 8 -or $external.Count) { 'High' } else { 'Medium' }
            $note = if ($external.Count) { Format-TcRuleText (Get-TcRulePart 'ENT-ADMINS' 'external') @{ count = $external.Count } } else { '' }
            Add-TcFinding 'ENT-ADMINS' $Role -Severity $severity -Values @{ count = $admins.Count; external = $note } -Items ($admins | ForEach-Object { '{0} ({1})' -f (Get-TcProperty $_ 'Principal'), (Get-TcProperty $_ 'Principal type') })
        }
    }

    { # MFA for all and legacy authentication
        param($Role)
        $policies = @(Get-TcRuleRow $Role 'conditionalAccess')
        $defaults = Get-TcRuleSetting $Role 'securitySettings' 'Security defaults enabled'
        if (-not (Test-TcRuleTable $Role 'conditionalAccess') -and $null -eq $defaults) { return }
        $mfa = @($policies | Where-Object { Test-TcRowTrue $_ 'MFA for all' })
        $legacy = @($policies | Where-Object { Test-TcRowTrue $_ 'Blocks legacy authentication' })
        $reportOnly = @($policies | Where-Object { (Get-TcProperty $_ 'State') -eq 'enabledForReportingButNotEnforced' })
        if (-not $mfa.Count -and -not (Test-TcTrue $defaults)) {
            Add-TcFinding 'ENT-MFA' $Role -Values @{ reportOnly = $reportOnly.Count } -Items ($policies | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'State'), (Get-TcProperty $_ 'Controls') })
        }
        if (-not $legacy.Count -and -not (Test-TcTrue $defaults)) { Add-TcFinding 'ENT-LEGACY-AUTH' $Role }
    }

    { # MFA registration
        param($Role)
        $rows = @(Get-TcRuleRow $Role 'mfaRegistrations' | Where-Object { (Get-TcProperty $_ 'Type') -eq 'member' -and -not (Test-TcRowTrue $_ 'MFA registered') })
        if (-not $rows.Count) { return }
        $active = @{}
        foreach ($user in Get-TcRuleRow $Role 'users') { if ((Test-TcRowTrue $user 'Enabled') -and (Get-TcProperty $user 'Type') -eq 'Member') { $active[[string](Get-TcProperty $user 'UPN')] = 1 } }
        if ($active.Count) { $rows = @($rows | Where-Object { $active.ContainsKey([string](Get-TcProperty $_ 'UPN')) }) }
        if (-not $rows.Count) { return }
        Add-TcFinding 'ENT-MFA-REGISTRATION' $Role -Values @{ count = $rows.Count } -Items ($rows | ForEach-Object { Get-TcProperty $_ 'UPN' })
    }

    { # Group creation in the target
        param($Role)
        if ($Role -ne 'Target' -or -not (Test-TcRuleTable $Role 'groupSettings')) { return }
        $value = Get-TcRuleSetting $Role 'groupSettings' 'Group.Unified.EnableGroupCreation'
        if ($null -eq $value -or (Test-TcTrue $value)) { Add-TcFinding 'ENT-GROUP-CREATION' $Role }
    }

    { # User permissions
        param($Role)
        $invitations = Get-TcRuleSetting $Role 'securitySettings' 'Invitations allowed from'
        $apps = Get-TcRuleSetting $Role 'securitySettings' 'User permissions.allowedToCreateApps'
        $details = @()
        if ($invitations -eq 'everyone') { $details += Get-TcRulePart 'ENT-AUTHORIZATION' 'anyoneInvites' }
        if (Test-TcTrue $apps) { $details += Get-TcRulePart 'ENT-AUTHORIZATION' 'usersRegisterApps' }
        if ($details.Count) { Add-TcFinding 'ENT-AUTHORIZATION' $Role -Values @{ details = $details -join '; ' } }
    }

    { # Secrets and certificates
        param($Role)
        $limit = [int](Get-TcRuleThreshold 'secretExpiryDays')
        $apps = @(Get-TcRuleRow $Role 'applications' | Where-Object {
                $d = Get-TcProperty $_ 'Days to expiry'
                (Get-TcRowInteger $_ 'Expired') -gt 0 -or ($null -ne $d -and "$d" -ne '' -and [int]$d -le $limit)
            })
        if (-not $apps.Count) { return }
        Add-TcFinding 'ENT-SECRETS' $Role -Values @{ count = $apps.Count; days = $limit } -Items ($apps | ForEach-Object {
                $d = Get-TcProperty $_ 'Days to expiry'
                '{0} - expired {1} - next expiry {2}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Expired'), $(if ("$d") { "in $d days" } else { 'none' })
            })
    }

    { # Applications that do not follow users
        param($Role)
        if ($Role -eq 'Target') { return }
        $third = @(Get-TcRuleRow $Role 'servicePrincipals' | Where-Object { (Get-TcProperty $_ 'Origin') -eq 'Third party' -and (Test-TcRowTrue $_ 'Enabled') })
        $consented = @(Get-TcRuleRow $Role 'delegatedConsents' | Where-Object { (Get-TcProperty $_ 'Consent type') -like 'Administrator*' } | ForEach-Object { Get-TcProperty $_ 'Application' } | Sort-Object -Unique)
        if ($third.Count) {
            Add-TcFinding 'ENT-THIRD-PARTY-APPS' $Role -Values @{ count = $third.Count; consented = $consented.Count } -Items ($third | Sort-Object { Get-TcProperty $_ 'Name' } | ForEach-Object {
                    $publisher = Get-TcProperty $_ 'Publisher'
                    '{0}{1}{2}' -f (Get-TcProperty $_ 'Name'), $(if ($publisher) { " - $publisher" } else { '' }), $(if ($consented -contains (Get-TcProperty $_ 'Name')) { ' - admin consent' } else { '' })
                })
        }
        $own = @(Get-TcRuleRow $Role 'applications')
        if ($own.Count) {
            Add-TcFinding 'ENT-APP-REGISTRATIONS' $Role -Values @{ count = $own.Count } -Items ($own | ForEach-Object { '{0} - {1} - created {2}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Audience'), (Get-TcProperty $_ 'Created') })
        }
    }

    { # Directory synchronization
        param($Role)
        $sync = Get-TcRuleSetting $Role 'organizationSettings' 'AD sync enabled'
        $days = Get-TcRuleSetting $Role 'organizationSettings' 'Days since last sync'
        if ($Role -ne 'Target' -and (Test-TcTrue $sync)) { Add-TcFinding 'ENT-SYNC-SOURCE' $Role -Values @{ days = $days } }
        if ($Role -eq 'Target' -and (Test-TcTrue $sync) -and $null -ne $days -and [int]$days -ge 1) { Add-TcFinding 'ENT-SYNC-TARGET' $Role -Values @{ days = $days } }
    }

    { # License errors and stale devices
        param($Role)
        $errors = @(Get-TcRuleRow $Role 'users' | Where-Object { (Get-TcRowInteger $_ 'License errors') -gt 0 })
        if ($errors.Count) { Add-TcFinding 'ENT-LICENSE-ERRORS' $Role -Values @{ count = $errors.Count } -Items ($errors | ForEach-Object { Get-TcProperty $_ 'UPN' }) }
        $stale = @(Get-TcRuleRow $Role 'devices' | Where-Object { $d = Get-TcProperty $_ 'Days inactive'; $null -ne $d -and "$d" -ne '' -and [int]$d -ge 90 })
        if ($stale.Count -ge 5) {
            Add-TcFinding 'ENT-STALE-DEVICES' $Role -Values @{ count = $stale.Count } -Items ($stale | ForEach-Object { '{0} - {1} - {2} days' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'OS'), (Get-TcProperty $_ 'Days inactive') })
        }
    }

    { # Business plan cap of the target
        param($Role)
        if ($Role -ne 'Target') { return }
        $capped = @(Get-TcRuleRow $Role 'licenses' | Where-Object { (Get-TcProperty $_ 'SKU') -match '^(SPB|O365_BUSINESS_PREMIUM|O365_BUSINESS_ESSENTIALS|O365_BUSINESS|SMB_BUSINESS.*)$' -and [int](Get-TcProperty $_ 'Purchased') -ge 290 })
        if ($capped.Count) {
            $plans = @($capped | ForEach-Object { '{0}: {1} purchased, {2} free' -f (Get-TcProperty $_ 'SKU'), (Get-TcProperty $_ 'Purchased'), (Get-TcProperty $_ 'Available') }) -join '; '
            Add-TcFinding 'ENT-BUSINESS-CAP' $Role -Values @{ plans = $plans }
        }
    }

    { # Legacy sign-ins and sign-in countries
        param($Role)
        $legacy = @(Get-TcRuleRow $Role 'legacySignIns')
        if ($legacy.Count) {
            $accounts = @($legacy | ForEach-Object { Get-TcProperty $_ 'UPN' } | Sort-Object -Unique)
            $clients = @($legacy | Group-Object { Get-TcProperty $_ 'Client' } | Sort-Object Count -Descending | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Count }) -join ', '
            Add-TcFinding 'ENT-LEGACY-SIGN-INS' $Role -Values @{ count = $accounts.Count; clients = $clients } -Items ($legacy | Sort-Object { - [int](Get-TcProperty $_ 'Sign-ins') } | ForEach-Object { '{0} - {1} - {2} sign-in(s)' -f (Get-TcProperty $_ 'UPN'), (Get-TcProperty $_ 'Client'), (Get-TcProperty $_ 'Sign-ins') })
        }

        $homeCountries = @($script:TcRuleRun['HomeCountry'])
        if (-not $homeCountries.Count) { $homeCountries = @(Get-TcRuleSetting $Role 'organizationSettings' 'Country' | Where-Object { $_ }) }
        $countries = @(Get-TcRuleRow $Role 'signInSummary' | Where-Object { (Get-TcProperty $_ 'Dimension') -eq 'Country' -and (Get-TcProperty $_ 'Value') -notin ($homeCountries + '(empty)') })
        if ($countries.Count) {
            Add-TcFinding 'ENT-COUNTRIES' $Role -Values @{ count = $countries.Count; home = $homeCountries -join ', ' } -Items ($countries | Sort-Object { - [int](Get-TcProperty $_ 'Sign-ins') } | ForEach-Object { '{0} - {1} sign-in(s) - {2} user(s)' -f (Get-TcProperty $_ 'Value'), (Get-TcProperty $_ 'Sign-ins'), (Get-TcProperty $_ 'Users') })
        }
    }

    { # Broad application permissions
        param($Role)
        $sensitive = '(?i)(ReadWrite\.All|FullControl|full_access_as_app|Mail\.Send|Mail\.Read|Directory\.ReadWrite|RoleManagement|Application\.ReadWrite|Sites\.Read\.All|Files\.Read\.All|User\.ReadWrite|Exchange\.ManageAsApp)'
        $rows = @(Get-TcRuleRow $Role 'applicationPermissions' | Where-Object { (Get-TcProperty $_ 'Permission') -match $sensitive })
        if (-not $rows.Count) { return }
        $apps = @($rows | ForEach-Object { Get-TcProperty $_ 'Application' } | Sort-Object -Unique)
        Add-TcFinding 'ENT-APP-PERMISSIONS' $Role -Values @{ count = $apps.Count; permissions = $rows.Count } -Items ($rows | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'Application'), (Get-TcProperty $_ 'Resource'), (Get-TcProperty $_ 'Permission') })
    }

    { # Risky accounts
        param($Role)
        $rows = @(Get-TcRuleRow $Role 'riskyUsers')
        if ($rows.Count) { Add-TcFinding 'ENT-RISK' $Role -Values @{ count = $rows.Count } -Items ($rows | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'UPN'), (Get-TcProperty $_ 'Level'), (Get-TcProperty $_ 'State') }) }
    }

    { # Synchronization errors
        param($Role)
        $rows = @(Get-TcRuleRow $Role 'users' | Where-Object { (Get-TcRowInteger $_ 'Sync errors') -gt 0 })
        if ($rows.Count) { Add-TcFinding 'ENT-SYNC-ERRORS' $Role -Values @{ count = $rows.Count } -Items ($rows | ForEach-Object { Get-TcProperty $_ 'UPN' }) }
    }
}

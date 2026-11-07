function Get-TcTeamsPhoneRule {
    <#
    .SYNOPSIS
    Returns the Teams Phone rules, as script blocks that take the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Numbers, voice users and what the tenant runs for them
        param($Role)
        if ($Role -eq 'Target') { return }
        $numbers = @(Get-TcRuleRow $Role 'phoneNumbers')
        if ($numbers.Count) {
            $breakdown = @($numbers | Group-Object { Get-TcProperty $_ 'Type' } | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Count }) -join ' - '
            $actions = @()
            foreach ($kind in @(@('CallingPlan', 'callingPlan'), @('DirectRouting', 'directRouting'), @('OperatorConnect', 'operatorConnect'))) {
                if (@($numbers | Where-Object { (Get-TcProperty $_ 'Type') -eq $kind[0] }).Count) { $actions += Get-TcRulePart 'TEL-NUMBERS' $kind[1] }
            }
            $assigned = @($numbers | Where-Object { (Get-TcProperty $_ 'Assignment') -ne 'Unassigned' }).Count
            Add-TcFinding 'TEL-NUMBERS' $Role -Values @{ count = $numbers.Count; breakdown = $breakdown; assigned = $assigned; actions = $actions -join ' ' } -Items ($numbers | ForEach-Object { '{0} - {1} - {2} - {3}' -f (Get-TcProperty $_ 'Number'), (Get-TcProperty $_ 'Type'), (Get-TcProperty $_ 'Assignment'), (Get-TcProperty $_ 'Assigned to') })
        }

        $voice = @(Get-TcRuleRow $Role 'teamsUsers' | Where-Object { Test-TcRowTrue $_ 'Enterprise Voice' })
        if ($voice.Count) {
            $numbered = @($voice | Where-Object { Get-TcProperty $_ 'Number' }).Count
            Add-TcFinding 'TEL-USERS' $Role -Values @{ count = $voice.Count; numbered = $numbered } -Items ($voice | ForEach-Object { '{0} - {1}' -f (Get-TcProperty $_ 'UPN'), (Get-TcProperty $_ 'Number') })
        }

        $attendants = @(Get-TcRuleRow $Role 'autoAttendants')
        $queues = @(Get-TcRuleRow $Role 'callQueues')
        $accounts = @(Get-TcRuleRow $Role 'resourceAccounts')
        if ($attendants.Count -or $queues.Count -or $accounts.Count) {
            $items = @($attendants | ForEach-Object { 'Attendant - {0} - {1} flow(s) - {2} schedule(s)' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Call flows'), (Get-TcProperty $_ 'Schedules') }) +
            @($queues | ForEach-Object { 'Queue - {0} - {1} agent(s) - {2}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Agents'), (Get-TcProperty $_ 'Routing') }) +
            @($accounts | ForEach-Object { 'Account - {0} - {1} - {2}' -f (Get-TcProperty $_ 'UPN'), (Get-TcProperty $_ 'Usage'), (Get-TcProperty $_ 'Number') })
            Add-TcFinding 'TEL-VOICE-APPS' $Role -Values @{ attendants = $attendants.Count; queues = $queues.Count; accounts = $accounts.Count } -Items $items
        }

        $addresses = @(Get-TcRuleRow $Role 'emergencyAddresses')
        if ($addresses.Count) { Add-TcFinding 'TEL-EMERGENCY' $Role -Values @{ count = $addresses.Count } -Items ($addresses | ForEach-Object { '{0} - {1}, {2} - {3}' -f (Get-TcProperty $_ 'Description'), (Get-TcProperty $_ 'Address'), (Get-TcProperty $_ 'City'), (Get-TcProperty $_ 'Validation') }) }

        $gateways = @(Get-TcRuleRow $Role 'pstnGateways')
        if ($gateways.Count) {
            $domains = @(Get-TcSourceDomain $Role)
            $bound = @($gateways | Where-Object { $fqdn = ([string](Get-TcProperty $_ 'FQDN')).ToLowerInvariant(); @($domains | Where-Object { $fqdn.EndsWith(".$_") }).Count })
            $items = $gateways | ForEach-Object { '{0}:{1} - enabled {2}' -f (Get-TcProperty $_ 'FQDN'), (Get-TcProperty $_ 'Port'), (Get-TcProperty $_ 'Enabled') }
            if ($bound.Count) { Add-TcFinding 'TEL-DIRECT-ROUTING' $Role -Variant 'bound' -Values @{ count = $gateways.Count; bound = $bound.Count } -Items $items }
            else { Add-TcFinding 'TEL-DIRECT-ROUTING' $Role -Values @{ count = $gateways.Count } -Items $items }
        }

        $plans = @(Get-TcRuleRow $Role 'dialPlans' | Where-Object { (Get-TcProperty $_ 'Name') -ne 'Global' })
        $routes = @(Get-TcRuleRow $Role 'voiceRoutes')
        $policies = @(Get-TcRuleRow $Role 'voiceRoutingPolicies' | Where-Object { (Get-TcProperty $_ 'Name') -ne 'Global' })
        if ($plans.Count -or $routes.Count -or $policies.Count) {
            $items = @($plans | ForEach-Object { 'Plan - {0} - {1} rule(s)' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Rules') }) +
            @($routes | ForEach-Object { 'Route - {0} - {1}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Pattern') }) +
            @($policies | ForEach-Object { 'Policy - {0}' -f (Get-TcProperty $_ 'Name') })
            Add-TcFinding 'TEL-DIAL-PLANS' $Role -Values @{ plans = $plans.Count; routes = $routes.Count; policies = $policies.Count } -Items $items
        }

        $bridges = @(Get-TcRuleRow $Role 'conferenceBridges' | Where-Object { Get-TcProperty $_ 'Default number' })
        if ($bridges.Count) { Add-TcFinding 'TEL-CONFERENCING' $Role -Items ($bridges | ForEach-Object { '{0} - {1}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Default number') }) }

        $settings = @(Get-TcRuleRow $Role 'userCallingSettings' | Where-Object { (Get-TcProperty $_ 'Forwarding') -or (Get-TcProperty $_ 'Unanswered') -or (Get-TcProperty $_ 'Delegates') -or (Get-TcProperty $_ 'Call group') })
        if ($settings.Count) { Add-TcFinding 'TEL-CALLING-SETTINGS' $Role -Values @{ count = $settings.Count } -Items ($settings | ForEach-Object { '{0} - {1} {2} {3}' -f (Get-TcProperty $_ 'UPN'), (Get-TcProperty $_ 'Forwarding'), (Get-TcProperty $_ 'Unanswered'), (Get-TcProperty $_ 'Delegates') }) }
    }

    { # Phone routing already in the target
        param($Role)
        if ($Role -ne 'Target') { return }
        $routing = @(Get-TcRuleRow $Role 'domains' | Where-Object { (Get-TcProperty $_ 'Domain') -match '(?i)teams.*voice|sbc' })
        $gateways = @(Get-TcRuleRow $Role 'pstnGateways')
        if ($routing.Count -or $gateways.Count) {
            $names = @($routing | ForEach-Object { Get-TcProperty $_ 'Domain' })
            Add-TcFinding 'TEL-ROUTING-TARGET' $Role -Values @{ domains = $names -join ', '; gateways = $gateways.Count } -Items ($names + @($gateways | ForEach-Object { Get-TcProperty $_ 'FQDN' }))
        }
    }

    { # Schedules and network topology
        param($Role)
        if ($Role -eq 'Target') { return }
        $schedules = @(Get-TcRuleRow $Role 'phoneSchedules')
        if ($schedules.Count) { Add-TcFinding 'TEL-SCHEDULES' $Role -Values @{ count = $schedules.Count } -Items ($schedules | ForEach-Object { '{0} - {1} - used {2} time(s)' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Type'), (Get-TcProperty $_ 'Used by') }) }
        $network = @(Get-TcRuleRow $Role 'phoneNetworkTopology')
        if ($network.Count) { Add-TcFinding 'TEL-NETWORK' $Role -Values @{ count = $network.Count } -Items ($network | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'Type'), (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Detail') }) }
    }
}

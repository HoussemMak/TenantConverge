function Get-TcTeamsRule {
    <#
    .SYNOPSIS
    Returns the Teams rules, as script blocks that take the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Teams
        param($Role)
        $composition = @(Get-TcRuleRow $Role 'teamComposition')
        if ($composition.Count) {
            $owners = @($composition | Where-Object { [int](Get-TcProperty $_ 'Owners') -le 1 })
            if ($owners.Count) { Add-TcFinding 'TMS-OWNERS' $Role -Values @{ count = $owners.Count } -Items ($owners | ForEach-Object { '{0} - {1} owner(s)' -f (Get-TcProperty $_ 'Team'), (Get-TcProperty $_ 'Owners') }) }

            if ($Role -ne 'Target') {
                $privateTeams = @($composition | Where-Object { [int](Get-TcProperty $_ 'Private channels') -gt 0 })
                $sharedTeams = @($composition | Where-Object { [int](Get-TcProperty $_ 'Shared channels') -gt 0 })
                if ($privateTeams.Count -or $sharedTeams.Count) {
                    $privateTotal = (@($composition | ForEach-Object { [int](Get-TcProperty $_ 'Private channels') }) | Measure-Object -Sum).Sum
                    $sharedTotal = (@($composition | ForEach-Object { [int](Get-TcProperty $_ 'Shared channels') }) | Measure-Object -Sum).Sum
                    $items = @($privateTeams | ForEach-Object { '{0} - {1} private channel(s)' -f (Get-TcProperty $_ 'Team'), (Get-TcProperty $_ 'Private channels') }) + @($sharedTeams | ForEach-Object { '{0} - {1} shared channel(s)' -f (Get-TcProperty $_ 'Team'), (Get-TcProperty $_ 'Shared channels') })
                    Add-TcFinding 'TMS-CHANNELS' $Role -Severity $(if ($sharedTeams.Count) { 'High' } else { 'Medium' }) -Values @{ private = $privateTotal; shared = $sharedTotal } -Items $items
                }
                $guests = @($composition | Where-Object { [int](Get-TcProperty $_ 'Guests') -gt 0 })
                if ($guests.Count) {
                    $total = (@($guests | ForEach-Object { [int](Get-TcProperty $_ 'Guests') }) | Measure-Object -Sum).Sum
                    Add-TcFinding 'TMS-GUESTS' $Role -Values @{ count = $guests.Count; guests = $total } -Items ($guests | ForEach-Object { '{0} - {1} guest(s)' -f (Get-TcProperty $_ 'Team'), (Get-TcProperty $_ 'Guests') })
                }
            }
        }

        if ($Role -eq 'Target') { return }

        $archived = @(Get-TcRuleRow $Role 'teams' | Where-Object { Test-TcRowTrue $_ 'Archived' })
        if ($archived.Count) { Add-TcFinding 'TMS-ARCHIVED' $Role -Values @{ count = $archived.Count } -Items ($archived | ForEach-Object { Get-TcProperty $_ 'Name' }) }

        $policies = @(Get-TcRuleRow $Role 'teamsPolicies' | Where-Object { Test-TcRowTrue $_ 'Custom' })
        if ($policies.Count) {
            $assigned = @{}
            foreach ($user in Get-TcRuleRow $Role 'teamsUsers') {
                foreach ($policy in ([string](Get-TcProperty $user 'Policies') -split ';\s*')) { if ($policy) { $assigned[$policy] = 1 + [int]$assigned[$policy] } }
            }
            $inTarget = @{}
            foreach ($policy in Get-TcRuleRow 'Target' 'teamsPolicies') { $inTarget["$(Get-TcProperty $policy 'Type')|$(Get-TcProperty $policy 'Identity')"] = 1 }
            Add-TcFinding 'TMS-POLICIES' $Role -Values @{ count = $policies.Count } -Items ($policies | ForEach-Object {
                    $type = Get-TcProperty $_ 'Type'
                    $identity = Get-TcProperty $_ 'Identity'
                    $name = ([string]$identity) -replace '^Tag:', ''
                    '{0} - {1} - {2} user(s){3}' -f $type, $name, [int]$assigned["$type=$name"], $(if ($inTarget["$type|$identity"]) { ' - exists in the target' } else { '' })
                })
        }

        $apps = @(Get-TcRuleRow $Role 'teamsApps')
        if ($apps.Count) { Add-TcFinding 'TMS-APPS' $Role -Values @{ count = $apps.Count } -Items ($apps | ForEach-Object { '{0} - version {1}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Version') }) }

        $devices = @(Get-TcRuleRow $Role 'teamsDevices')
        if ($devices.Count) { Add-TcFinding 'TMS-DEVICES' $Role -Values @{ count = $devices.Count } -Items ($devices | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'Type'), (Get-TcProperty $_ 'Model'), (Get-TcProperty $_ 'User') }) }
    }
}

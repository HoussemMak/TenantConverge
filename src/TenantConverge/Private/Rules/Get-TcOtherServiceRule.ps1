function Get-TcOtherServiceRule {
    <#
    .SYNOPSIS
    Returns the rules on other services, as script blocks that take the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Concealed names in the usage reports
        param($Role)
        if (Test-TcTrue (Get-TcRuleSetting $Role 'reportSettings' 'Names concealed in reports')) { Add-TcFinding 'AUT-CONCEALED-REPORTS' $Role }
    }

    { # Bookings, Viva Engage, Planner and Copilot
        param($Role)
        if ($Role -eq 'Target') { return }
        $bookings = @(Get-TcRuleRow $Role 'bookings')
        $communities = @(Get-TcRuleRow $Role 'vivaCommunities')
        $plans = @(Get-TcRuleRow $Role 'plannerPlans')
        if ($bookings.Count -or $communities.Count -or $plans.Count) {
            $items = @($bookings | ForEach-Object { 'Bookings - {0}' -f (Get-TcProperty $_ 'Name') }) + @($communities | ForEach-Object { 'Viva Engage - {0}' -f (Get-TcProperty $_ 'Name') }) + @($plans | ForEach-Object { 'Planner - {0} > {1}' -f (Get-TcProperty $_ 'Group'), (Get-TcProperty $_ 'Plan') })
            Add-TcFinding 'AUT-SERVICES' $Role -Values @{ bookings = $bookings.Count; communities = $communities.Count; plans = $plans.Count } -Items $items
        }

        $copilot = @(Get-TcRuleRow $Role 'licenses' | Where-Object { (Get-TcProperty $_ 'SKU') -match '(?i)copilot' -and [int](Get-TcProperty $_ 'Consumed') -gt 0 })
        if ($copilot.Count) {
            $total = (@($copilot | ForEach-Object { [int](Get-TcProperty $_ 'Consumed') }) | Measure-Object -Sum).Sum
            Add-TcFinding 'AUT-COPILOT' $Role -Values @{ count = $total } -Items ($copilot | ForEach-Object { '{0} - {1} in use' -f (Get-TcProperty $_ 'SKU'), (Get-TcProperty $_ 'Consumed') })
        }
    }

    { # Secure Score
        param($Role)
        $percent = Get-TcRuleSetting $Role 'secureScore' 'Percentage'
        if ($null -eq $percent) { return }
        $actions = @(Get-TcRuleRow $Role 'secureScoreActions' | Select-Object -First 8)
        $values = @{ percent = $percent; score = Format-TcNumber (Get-TcRuleSetting $Role 'secureScore' 'Current score') 1; maximum = Format-TcNumber (Get-TcRuleSetting $Role 'secureScore' 'Maximum score') }
        Add-TcFinding 'AUT-SECURE-SCORE' $Role -Severity $(if ([int]$percent -lt 40) { 'Medium' } else { 'Info' }) -Values $values -Items ($actions | ForEach-Object { '{0} - +{1} point(s) - {2}' -f (Get-TcProperty $_ 'Control'), (Get-TcProperty $_ 'Possible gain'), (Get-TcProperty $_ 'User impact') })
    }
}

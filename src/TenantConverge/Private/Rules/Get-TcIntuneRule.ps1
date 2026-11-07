function Get-TcIntuneRule {
    <#
    .SYNOPSIS
    Returns the Intune rules, as script blocks that take the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Devices, policies and applications
        param($Role)
        $autopilot = @(Get-TcRuleRow $Role 'autopilotDevices')
        if ($autopilot.Count -and $Role -ne 'Target') {
            $tags = @($autopilot | Group-Object { Get-TcProperty $_ 'Group tag' } | ForEach-Object { '{0} ({1})' -f $(if ($_.Name) { $_.Name } else { 'none' }), $_.Count }) -join ', '
            Add-TcFinding 'INT-AUTOPILOT' $Role -Values @{ count = $autopilot.Count; tags = $tags } -Items ($autopilot | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'Serial number'), (Get-TcProperty $_ 'Model'), (Get-TcProperty $_ 'Group tag') })
        }

        $devices = @(Get-TcRuleRow $Role 'managedDevices')
        $stale = @($devices | Where-Object { $d = Get-TcProperty $_ 'Days inactive'; $null -ne $d -and "$d" -ne '' -and [int]$d -ge 90 })
        if ($stale.Count) { Add-TcFinding 'INT-STALE' $Role -Values @{ count = $stale.Count } -Items ($stale | ForEach-Object { '{0} - {1} - {2} days' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'OS'), (Get-TcProperty $_ 'Days inactive') }) }

        $noncompliant = @($devices | Where-Object { (Get-TcProperty $_ 'Compliance') -eq 'noncompliant' })
        if ($noncompliant.Count -and $Role -eq 'Target') { Add-TcFinding 'INT-NONCOMPLIANT' $Role -Values @{ count = $noncompliant.Count } -Items ($noncompliant | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'OS'), (Get-TcProperty $_ 'User') }) }

        if ($Role -eq 'Target') { return }

        $policies = @(Get-TcRuleRow $Role 'intunePolicies')
        if ($policies.Count) {
            $names = @{}
            foreach ($policy in Get-TcRuleRow 'Target' 'intunePolicies') { $names[([string](Get-TcProperty $policy 'Name')).ToLowerInvariant()] = 1 }
            $missing = @($policies | Where-Object { -not $names.ContainsKey(([string](Get-TcProperty $_ 'Name')).ToLowerInvariant()) }).Count
            Add-TcFinding 'INT-POLICIES' $Role -Values @{ count = $policies.Count; missing = $missing } -Items ($policies | ForEach-Object {
                    '{0} - {1} - {2}{3}' -f (Get-TcProperty $_ 'Category'), (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Platform'), $(if ($names.ContainsKey(([string](Get-TcProperty $_ 'Name')).ToLowerInvariant())) { ' - exists in the target' } else { '' })
                })
        }

        $apps = @(Get-TcRuleRow $Role 'intuneApps' | Where-Object { (Get-TcProperty $_ 'Type') -match '(?i)win32|msi|lob|office|winget|store' -and (Test-TcRowTrue $_ 'Assigned') })
        if ($apps.Count) { Add-TcFinding 'INT-APPS' $Role -Values @{ count = $apps.Count } -Items ($apps | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Type'), (Get-TcProperty $_ 'Publisher') }) }

        $protection = @(Get-TcRuleRow $Role 'appProtectionPolicies')
        if ($protection.Count) { Add-TcFinding 'INT-MAM' $Role -Values @{ count = $protection.Count } -Items ($protection | ForEach-Object { Get-TcProperty $_ 'Name' }) }
    }

    { # Apple connectors and tokens
        param($Role)
        $connectors = @(Get-TcRuleRow $Role 'intuneConnectors')
        if (-not $connectors.Count) { return }
        $expiring = @($connectors | Where-Object { $d = Get-TcProperty $_ 'Days remaining'; "$d" -ne '' -and [int]$d -le 45 })
        $apple = @($connectors | Where-Object { (Get-TcProperty $_ 'Type') -match 'Apple' })
        if ($Role -ne 'Target' -and $apple.Count) {
            Add-TcFinding 'INT-CONNECTORS' $Role -Values @{ count = $apple.Count } -Items ($connectors | ForEach-Object { '{0} - {1} - {2} - {3} days' -f (Get-TcProperty $_ 'Type'), (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Account'), (Get-TcProperty $_ 'Days remaining') })
        }
        elseif ($expiring.Count) {
            Add-TcFinding 'INT-CONNECTORS' $Role -Variant 'expiring' -Values @{ count = $expiring.Count } -Items ($expiring | ForEach-Object { '{0} - {1} - {2} days' -f (Get-TcProperty $_ 'Type'), (Get-TcProperty $_ 'Account'), (Get-TcProperty $_ 'Days remaining') })
        }
    }
}

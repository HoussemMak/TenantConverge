function Get-TcPurviewRule {
    <#
    .SYNOPSIS
    Returns the Purview rules, as script blocks that take the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Labels, retention and data loss prevention
        param($Role)
        if ($Role -eq 'Target') { return }
        $labels = @(Get-TcRuleRow $Role 'sensitivityLabels' | Where-Object { -not (Test-TcRowTrue $_ 'Disabled') })
        $encrypted = @($labels | Where-Object { Test-TcRowTrue $_ 'Encryption' })
        if ($encrypted.Count) { Add-TcFinding 'PUR-ENCRYPTION' $Role -Values @{ count = $encrypted.Count } -Items ($encrypted | ForEach-Object { '{0} ({1})' -f (Get-TcProperty $_ 'Display name'), (Get-TcProperty $_ 'Name') }) }

        if ($labels.Count) {
            $names = @{}
            foreach ($label in Get-TcRuleRow 'Target' 'sensitivityLabels') {
                $names[([string](Get-TcProperty $label 'Display name')).ToLowerInvariant()] = 1
                $names[([string](Get-TcProperty $label 'Name')).ToLowerInvariant()] = 1
            }
            $missing = @($labels | Where-Object { -not $names.ContainsKey(([string](Get-TcProperty $_ 'Display name')).ToLowerInvariant()) -and -not $names.ContainsKey(([string](Get-TcProperty $_ 'Name')).ToLowerInvariant()) })
            if ($missing.Count) { Add-TcFinding 'PUR-LABELS' $Role -Values @{ count = $missing.Count } -Items ($missing | ForEach-Object { '{0} - {1}' -f (Get-TcProperty $_ 'Display name'), (Get-TcProperty $_ 'Scope') }) }
        }

        $retention = @(Get-TcRuleRow $Role 'retentionPolicies' | Where-Object { Test-TcRowTrue $_ 'Enabled' })
        $cases = @(Get-TcRuleRow $Role 'ediscoveryCases' | Where-Object { (Get-TcProperty $_ 'Status') -ne 'Closed' })
        if ($retention.Count -or $cases.Count) {
            $items = @($retention | ForEach-Object { 'Retention - {0} - {1}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Locations') }) + @($cases | ForEach-Object { 'eDiscovery - {0} - {1} hold(s)' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Holds') })
            Add-TcFinding 'PUR-RETENTION' $Role -Values @{ policies = $retention.Count; cases = $cases.Count } -Items $items
        }

        $dlp = @(Get-TcRuleRow $Role 'dlpPolicies' | Where-Object { Test-TcRowTrue $_ 'Enabled' })
        if ($dlp.Count) { Add-TcFinding 'PUR-DLP' $Role -Values @{ count = $dlp.Count } -Items ($dlp | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Mode'), (Get-TcProperty $_ 'Workloads') }) }
    }
}

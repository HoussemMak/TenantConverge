function Get-TcPowerPlatformRule {
    <#
    .SYNOPSIS
    Returns the Power Platform rules, as script blocks that take the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Apps, flows and environments
        param($Role)
        if ($Role -eq 'Target') { return }
        $environments = @(Get-TcRuleRow $Role 'powerEnvironments')
        $apps = @(Get-TcRuleRow $Role 'powerApps')
        $flows = @(Get-TcRuleRow $Role 'powerFlows')
        if ($apps.Count -or $flows.Count -or @($environments | Where-Object { -not (Test-TcRowTrue $_ 'Default') }).Count) {
            $dataverse = @($environments | Where-Object { Test-TcRowTrue $_ 'Dataverse' })
            $items = @($apps | ForEach-Object { 'App - {0} - {1}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Owner') }) + @($flows | ForEach-Object { 'Flow - {0} - {1} - enabled {2}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Owner'), (Get-TcProperty $_ 'Enabled') })
            Add-TcFinding 'POW-RESOURCES' $Role -Severity $(if ($dataverse.Count) { 'Critical' } else { 'High' }) -Values @{ apps = $apps.Count; flows = $flows.Count; environments = $environments.Count; dataverse = $dataverse.Count } -Items $items
        }
    }
}

function Get-TcAzureRule {
    <#
    .SYNOPSIS
    Returns the Azure rules, as script blocks that take the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Subscriptions
        param($Role)
        if ($Role -eq 'Target') { return }
        $subscriptions = @(Get-TcRuleRow $Role 'azureSubscriptions')
        if ($subscriptions.Count) {
            $resources = @(Get-TcRuleRow $Role 'azureResources')
            $desktop = @($resources | Where-Object { (Get-TcProperty $_ 'Type') -match '(?i)DesktopVirtualization' })
            $items = @($subscriptions | ForEach-Object { '{0} - {1} - {2} RBAC assignment(s)' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'State'), (Get-TcProperty $_ 'RBAC assignments') }) + @($resources | ForEach-Object { '{0} - {1} x {2}' -f (Get-TcProperty $_ 'Subscription'), (Get-TcProperty $_ 'Count'), (Get-TcProperty $_ 'Type') })
            Add-TcFinding 'AZR-SUBSCRIPTIONS' $Role -Values @{ count = $subscriptions.Count; types = $resources.Count; desktop = $(if ($desktop.Count) { 'yes' } else { 'no' }) } -Items $items
        }
    }
}

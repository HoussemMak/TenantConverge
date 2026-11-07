function Get-TcMeasure {
    <#
    .SYNOPSIS
    Returns one line per indicator: the value of each tenant, the total of the sources and the target after.

    .DESCRIPTION
    A value is empty when its table was not collected, so a gap is not read as a zero. Sources and after
    stay empty for what cannot add up, like a Secure Score, and when target or sources are missing. A
    value that cannot be read stays empty too: it is reported in errors, and the other measures carry on.
    UnreadSources names the sources with no value: when it is not empty, sources and after are minimums.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    $count = { param($Role, $Table, [scriptblock]$Filter) @(Get-TcRuleRow $Role $Table | Where-Object $Filter).Count }
    $rows = { param($Role, $Table) @(Get-TcRuleRow $Role $Table).Count }
    $sum = { param($Role, $Table, $Column) (@(Get-TcRuleRow $Role $Table | ForEach-Object { [double](Get-TcProperty $_ $Column) }) | Measure-Object -Sum).Sum }

    # Workload, label, table that says whether it was collected, how to read it, whether it adds up.
    $definitions = @(
        @('Entra ID', 'Active member accounts', 'users', { param($R) & $count $R 'users' { (Get-TcProperty $_ 'Type') -eq 'Member' -and (Test-TcRowTrue $_ 'Enabled') } }, $true),
        @('Entra ID', 'Licensed accounts', 'users', { param($R) & $count $R 'users' { (Get-TcRowInteger $_ 'License count') -gt 0 } }, $true),
        @('Entra ID', 'Guest accounts', 'users', { param($R) & $count $R 'users' { (Get-TcProperty $_ 'Type') -eq 'Guest' } }, $false),
        @('Entra ID', 'Groups', 'groups', { param($R) & $rows $R 'groups' }, $true),
        @('Entra ID', 'Active Global Administrators', 'adminRoles', { param($R) & $count $R 'adminRoles' { (Get-TcProperty $_ 'Role') -eq 'Global Administrator' -and (Get-TcProperty $_ 'Assignment') -eq 'Active' } }, $false),
        @('Entra ID', 'Active Conditional Access policies', 'conditionalAccess', { param($R) & $count $R 'conditionalAccess' { (Get-TcProperty $_ 'State') -eq 'enabled' } }, $false),
        @('Entra ID', 'Third-party applications', 'servicePrincipals', { param($R) & $count $R 'servicePrincipals' { (Get-TcProperty $_ 'Origin') -eq 'Third party' } }, $false),
        @('Entra ID', 'Accounts on legacy authentication', 'legacySignIns', { param($R) @(Get-TcRuleRow $R 'legacySignIns' | ForEach-Object { Get-TcProperty $_ 'UPN' } | Sort-Object -Unique).Count }, $false),
        @('Entra ID', 'Risky accounts', 'riskyUsers', { param($R) & $rows $R 'riskyUsers' }, $false),
        @('Exchange Online', 'User mailboxes', 'mailboxes', { param($R) & $count $R 'mailboxes' { (Get-TcProperty $_ 'Type') -eq 'UserMailbox' } }, $true),
        @('Exchange Online', 'Shared mailboxes', 'mailboxes', { param($R) & $count $R 'mailboxes' { (Get-TcProperty $_ 'Type') -eq 'SharedMailbox' } }, $true),
        @('Exchange Online', 'Rooms and equipment', 'mailboxes', { param($R) & $count $R 'mailboxes' { (Get-TcProperty $_ 'Type') -in 'RoomMailbox', 'EquipmentMailbox' } }, $true),
        @('Exchange Online', 'Mailbox volume (GB)', 'mailboxUsage', { param($R) [math]::Round((@(Get-TcRuleRow $R 'mailboxUsage' | ForEach-Object { Get-TcRowNumber $_ 'Size GB' }) | Measure-Object -Sum).Sum) }, $true),
        @('Exchange Online', 'Active archives', 'mailboxes', { param($R) & $count $R 'mailboxes' { Test-TcRowTrue $_ 'Archive' } }, $true),
        @('Exchange Online', 'Distribution lists', 'distributionGroups', { param($R) & $rows $R 'distributionGroups' }, $true),
        @('Exchange Online', 'Mobile devices', 'mobileDevices', { param($R) & $rows $R 'mobileDevices' }, $true),
        @('Exchange Online', 'Public folders', 'publicFolders', { param($R) & $rows $R 'publicFolders' }, $true),
        @('Exchange Online', 'Transport rules', 'transportRules', { param($R) & $rows $R 'transportRules' }, $false),
        @('Domains and DNS', 'Custom domains', 'dnsSummary', { param($R) & $rows $R 'dnsSummary' }, $true),
        @('Domains and DNS', 'Domains behind a gateway', 'dnsSummary', { param($R) & $count $R 'dnsSummary' { (Get-TcProperty $_ 'Inbound mail flow') -eq 'Third-party gateway' } }, $true),
        @('SharePoint and OneDrive', 'Sites', 'sites', { param($R) & $rows $R 'sites' }, $true),
        @('SharePoint and OneDrive', 'Site volume (GB)', 'sites', { param($R) [math]::Round((& $sum $R 'sites' 'Storage MB') / 1024) }, $true),
        @('SharePoint and OneDrive', 'OneDrive accounts', 'oneDrive', { param($R) & $rows $R 'oneDrive' }, $true),
        @('SharePoint and OneDrive', 'OneDrive volume (GB)', 'oneDrive', { param($R) [math]::Round((& $sum $R 'oneDrive' 'Storage MB') / 1024) }, $true),
        @('SharePoint and OneDrive', 'External users', 'sharePointExternalUsers', { param($R) & $rows $R 'sharePointExternalUsers' }, $false),
        @('SharePoint and OneDrive', 'SPFx apps', 'sharePointCustomizations', { param($R) & $count $R 'sharePointCustomizations' { (Get-TcProperty $_ 'Type') -eq 'SPFx app' } }, $false),
        @('Teams', 'Teams', 'teams', { param($R) & $rows $R 'teams' }, $true),
        @('Teams', 'Private channels', 'teamComposition', { param($R) (@(Get-TcRuleRow $R 'teamComposition' | ForEach-Object { [int](Get-TcProperty $_ 'Private channels') }) | Measure-Object -Sum).Sum }, $true),
        @('Teams', 'Shared channels', 'teamComposition', { param($R) (@(Get-TcRuleRow $R 'teamComposition' | ForEach-Object { [int](Get-TcProperty $_ 'Shared channels') }) | Measure-Object -Sum).Sum }, $true),
        @('Teams', 'Custom policies', 'teamsPolicies', { param($R) & $count $R 'teamsPolicies' { Test-TcRowTrue $_ 'Custom' } }, $false),
        @('Teams Phone', 'Phone numbers', 'phoneNumbers', { param($R) & $rows $R 'phoneNumbers' }, $true),
        @('Teams Phone', 'Voice users', 'teamsUsers', { param($R) & $count $R 'teamsUsers' { Test-TcRowTrue $_ 'Enterprise Voice' } }, $true),
        @('Teams Phone', 'Auto attendants', 'autoAttendants', { param($R) & $rows $R 'autoAttendants' }, $true),
        @('Teams Phone', 'Call queues', 'callQueues', { param($R) & $rows $R 'callQueues' }, $true),
        @('Intune', 'Managed devices', 'managedDevices', { param($R) & $rows $R 'managedDevices' }, $true),
        @('Intune', 'Autopilot devices', 'autopilotDevices', { param($R) & $rows $R 'autopilotDevices' }, $true),
        @('Intune', 'Policies', 'intunePolicies', { param($R) & $rows $R 'intunePolicies' }, $false),
        @('Purview', 'Labels with encryption', 'sensitivityLabels', { param($R) & $count $R 'sensitivityLabels' { Test-TcRowTrue $_ 'Encryption' } }, $false),
        @('Purview', 'Retention policies', 'retentionPolicies', { param($R) & $rows $R 'retentionPolicies' }, $false),
        @('Power Platform', 'Apps and flows', 'powerFlows', { param($R) (& $rows $R 'powerApps') + (& $rows $R 'powerFlows') }, $true),
        @('Azure', 'Subscriptions', 'azureSubscriptions', { param($R) & $rows $R 'azureSubscriptions' }, $true),
        @('Other services', 'Secure Score (%)', 'secureScore', { param($R) Get-TcRuleSetting $R 'secureScore' 'Percentage' }, $false)
    )

    $roles = @($script:TcRuleRun['Roles'])
    foreach ($definition in $definitions) {
        $values = [ordered]@{}
        foreach ($role in $roles) {
            try { $values[$role] = if (Test-TcRuleTable $role $definition[2]) { & $definition[3] $role } else { $null } }
            catch {
                $values[$role] = $null
                Add-TcRuleError -Role $role -Workload $definition[0] -ErrorRecord $_
            }
        }
        $sources = @($roles | Where-Object { $_ -ne 'Target' -and $null -ne $values[$_] })
        $unreadSources = @($roles | Where-Object { $_ -ne 'Target' -and $null -eq $values[$_] })
        $total = if ($definition[4] -and $sources.Count) { (@($sources | ForEach-Object { [double]$values[$_] }) | Measure-Object -Sum).Sum } else { $null }
        $target = if ($values.Contains('Target')) { $values['Target'] } else { $null }
        [ordered]@{
            workload = $definition[0]; label = $definition[1]; table = $definition[2]; additive = [bool]$definition[4]; values = $values; sources = $total; unreadSources = $unreadSources
            after = $(if ($null -ne $total -and $null -ne $target) { [double]$target + $total } else { $null })
        }
    }
}

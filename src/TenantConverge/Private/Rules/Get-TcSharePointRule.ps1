function Get-TcSharePointRule {
    <#
    .SYNOPSIS
    Returns the SharePoint and OneDrive rules, as script blocks that take the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Sharing, inactive sites, large sites and what a copy does not take
        param($Role)
        $capability = Get-TcRuleSetting $Role 'sharePointSettings' 'SharingCapability'
        $anyone = @(Get-TcRuleRow $Role 'sites' | Where-Object { (Get-TcProperty $_ 'Sharing') -eq 'ExternalUserAndGuestSharing' })
        if ($capability -eq 'ExternalUserAndGuestSharing' -or $anyone.Count) {
            Add-TcFinding 'SPO-SHARING' $Role -Values @{ capability = $capability; sites = $anyone.Count } -Items ($anyone | ForEach-Object { Get-TcProperty $_ 'Url' })
        }

        $sites = @(Get-TcRuleRow $Role 'sites')
        if (-not $sites.Count) { return }

        $usage = @{}
        foreach ($row in Get-TcRuleRow $Role 'siteUsage') {
            $url = Get-TcProperty $row 'Url'
            if ($url) { $usage[([string]$url).TrimEnd('/').ToLowerInvariant()] = $row }
        }
        $inactive = @($sites | Where-Object {
                $used = $usage[([string](Get-TcProperty $_ 'Url')).TrimEnd('/').ToLowerInvariant()]
                $days = Get-TcProperty $_ 'Days inactive'
                (Get-TcProperty $_ 'Template') -notmatch '^(REDIRECTSITE|SRCHCEN|SPSMSITEHOST|APPCATALOG|TEAMCHANNEL)' -and
                (([double](Get-TcProperty $_ 'Storage MB') -lt 2 -and ($null -eq $days -or [int]$days -ge 30)) -or ($used -and [long](Get-TcProperty $used 'Files') -eq 0) -or ($null -ne $days -and "$days" -ne '' -and [int]$days -ge 365))
            })
        if ($inactive.Count) {
            $volume = (@($inactive | ForEach-Object { [double](Get-TcProperty $_ 'Storage MB') }) | Measure-Object -Sum).Sum / 1024
            Add-TcFinding 'SPO-INACTIVE' $Role -Values @{ count = $inactive.Count; volume = Format-TcNumber $volume 1 } -Items ($inactive | ForEach-Object {
                    $days = Get-TcProperty $_ 'Days inactive'
                    '{0} - {1} MB - inactive {2} days' -f (Get-TcProperty $_ 'Url'), (Get-TcProperty $_ 'Storage MB'), $(if ("$days") { $days } else { '?' })
                })
        }

        $size = [double](Get-TcRuleThreshold 'siteThresholdGb')
        $large = @($sites | Where-Object { [double](Get-TcProperty $_ 'Storage MB') / 1024 -ge $size })
        if ($large.Count -and $Role -ne 'Target') {
            $volume = (@($sites | ForEach-Object { [double](Get-TcProperty $_ 'Storage MB') }) | Measure-Object -Sum).Sum / 1024
            Add-TcFinding 'SPO-LARGE-SITES' $Role -Values @{ count = $large.Count; size = $size; volume = Format-TcNumber $volume 1 } -Items ($large | Sort-Object { - [double](Get-TcProperty $_ 'Storage MB') } | ForEach-Object { '{0} - {1} GB' -f (Get-TcProperty $_ 'Url'), (Format-TcNumber ([double](Get-TcProperty $_ 'Storage MB') / 1024) 1) })
        }

        if ($Role -eq 'Target') { return }

        $classic = @($sites | Where-Object { ((Get-TcProperty $_ 'Template') -match '^(STS#0|STS#1|BLOG#0|PROJECTSITE#0|BDR#0|ENTERWIKI#0|PWA#0|OFFILE#1|CMSPUBLISHING#0|BLANKINTERNET#0|BICenterSite#0|SRCHCENTERLITE#0|WIKI#0|SGS#0|MPS#\d)$' -and -not (Get-TcProperty $_ 'Group')) -or (Test-TcRowTrue $_ 'Custom scripts') })
        if ($classic.Count) {
            Add-TcFinding 'SPO-CLASSIC' $Role -Values @{ count = $classic.Count } -Items ($classic | ForEach-Object { '{0} - {1}{2}' -f (Get-TcProperty $_ 'Url'), (Get-TcProperty $_ 'Template'), $(if (Test-TcRowTrue $_ 'Custom scripts') { ' - custom scripts' } else { '' }) })
        }

        $hubs = @(Get-TcRuleRow $Role 'hubSites')
        if ($hubs.Count) { Add-TcFinding 'SPO-HUBS' $Role -Values @{ count = $hubs.Count } -Items ($hubs | ForEach-Object { '{0} - {1} associated site(s)' -f (Get-TcProperty $_ 'Url'), (Get-TcProperty $_ 'Associated sites') }) }

        $labeled = @($sites | Where-Object { Get-TcProperty $_ 'Label' })
        if ($labeled.Count) { Add-TcFinding 'SPO-LABELS' $Role -Values @{ count = $labeled.Count } -Items ($labeled | ForEach-Object { '{0} - {1}' -f (Get-TcProperty $_ 'Url'), (Get-TcProperty $_ 'Label') }) }
    }

    { # Customizations, term store and OneDrive
        param($Role)
        if ($Role -eq 'Target') { return }
        $customizations = @(Get-TcRuleRow $Role 'sharePointCustomizations' | Where-Object { (Get-TcProperty $_ 'Type') -in 'Site design', 'Site script', 'SPFx app', 'Asset library' })
        if ($customizations.Count) {
            $spfx = @($customizations | Where-Object { (Get-TcProperty $_ 'Type') -eq 'SPFx app' }).Count
            Add-TcFinding 'SPO-CUSTOMIZATIONS' $Role -Severity $(if ($spfx) { 'High' } else { 'Medium' }) -Values @{ count = $customizations.Count; spfx = $spfx } -Items ($customizations | ForEach-Object { '{0} - {1} {2}' -f (Get-TcProperty $_ 'Type'), (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Detail') })
        }

        $terms = @(Get-TcRuleRow $Role 'termStore' | Where-Object { -not (Test-TcRowTrue $_ 'System or collection') })
        if ($terms.Count) { Add-TcFinding 'SPO-TERMS' $Role -Values @{ count = $terms.Count } -Items ($terms | ForEach-Object { '{0} > {1} - {2} term(s)' -f (Get-TcProperty $_ 'Group'), (Get-TcProperty $_ 'Term set'), (Get-TcProperty $_ 'Terms') }) }

        $drives = @(Get-TcRuleRow $Role 'oneDrive')
        if ($drives.Count) {
            $active = @{}
            foreach ($user in Get-TcRuleRow $Role 'users') { if (Test-TcRowTrue $user 'Enabled') { $active[([string](Get-TcProperty $user 'UPN')).ToLowerInvariant()] = 1 } }
            $orphans = @(if ($active.Count) { $drives | Where-Object { $owner = Get-TcProperty $_ 'Owner'; $owner -and -not $active.ContainsKey(([string]$owner).ToLowerInvariant()) } })
            $size = [double](Get-TcRuleThreshold 'oneDriveThresholdGb')
            $large = @($drives | Where-Object { [double](Get-TcProperty $_ 'Storage MB') / 1024 -ge $size })
            $volume = (@($drives | ForEach-Object { [double](Get-TcProperty $_ 'Storage MB') }) | Measure-Object -Sum).Sum / 1024
            $items = @($orphans | ForEach-Object { '{0} - inactive owner {1}' -f (Get-TcProperty $_ 'Url'), (Get-TcProperty $_ 'Owner') }) + @($large | ForEach-Object { '{0} - {1} GB' -f (Get-TcProperty $_ 'Url'), (Format-TcNumber ([double](Get-TcProperty $_ 'Storage MB') / 1024) 1) })
            Add-TcFinding 'SPO-ONEDRIVE' $Role -Severity $(if ($orphans.Count -or $large.Count) { 'Medium' } else { 'Info' }) -Values @{ count = $drives.Count; volume = Format-TcNumber $volume 1; orphans = $orphans.Count; large = $large.Count; size = $size } -Items $items
        }
    }

    { # External users
        param($Role)
        if ($Role -eq 'Target') { return }
        $external = @(Get-TcRuleRow $Role 'sharePointExternalUsers')
        if ($external.Count) { Add-TcFinding 'SPO-EXTERNAL' $Role -Values @{ count = $external.Count } -Items ($external | ForEach-Object { '{0} - {1} - invited by {2}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Email'), (Get-TcProperty $_ 'Invited by') }) }
    }
}

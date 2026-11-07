function Get-TcExchangeRule {
    <#
    .SYNOPSIS
    Returns the Exchange Online rules, as script blocks that take the role of one tenant.
    #>
    [CmdletBinding()]
    [OutputType([scriptblock])]
    param()

    { # Forwarding, archives and holds
        param($Role)
        $mailboxes = @(Get-TcRuleRow $Role 'mailboxes')
        if (-not $mailboxes.Count) { return }
        $forwarded = @($mailboxes | Where-Object { (Get-TcProperty $_ 'SMTP forwarding') -or (Get-TcProperty $_ 'Internal forwarding') })
        if ($forwarded.Count) {
            $external = @($forwarded | Where-Object { Get-TcProperty $_ 'SMTP forwarding' }).Count
            Add-TcFinding 'EXO-FORWARDING' $Role -Values @{ count = $forwarded.Count; external = $external } -Items ($forwarded | ForEach-Object {
                    $to = Get-TcProperty $_ 'SMTP forwarding'
                    if (-not $to) { $to = Get-TcProperty $_ 'Internal forwarding' }
                    '{0} to {1}{2}' -f (Get-TcProperty $_ 'Primary address'), $to, $(if (Test-TcRowTrue $_ 'Deliver and forward') { ' (copy kept)' } else { ' (no copy)' })
                })
        }

        $archived = @($mailboxes | Where-Object { Test-TcRowTrue $_ 'Archive' })
        if ($archived.Count -and $Role -ne 'Target') {
            $sizes = @{}
            foreach ($row in Get-TcRuleRow $Role 'archives') { $sizes[[string](Get-TcProperty $row 'UPN')] = Get-TcProperty $row 'Size GB' }
            $volume = (@($sizes.Values | ForEach-Object { [double]$_ }) | Measure-Object -Sum).Sum
            Add-TcFinding 'EXO-ARCHIVES' $Role -Values @{ count = $archived.Count; volume = Format-TcNumber $volume 1 } -Items ($archived | ForEach-Object {
                    $size = $sizes[[string](Get-TcProperty $_ 'UPN')]
                    '{0}{1}' -f (Get-TcProperty $_ 'UPN'), $(if ($size) { " - $size GB" } else { '' })
                })
        }

        $holds = @($mailboxes | Where-Object { (Test-TcRowTrue $_ 'Litigation hold') -or (Get-TcRowInteger $_ 'Holds') -gt 0 })
        $inactive = @(Get-TcRuleRow $Role 'inactiveMailboxes')
        if (($holds.Count -or $inactive.Count) -and $Role -ne 'Target') {
            $items = @($holds | ForEach-Object { '{0} - litigation {1} - holds {2}' -f (Get-TcProperty $_ 'UPN'), (Get-TcProperty $_ 'Litigation hold'), (Get-TcProperty $_ 'Holds') }) + @($inactive | ForEach-Object { '{0} - inactive mailbox' -f (Get-TcProperty $_ 'Address') })
            Add-TcFinding 'EXO-HOLDS' $Role -Values @{ holds = $holds.Count; inactive = $inactive.Count } -Items $items
        }
    }

    { # Mailbox sizes
        param($Role)
        $usage = @(Get-TcRuleRow $Role 'mailboxUsage')
        if (-not $usage.Count) { return }
        $size = [double](Get-TcRuleThreshold 'mailboxThresholdGb')
        $large = @($usage | Where-Object { (Get-TcRowNumber $_ 'Size GB') -ge $size })
        if ($large.Count) {
            $volume = (@($usage | ForEach-Object { Get-TcRowNumber $_ 'Size GB' }) | Measure-Object -Sum).Sum
            Add-TcFinding 'EXO-LARGE-MAILBOXES' $Role -Values @{ count = $large.Count; size = $size; volume = Format-TcNumber $volume 1 } -Items ($large | Sort-Object { - [double](Get-TcProperty $_ 'Size GB') } | ForEach-Object { '{0} - {1} - {2} GB' -f (Get-TcProperty $_ 'UPN'), (Get-TcProperty $_ 'Type'), (Get-TcProperty $_ 'Size GB') })
        }
        $shared = @($usage | Where-Object { (Get-TcProperty $_ 'Type') -match '(?i)shared' -and (Get-TcRowNumber $_ 'Size GB') -ge 45 })
        if ($shared.Count) { Add-TcFinding 'EXO-SHARED-LICENSED' $Role -Values @{ count = $shared.Count } -Items ($shared | ForEach-Object { '{0} - {1} GB' -f (Get-TcProperty $_ 'UPN'), (Get-TcProperty $_ 'Size GB') }) }
    }

    { # What does not move with the mailboxes
        param($Role)
        if ($Role -eq 'Target') { return }
        $rules = @(Get-TcRuleRow $Role 'transportRules' | Where-Object { (Get-TcProperty $_ 'State') -eq 'Enabled' })
        if ($rules.Count) { Add-TcFinding 'EXO-RULES' $Role -Values @{ count = $rules.Count } -Items ($rules | ForEach-Object { '{0} - priority {1} - {2}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Priority'), (Get-TcProperty $_ 'Description') }) }

        $connectors = @(Get-TcRuleRow $Role 'connectors' | Where-Object { Test-TcRowTrue $_ 'Enabled' })
        if ($connectors.Count) { Add-TcFinding 'EXO-CONNECTORS' $Role -Values @{ count = $connectors.Count } -Items ($connectors | ForEach-Object { '{0} - {1} - {2} - {3}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Direction'), (Get-TcProperty $_ 'Type'), (Get-TcProperty $_ 'Hosts or IPs') }) }

        $journal = @(Get-TcRuleRow $Role 'journalRules')
        if ($journal.Count) { Add-TcFinding 'EXO-JOURNAL' $Role -Values @{ count = $journal.Count } -Items ($journal | ForEach-Object { '{0} to {1}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Journal address') }) }

        $lists = @(Get-TcRuleRow $Role 'distributionGroups')
        $dynamic = @(Get-TcRuleRow $Role 'dynamicGroups')
        $contacts = @(Get-TcRuleRow $Role 'contacts')
        if ($lists.Count -or $dynamic.Count -or $contacts.Count) {
            $items = @($lists | ForEach-Object { '{0} - {1}' -f (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Address') }) + @($dynamic | ForEach-Object { '{0} - dynamic' -f (Get-TcProperty $_ 'Name') })
            Add-TcFinding 'EXO-RECIPIENTS' $Role -Values @{ groups = $lists.Count; dynamic = $dynamic.Count; contacts = $contacts.Count } -Items $items
        }

        $permissions = @(Get-TcRuleRow $Role 'mailboxPermissions')
        if ($permissions.Count) { Add-TcFinding 'EXO-PERMISSIONS' $Role -Values @{ count = $permissions.Count } -Items ($permissions | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'Mailbox'), (Get-TcProperty $_ 'User'), (Get-TcProperty $_ 'Right') }) }
    }

    { # DKIM, audit, hybrid and automatic forwarding
        param($Role)
        $unsigned = @(Get-TcRuleRow $Role 'dkim' | Where-Object { (Get-TcProperty $_ 'Domain') -notmatch '\.onmicrosoft\.com$' -and -not (Test-TcRowTrue $_ 'Enabled') })
        if ($unsigned.Count) { Add-TcFinding 'EXO-DKIM' $Role -Values @{ count = $unsigned.Count } -Items ($unsigned | ForEach-Object { Get-TcProperty $_ 'Domain' }) }

        $audit = Get-TcRuleSetting $Role 'exchangeSettings' 'Unified audit log enabled'
        if ($null -ne $audit -and -not (Test-TcTrue $audit)) { Add-TcFinding 'EXO-AUDIT' $Role }

        $hybrid = @(Get-TcRuleRow $Role 'exchangeHybrid')
        if ($hybrid.Count) { Add-TcFinding 'EXO-HYBRID' $Role -Items ($hybrid | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'Item'), (Get-TcProperty $_ 'Name'), (Get-TcProperty $_ 'Detail') }) }

        $forward = @(Get-TcRuleRow $Role 'remoteDomains' | Where-Object { (Get-TcProperty $_ 'Domain') -eq '*' -and (Test-TcRowTrue $_ 'Auto-forward') })
        if ($forward.Count) { Add-TcFinding 'EXO-AUTO-FORWARD' $Role }
    }

    { # Protocols, mobile devices, inbox rules, rooms and public folders
        param($Role)
        $protocols = @(Get-TcRuleRow $Role 'mailboxProtocols' | Where-Object { (Test-TcRowTrue $_ 'POP') -or (Test-TcRowTrue $_ 'IMAP') -or (Get-TcProperty $_ 'Authenticated SMTP') -eq $true })
        if ($protocols.Count) {
            $values = @{
                count = $protocols.Count
                pop   = @($protocols | Where-Object { Test-TcRowTrue $_ 'POP' }).Count
                imap  = @($protocols | Where-Object { Test-TcRowTrue $_ 'IMAP' }).Count
                smtp  = @($protocols | Where-Object { (Get-TcProperty $_ 'Authenticated SMTP') -eq $true }).Count
            }
            Add-TcFinding 'EXO-PROTOCOLS' $Role -Values $values -Items ($protocols | ForEach-Object {
                    '{0} -{1}{2}{3}' -f (Get-TcProperty $_ 'Mailbox'), $(if (Test-TcRowTrue $_ 'POP') { ' POP' }), $(if (Test-TcRowTrue $_ 'IMAP') { ' IMAP' }), $(if ((Get-TcProperty $_ 'Authenticated SMTP') -eq $true) { ' SMTP' })
                })
        }

        $mobile = @(Get-TcRuleRow $Role 'mobileDevices')
        if ($mobile.Count -and $Role -ne 'Target') {
            $systems = @($mobile | Group-Object { ([string](Get-TcProperty $_ 'System')) -replace '\s.*$', '' } | Sort-Object Count -Descending | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Count }) -join ', '
            Add-TcFinding 'EXO-MOBILE' $Role -Values @{ count = $mobile.Count; systems = $systems } -Items ($mobile | ForEach-Object { '{0} - {1} - {2}' -f (Get-TcProperty $_ 'User'), (Get-TcProperty $_ 'Model'), (Get-TcProperty $_ 'Client') })
        }

        $inbox = @(Get-TcRuleRow $Role 'inboxRules')
        $external = @($inbox | Where-Object { Test-TcRowTrue $_ 'External' })
        if ($external.Count) { Add-TcFinding 'EXO-INBOX-RULES' $Role -Values @{ count = $external.Count; total = $inbox.Count } -Items ($external | ForEach-Object { "{0} - '{1}' to {2}" -f (Get-TcProperty $_ 'Mailbox'), (Get-TcProperty $_ 'Rule'), (Get-TcProperty $_ 'To') }) }

        $rooms = @(Get-TcRuleRow $Role 'roomsAndEquipment')
        if ($rooms.Count -and $Role -ne 'Target') { Add-TcFinding 'EXO-ROOMS' $Role -Values @{ count = $rooms.Count } -Items ($rooms | ForEach-Object { '{0} - {1} - {2} days - {3} delegate(s)' -f (Get-TcProperty $_ 'Resource'), (Get-TcProperty $_ 'Processing'), (Get-TcProperty $_ 'Booking window (days)'), (Get-TcProperty $_ 'Delegates') }) }

        $folders = @(Get-TcRuleRow $Role 'publicFolders')
        if ($folders.Count) {
            $mail = @($folders | Where-Object { Test-TcRowTrue $_ 'Email' }).Count
            Add-TcFinding 'EXO-PUBLIC-FOLDERS' $Role -Values @{ count = $folders.Count; mail = $mail } -Items ($folders | ForEach-Object { '{0}{1}' -f (Get-TcProperty $_ 'Path'), $(if (Test-TcRowTrue $_ 'Email') { ' - mail' }) })
        }
    }
}

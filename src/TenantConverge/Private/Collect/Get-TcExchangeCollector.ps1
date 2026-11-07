function Get-TcExchangeCollector {
    <#
    .SYNOPSIS
    Lists the Exchange Online collectors, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @(
        @{
            Id       = 'EXO-01'
            Workload = 'Exchange Online'
            Title    = 'Organization, domains, hybrid and sharing'
            Service  = 'Exo'
            Collect  = {
                Add-TcTable 'exchangeSettings' @(ConvertTo-TcSettingRow (Get-OrganizationConfig -ErrorAction Stop) 'Organization')
                Invoke-TcCollectorPart 'Unified audit log' { Add-TcTable 'exchangeSettings' -Append @([ordered]@{ 'Setting' = 'Unified audit log enabled'; 'Value' = [bool](Get-TcProperty (Get-AdminAuditLogConfig -ErrorAction Stop) 'UnifiedAuditLogIngestionEnabled') }) }
                Invoke-TcCollectorPart 'Transport' { Add-TcTable 'exchangeSettings' -Append @(ConvertTo-TcSettingRow (Get-TransportConfig -ErrorAction Stop) 'Transport') }
                Add-TcTable 'acceptedDomains' @(foreach ($d in Get-AcceptedDomain -ErrorAction Stop) {
                        [ordered]@{
                            'Domain'  = [string](Get-TcProperty $d 'DomainName')
                            'Type'    = [string](Get-TcProperty $d 'DomainType')
                            'Default' = [bool](Get-TcProperty $d 'Default')
                        }
                    })
                Invoke-TcCollectorPart 'Remote domains' { Add-TcTable 'remoteDomains' @(foreach ($d in Get-RemoteDomain -ErrorAction Stop) {
                            [ordered]@{
                                'Name'              = (Get-TcProperty $d 'Name')
                                'Domain'            = [string](Get-TcProperty $d 'DomainName')
                                'Auto-forward'      = [bool](Get-TcProperty $d 'AutoForwardEnabled')
                                'Automatic replies' = [string](Get-TcProperty $d 'AllowedOOFType')
                            }
                        }) }
                Invoke-TcCollectorPart 'Exchange hybrid' {
                    $h = @(foreach ($o in @(Get-OnPremisesOrganization -ErrorAction Stop)) {
                            [ordered]@{
                                'Item'   = 'On-premises organization (hybrid)'
                                'Name'   = (Get-TcProperty $o 'Name')
                                'Detail' = (Format-TcValue (Get-TcProperty $o 'HybridDomains'))
                            }
                        })
                    $h += @(foreach ($o in @(Get-IntraOrganizationConnector -ErrorAction Stop)) {
                            [ordered]@{
                                'Item'   = 'Intra-organization connector'
                                'Name'   = (Get-TcProperty $o 'Name')
                                'Detail' = ('{0} - enabled {1}' -f (Format-TcValue (Get-TcProperty $o 'TargetAddressDomains')), (Get-TcProperty $o 'Enabled'))
                            }
                        })
                    Add-TcTable 'exchangeHybrid' $h
                }
                Invoke-TcCollectorPart 'Organization relationships (free/busy)' { Add-TcTable 'organizationRelationships' @(foreach ($r in Get-OrganizationRelationship -ErrorAction Stop) {
                            [ordered]@{
                                'Name'      = (Get-TcProperty $r 'Name')
                                'Domains'   = (Format-TcValue (Get-TcProperty $r 'DomainNames'))
                                'Free/busy' = [bool](Get-TcProperty $r 'FreeBusyAccessEnabled')
                                'Level'     = [string](Get-TcProperty $r 'FreeBusyAccessLevel')
                                'Enabled'   = [bool](Get-TcProperty $r 'Enabled')
                            }
                        }) }
                Invoke-TcCollectorPart 'Sharing policies' { Add-TcTable 'sharingPolicies' @(foreach ($r in Get-SharingPolicy -ErrorAction Stop) {
                            [ordered]@{
                                'Name'    = (Get-TcProperty $r 'Name')
                                'Domains' = (Format-TcValue (Get-TcProperty $r 'Domains'))
                                'Default' = [bool](Get-TcProperty $r 'Default')
                                'Enabled' = [bool](Get-TcProperty $r 'Enabled')
                            }
                        }) }
                Invoke-TcCollectorPart 'Email address policies' { Add-TcTable 'emailAddressPolicies' @(foreach ($r in Get-EmailAddressPolicy -ErrorAction Stop) {
                            [ordered]@{
                                'Name'      = (Get-TcProperty $r 'Name')
                                'Priority'  = [string](Get-TcProperty $r 'Priority')
                                'Templates' = (Format-TcValue (Get-TcProperty $r 'EnabledEmailAddressTemplates'))
                                'Filter'    = (Get-TcProperty $r 'RecipientFilter')
                            }
                        }) }
                Invoke-TcCollectorPart 'MRM retention policies' { Add-TcTable 'mrmPolicies' @(foreach ($r in Get-RetentionPolicy -ErrorAction Stop) {
                            [ordered]@{
                                'Name'    = (Get-TcProperty $r 'Name')
                                'Default' = [bool](Get-TcProperty $r 'IsDefault')
                                'Tags'    = (Format-TcValue (Get-TcProperty $r 'RetentionPolicyTagLinks'))
                            }
                        }) }
            }
        }

        @{
            Id       = 'EXO-02'
            Workload = 'Exchange Online'
            Title    = 'Mailboxes, archives, holds and forwarding'
            Service  = 'Exo'
            Collect  = {
                $properties = 'ArchiveStatus', 'LitigationHoldEnabled', 'InPlaceHolds', 'RetentionHoldEnabled', 'ForwardingSmtpAddress', 'ForwardingAddress', 'DeliverToMailboxAndForward',
                'HiddenFromAddressListsEnabled', 'WhenCreated', 'ProhibitSendReceiveQuota', 'RetentionPolicy', 'EmailAddresses', 'ExternalDirectoryObjectId', 'GrantSendOnBehalfTo', 'Alias'
                $b = @(Get-EXOMailbox -ResultSize Unlimited -Properties $properties -ErrorAction Stop | Where-Object { [string](Get-TcProperty $_ 'RecipientTypeDetails') -ne 'DiscoveryMailbox' })
                Add-TcTable 'mailboxes' @(foreach ($x in $b) {
                        $smtp = @((Get-TcProperty $x 'EmailAddresses') | Where-Object { $_ -match '^smtp:' } | ForEach-Object { $_ -replace '^smtp:', '' })
                        [ordered]@{
                            'UPN'                 = (Get-TcProperty $x 'UserPrincipalName')
                            'Name'                = (Get-TcProperty $x 'DisplayName')
                            'Type'                = [string](Get-TcProperty $x 'RecipientTypeDetails')
                            'Primary address'     = [string](Get-TcProperty $x 'PrimarySmtpAddress')
                            'Alias'               = (Get-TcProperty $x 'Alias')
                            'Address count'       = $smtp.Count
                            'Addresses'           = ($smtp -join '; ')
                            'Archive'             = ([string](Get-TcProperty $x 'ArchiveStatus') -eq 'Active')
                            'Litigation hold'     = [bool](Get-TcProperty $x 'LitigationHoldEnabled')
                            'Holds'               = @((Get-TcProperty $x 'InPlaceHolds')).Count
                            'SMTP forwarding'     = [string](Get-TcProperty $x 'ForwardingSmtpAddress')
                            'Internal forwarding' = [string](Get-TcProperty $x 'ForwardingAddress')
                            'Deliver and forward' = [bool](Get-TcProperty $x 'DeliverToMailboxAndForward')
                            'Hidden'              = [bool](Get-TcProperty $x 'HiddenFromAddressListsEnabled')
                            'Created'             = (Format-TcValue (Get-TcProperty $x 'WhenCreated'))
                            'Quota'               = [string](Get-TcProperty $x 'ProhibitSendReceiveQuota')
                            'MRM policy'          = [string](Get-TcProperty $x 'RetentionPolicy')
                            'ObjectId'            = (Get-TcProperty $x 'ExternalDirectoryObjectId')
                        }
                    })
                Add-TcTable 'mailboxPermissions' @(foreach ($x in $b | Where-Object { @((Get-TcProperty $_ 'GrantSendOnBehalfTo')).Count }) {
                        foreach ($d in @((Get-TcProperty $x 'GrantSendOnBehalfTo'))) {
                            [ordered]@{
                                'Mailbox' = [string](Get-TcProperty $x 'PrimarySmtpAddress')
                                'User'    = [string]$d
                                'Right'   = 'SendOnBehalf'
                            }
                        }
                    })
                Invoke-TcCollectorPart 'Inactive mailboxes' { Add-TcTable 'inactiveMailboxes' @(foreach ($x in @(Get-EXOMailbox -InactiveMailboxOnly -ResultSize Unlimited -ErrorAction Stop)) {
                            [ordered]@{
                                'Name'    = (Get-TcProperty $x 'DisplayName')
                                'Address' = [string](Get-TcProperty $x 'PrimarySmtpAddress')
                                'Type'    = [string](Get-TcProperty $x 'RecipientTypeDetails')
                            }
                        }) }
                Invoke-TcCollectorPart 'Mailbox usage report (Graph)' {
                    Connect-TcTenant -Role $script:TcCurrentTenant['role']
                    Add-TcTable 'mailboxUsage' @(foreach ($r in Get-TcUsageReport 'getMailboxUsageDetail') {
                            [ordered]@{
                                'UPN'           = (Get-TcProperty $r 'User Principal Name')
                                'Name'          = (Get-TcProperty $r 'Display Name')
                                'Type'          = (Get-TcProperty $r 'Recipient Type')
                                'Deleted'       = (Get-TcProperty $r 'Is Deleted')
                                'Last activity' = (Get-TcProperty $r 'Last Activity Date')
                                'Items'         = [long]('0' + (Get-TcProperty $r 'Item Count'))
                                'Size GB'       = (ConvertTo-TcGigabyte (Get-TcProperty $r 'Storage Used (Byte)'))
                                'Quota GB'      = (ConvertTo-TcGigabyte (Get-TcProperty $r 'Prohibit Send/Receive Quota (Byte)'))
                                'Archive'       = (Get-TcProperty $r 'Has Archive')
                            }
                        })
                }
                if ($script:TcDepth -eq 'Complete') {
                    Invoke-TcCollectorPart 'Archive sizes' {
                        Add-TcTable 'archives' @(foreach ($x in $b | Where-Object { [string](Get-TcProperty $_ 'ArchiveStatus') -eq 'Active' }) {
                                $s = Get-EXOMailboxStatistics -Identity ([string](Get-TcProperty $x 'PrimarySmtpAddress')) -Archive -ErrorAction Stop
                                [ordered]@{
                                    'UPN'     = (Get-TcProperty $x 'UserPrincipalName')
                                    'Size GB' = (ConvertTo-TcGigabyte (Get-TcByteSize (Get-TcProperty $s 'TotalItemSize')))
                                    'Items'   = [long](Get-TcProperty $s 'ItemCount')
                                }
                            })
                    }
                }
            }
        }

        @{
            Id       = 'EXO-03'
            Workload = 'Exchange Online'
            Title    = 'Groups, lists, contacts and mail users'
            Service  = 'Exo'
            Collect  = {
                Add-TcTable 'distributionGroups' @(foreach ($g in Get-DistributionGroup -ResultSize Unlimited -ErrorAction Stop) {
                        $memberCount = $null
                        if ($script:TcDepth -eq 'Complete') { try { $memberCount = @(Get-DistributionGroupMember -Identity ([string](Get-TcProperty $g 'PrimarySmtpAddress')) -ResultSize Unlimited -ErrorAction Stop).Count } catch { Add-TcCollectorWarning "Members of $(Get-TcProperty $g 'PrimarySmtpAddress')" $_ } }
                        [ordered]@{
                            'Name'                     = (Get-TcProperty $g 'DisplayName')
                            'Address'                  = [string](Get-TcProperty $g 'PrimarySmtpAddress')
                            'Alias'                    = (Get-TcProperty $g 'Alias')
                            'Type'                     = [string](Get-TcProperty $g 'RecipientTypeDetails')
                            'External senders allowed' = -not [bool](Get-TcProperty $g 'RequireSenderAuthenticationEnabled')
                            'Managers'                 = (Format-TcValue (Get-TcProperty $g 'ManagedBy'))
                            'Hidden'                   = [bool](Get-TcProperty $g 'HiddenFromAddressListsEnabled')
                            'Members'                  = $memberCount
                        }
                    })
                Invoke-TcCollectorPart 'Dynamic groups' { Add-TcTable 'dynamicGroups' @(foreach ($g in Get-DynamicDistributionGroup -ResultSize Unlimited -ErrorAction Stop) {
                            [ordered]@{
                                'Name'    = (Get-TcProperty $g 'DisplayName')
                                'Address' = [string](Get-TcProperty $g 'PrimarySmtpAddress')
                                'Filter'  = (Get-TcProperty $g 'RecipientFilter')
                            }
                        }) }
                Invoke-TcCollectorPart 'Microsoft 365 groups' {
                    Add-TcTable 'microsoft365Groups' @(foreach ($g in Get-UnifiedGroup -ResultSize Unlimited -ErrorAction Stop) {
                            [ordered]@{
                                'Name'    = (Get-TcProperty $g 'DisplayName')
                                'Address' = [string](Get-TcProperty $g 'PrimarySmtpAddress')
                                'Alias'   = (Get-TcProperty $g 'Alias')
                                'Access'  = [string](Get-TcProperty $g 'AccessType')
                                'Team'    = (@((Get-TcProperty $g 'ResourceProvisioningOptions')) -contains 'Team')
                                'Members' = (Get-TcProperty $g 'GroupMemberCount')
                                'Guests'  = (Get-TcProperty $g 'GroupExternalMemberCount')
                                'Site'    = (Get-TcProperty $g 'SharePointSiteUrl')
                                'Created' = (Format-TcValue (Get-TcProperty $g 'WhenCreated'))
                            }
                        })
                }
                Invoke-TcCollectorPart 'Contacts and mail users' {
                    $c = @(foreach ($x in Get-MailContact -ResultSize Unlimited -ErrorAction Stop) {
                            [ordered]@{
                                'Name'             = (Get-TcProperty $x 'DisplayName')
                                'External address' = [string](Get-TcProperty $x 'ExternalEmailAddress')
                                'Type'             = 'Contact'
                            }
                        })
                    $c += @(foreach ($x in Get-MailUser -ResultSize Unlimited -ErrorAction Stop) {
                            [ordered]@{
                                'Name'             = (Get-TcProperty $x 'DisplayName')
                                'External address' = [string](Get-TcProperty $x 'ExternalEmailAddress')
                                'Type'             = 'Mail user'
                            }
                        })
                    Add-TcTable 'contacts' $c
                }
            }
        }

        @{
            Id       = 'EXO-04'
            Workload = 'Exchange Online'
            Title    = 'Mailbox permissions (full access, send as)'
            Service  = 'Exo'
            Requires = @('mailboxes')
            Collect  = {
                $types = if ($script:TcDepth -eq 'Complete') { @('UserMailbox', 'SharedMailbox', 'RoomMailbox', 'EquipmentMailbox') } else { @('SharedMailbox', 'RoomMailbox', 'EquipmentMailbox') }
                $targets = @(Get-TcTable 'mailboxes' | Where-Object { (Get-TcProperty $_ 'Type') -in $types })
                $n = 0
                Add-TcTable 'mailboxPermissions' -Append @(foreach ($x in $targets) {
                        $n++
                        if ($n % 50 -eq 0) { Write-TcMessage -Message ('Permissions: {0}/{1}' -f $n, $targets.Count) }
                        $permissions = $null
                        for ($attempt = 1; $attempt -le 3 -and $null -eq $permissions; $attempt++) {
                            try { $permissions = @(Get-EXOMailboxPermission -Identity (Get-TcProperty $x 'Primary address') -ErrorAction Stop) }
                            catch {
                                if ($attempt -lt 3 -and (Get-TcErrorText $_) -match 'timed out|Timeout|429|503|504|temporar|throttl') { Start-Sleep -Seconds (20 * $attempt); continue }
                                Add-TcCollectorWarning "Permissions of $(Get-TcProperty $x 'Primary address')" $_; break
                            }
                        }
                        foreach ($p in @($permissions | Where-Object { $_ -and -not (Get-TcProperty $_ 'IsInherited') -and -not (Get-TcProperty $_ 'Deny') -and [string](Get-TcProperty $_ 'User') -notmatch 'NT AUTHORITY|S-1-5-' })) {
                            [ordered]@{
                                'Mailbox' = (Get-TcProperty $x 'Primary address')
                                'User'    = [string](Get-TcProperty $p 'User')
                                'Right'   = (@((Get-TcProperty $p 'AccessRights')) -join ',')
                            }
                        }
                    })
                Invoke-TcCollectorPart 'Send as' {
                    Add-TcTable 'mailboxPermissions' -Append @(foreach ($p in @(Get-EXORecipientPermission -ResultSize Unlimited -ErrorAction Stop | Where-Object { [string](Get-TcProperty $_ 'Trustee') -notmatch 'NT AUTHORITY|S-1-5-' -and -not (Get-TcProperty $_ 'IsInherited') })) {
                            [ordered]@{
                                'Mailbox' = [string](Get-TcProperty $p 'Identity')
                                'User'    = [string](Get-TcProperty $p 'Trustee')
                                'Right'   = (@((Get-TcProperty $p 'AccessRights')) -join ',')
                            }
                        })
                }
            }
        }

        @{
            Id       = 'EXO-05'
            Workload = 'Exchange Online'
            Title    = 'Mail flow: rules, connectors, journaling, DKIM'
            Service  = 'Exo'
            Collect  = {
                Add-TcTable 'transportRules' @(foreach ($r in Get-TransportRule -ResultSize Unlimited -ErrorAction Stop) {
                        [ordered]@{
                            'Name'        = (Get-TcProperty $r 'Name')
                            'State'       = [string](Get-TcProperty $r 'State')
                            'Priority'    = (Get-TcProperty $r 'Priority')
                            'Mode'        = [string](Get-TcProperty $r 'Mode')
                            'Description' = (Limit-TcText ([string](Get-TcProperty $r 'Description')) 400)
                        }
                    })
                Invoke-TcCollectorPart 'Connectors' {
                    $c = @(foreach ($x in Get-InboundConnector -ErrorAction Stop) {
                            [ordered]@{
                                'Name'         = (Get-TcProperty $x 'Name')
                                'Direction'    = 'Inbound'
                                'Enabled'      = [bool](Get-TcProperty $x 'Enabled')
                                'Type'         = [string](Get-TcProperty $x 'ConnectorType')
                                'Domains'      = (Format-TcValue (Get-TcProperty $x 'SenderDomains'))
                                'Hosts or IPs' = (Format-TcValue (Get-TcProperty $x 'SenderIPAddresses'))
                                'TLS'          = ('{0} {1}' -f (Get-TcProperty $x 'RequireTls'), (Get-TcProperty $x 'TlsSenderCertificateName')).Trim()
                            }
                        })
                    $c += @(foreach ($x in Get-OutboundConnector -ErrorAction Stop) {
                            [ordered]@{
                                'Name'         = (Get-TcProperty $x 'Name')
                                'Direction'    = 'Outbound'
                                'Enabled'      = [bool](Get-TcProperty $x 'Enabled')
                                'Type'         = [string](Get-TcProperty $x 'ConnectorType')
                                'Domains'      = (Format-TcValue (Get-TcProperty $x 'RecipientDomains'))
                                'Hosts or IPs' = (Format-TcValue (Get-TcProperty $x 'SmartHosts'))
                                'TLS'          = [string](Get-TcProperty $x 'TlsSettings')
                            }
                        })
                    Add-TcTable 'connectors' $c
                }
                Invoke-TcCollectorPart 'Journal rules' { Add-TcTable 'journalRules' @(foreach ($r in Get-JournalRule -ErrorAction Stop) {
                            [ordered]@{
                                'Name'            = (Get-TcProperty $r 'Name')
                                'Recipient'       = [string](Get-TcProperty $r 'Recipient')
                                'Journal address' = [string](Get-TcProperty $r 'JournalEmailAddress')
                                'Scope'           = [string](Get-TcProperty $r 'Scope')
                                'Enabled'         = [bool](Get-TcProperty $r 'Enabled')
                            }
                        }) }
                Invoke-TcCollectorPart 'DKIM' { Add-TcTable 'dkim' @(foreach ($d in Get-DkimSigningConfig -ErrorAction Stop) {
                            [ordered]@{
                                'Domain'     = [string](Get-TcProperty $d 'Domain')
                                'Enabled'    = [bool](Get-TcProperty $d 'Enabled')
                                'Selector 1' = (Get-TcProperty $d 'Selector1CNAME')
                                'Selector 2' = (Get-TcProperty $d 'Selector2CNAME')
                            }
                        }) }
            }
        }

        @{
            Id       = 'EXO-06'
            Workload = 'Exchange Online'
            Title    = 'Protection: anti-spam, anti-phishing, links and attachments'
            Service  = 'Exo'
            Collect  = {
                $types = [ordered]@{
                    'HostedContentFilterPolicy'      = 'Inbound anti-spam'
                    'HostedOutboundSpamFilterPolicy' = 'Outbound anti-spam'
                    'MalwareFilterPolicy'            = 'Anti-malware'
                    'AntiPhishPolicy'                = 'Anti-phishing'
                    'SafeLinksPolicy'                = 'Safe Links (Defender)'
                    'SafeAttachmentPolicy'           = 'Safe Attachments (Defender)'
                    'HostedConnectionFilterPolicy'   = 'Connection filtering'
                    'QuarantinePolicy'               = 'Quarantine'
                }
                foreach ($t in $types.Keys) {
                    if (-not (Get-Command "Get-$t" -ErrorAction SilentlyContinue)) { continue }
                    Invoke-TcCollectorPart $types[$t] {
                        Add-TcTable 'protectionPolicies' -Append @(foreach ($p in @(& "Get-$t" -ErrorAction Stop)) {
                                [ordered]@{
                                    'Type'    = $types[$t]
                                    'Name'    = (Get-TcProperty $p 'Name')
                                    'Default' = [bool](Get-TcSafeProperty $p 'IsDefault' $false)
                                    'Enabled' = (Get-TcSafeProperty $p 'Enabled' (Get-TcSafeProperty $p 'Enable'))
                                }
                            })
                    }
                }
                if (-not @(Get-TcTable 'protectionPolicies').Count) { Add-TcTable 'protectionPolicies' @() }
            }
        }

        @{
            Id       = 'EXO-07'
            Workload = 'Exchange Online'
            Title    = 'Mailbox protocols and mobile devices'
            Service  = 'Exo'
            Collect  = {
                Add-TcTable 'mailboxProtocols' @(foreach ($c in @(Get-EXOCasMailbox -ResultSize Unlimited -Properties PopEnabled, ImapEnabled, ActiveSyncEnabled, EwsEnabled, MAPIEnabled, OWAEnabled, SmtpClientAuthenticationDisabled -ErrorAction Stop)) {
                        [ordered]@{
                            'Mailbox'            = [string](Get-TcProperty $c 'PrimarySmtpAddress')
                            'POP'                = [bool](Get-TcProperty $c 'PopEnabled')
                            'IMAP'               = [bool](Get-TcProperty $c 'ImapEnabled')
                            'ActiveSync'         = [bool](Get-TcProperty $c 'ActiveSyncEnabled')
                            'EWS'                = [bool](Get-TcProperty $c 'EwsEnabled')
                            'MAPI'               = [bool](Get-TcProperty $c 'MAPIEnabled')
                            'OWA'                = [bool](Get-TcProperty $c 'OWAEnabled')
                            'Authenticated SMTP' = $(if ($null -eq (Get-TcProperty $c 'SmtpClientAuthenticationDisabled')) { 'Per organization' } else { -not [bool](Get-TcProperty $c 'SmtpClientAuthenticationDisabled') })
                        }
                    })
                Invoke-TcCollectorPart 'Mobile devices' {
                    Add-TcTable 'mobileDevices' @(foreach ($d in @(Get-MobileDevice -ResultSize Unlimited -ErrorAction Stop)) {
                            [ordered]@{
                                'User'       = (Get-TcProperty $d 'UserDisplayName')
                                'Model'      = (Get-TcProperty $d 'DeviceModel')
                                'System'     = (Get-TcProperty $d 'DeviceOS')
                                'Type'       = (Get-TcProperty $d 'DeviceType')
                                'Client'     = [string](Get-TcProperty $d 'ClientType')
                                'Access'     = [string](Get-TcProperty $d 'DeviceAccessState')
                                'First sync' = (Format-TcValue (Get-TcProperty $d 'FirstSyncTime'))
                            }
                        })
                }
            }
        }

        @{
            Id       = 'EXO-08'
            Workload = 'Exchange Online'
            Title    = 'Inbox rules that forward or redirect'
            Service  = 'Exo'
            Depth    = 'Complete'
            Requires = @('mailboxes', 'acceptedDomains')
            Collect  = {
                $internalDomains = @(Get-TcTable 'acceptedDomains' | ForEach-Object { ([string](Get-TcProperty $_ 'Domain')).ToLowerInvariant() })
                $mailboxes = @(Limit-TcCollectorRow 'user mailboxes' @(Get-TcTable 'mailboxes' | Where-Object { (Get-TcProperty $_ 'Type') -eq 'UserMailbox' }) ([int](Get-TcCollectionSetting 'maxInboxRuleMailboxes')))
                $n = 0
                Add-TcTable 'inboxRules' @(foreach ($b in $mailboxes) {
                        $n++
                        if ($n % 50 -eq 0) { Write-TcMessage -Message ('Inbox rules: {0}/{1}' -f $n, $mailboxes.Count) }
                        try {
                            foreach ($r in @(Get-InboxRule -Mailbox (Get-TcProperty $b 'Primary address') -ErrorAction Stop -WarningAction SilentlyContinue | Where-Object { (Get-TcProperty $_ 'ForwardTo') -or (Get-TcProperty $_ 'ForwardAsAttachmentTo') -or (Get-TcProperty $_ 'RedirectTo') })) {
                                $destinations = @(@((Get-TcProperty $r 'ForwardTo')) + @((Get-TcProperty $r 'ForwardAsAttachmentTo')) + @((Get-TcProperty $r 'RedirectTo')) | ForEach-Object { if ([string]$_ -match '"?([^"\[\]\s]+@[^"\]\s]+)') { $Matches[1] } else { [string]$_ } })
                                [ordered]@{
                                    'Mailbox'  = (Get-TcProperty $b 'Primary address')
                                    'Rule'     = (Get-TcProperty $r 'Name')
                                    'Enabled'  = [bool](Get-TcProperty $r 'Enabled')
                                    'To'       = ($destinations -join '; ')
                                    'External' = [bool](@($destinations | Where-Object { (Get-TcAddressDomain $_) -and (Get-TcAddressDomain $_) -notin $internalDomains }).Count)
                                }
                            }
                        }
                        catch { Add-TcCollectorWarning "Inbox rules of $(Get-TcProperty $b 'Primary address')" $_ }
                    })
            }
        }

        @{
            Id       = 'EXO-09'
            Workload = 'Exchange Online'
            Title    = 'Rooms and equipment: booking rules'
            Service  = 'Exo'
            Requires = @('mailboxes')
            Collect  = {
                Add-TcTable 'roomsAndEquipment' @(foreach ($b in @(Get-TcTable 'mailboxes' | Where-Object { (Get-TcProperty $_ 'Type') -in 'RoomMailbox', 'EquipmentMailbox' })) {
                        try {
                            $c = Get-CalendarProcessing -Identity (Get-TcProperty $b 'Primary address') -ErrorAction Stop
                            [ordered]@{
                                'Resource'              = (Get-TcProperty $b 'Name')
                                'Address'               = (Get-TcProperty $b 'Primary address')
                                'Type'                  = (Get-TcProperty $b 'Type')
                                'Processing'            = [string](Get-TcProperty $c 'AutomateProcessing')
                                'Open to all'           = [bool](Get-TcProperty $c 'AllBookInPolicy')
                                'Booking window (days)' = (Get-TcProperty $c 'BookingWindowInDays')
                                'Max duration (min)'    = (Get-TcProperty $c 'MaximumDurationInMinutes')
                                'Delegates'             = @((Get-TcProperty $c 'ResourceDelegates')).Count
                                'External accepted'     = [bool](Get-TcProperty $c 'ProcessExternalMeetingMessages')
                            }
                        }
                        catch { Add-TcCollectorWarning "Booking settings of $(Get-TcProperty $b 'Primary address')" $_ }
                    })
            }
        }

        @{
            Id       = 'EXO-10'
            Workload = 'Exchange Online'
            Title    = 'Public folders'
            Service  = 'Exo'
            Collect  = {
                $publicFolderMailboxes = @(Get-Mailbox -PublicFolder -ResultSize Unlimited -ErrorAction Stop)
                if (-not $publicFolderMailboxes.Count) { Add-TcCollectorNote 'No public folder mailbox: nothing to migrate.'; Add-TcTable 'publicFolders' @(); return }
                $maxFolders = [int](Get-TcCollectionSetting 'maxPublicFolders')
                $folders = @(Get-PublicFolder -Recurse -ResultSize $maxFolders -ErrorAction Stop)
                if ($folders.Count -ge $maxFolders) { Add-TcCollectorLimit ('only the first {0} public folders were read, there may be more.' -f $maxFolders) }
                Add-TcTable 'publicFolders' @(foreach ($d in @($folders | Where-Object { (Get-TcProperty $_ 'Identity') -ne '\' })) {
                        [ordered]@{
                            'Path'            = [string](Get-TcProperty $d 'Identity')
                            'Name'            = (Get-TcProperty $d 'Name')
                            'Email'           = [bool](Get-TcProperty $d 'MailEnabled')
                            'Content mailbox' = [string](Get-TcProperty $d 'ContentMailboxName')
                            'Subfolders'      = [bool](Get-TcProperty $d 'HasSubfolders')
                        }
                    })
            }
        }

    )
}
function Get-TcTeamsPhoneCollector {
    <#
    .SYNOPSIS
    Lists the Teams Phone collectors, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @(
        @{
            Id       = 'TEL-01'
            Workload = 'Teams Phone'
            Title    = 'Phone numbers'
            Service  = 'Teams'
            Collect  = {
                $assignees = @{}
                foreach ($u in Get-TcTable 'teamsUsers') { if ((Get-TcProperty $u 'ObjectId')) { $assignees[[string](Get-TcProperty $u 'ObjectId')] = (Get-TcProperty $u 'UPN') } }
                $numbers = [System.Collections.Generic.List[object]]::new(); $skip = 0
                do { $page = @(Get-CsPhoneNumberAssignment -Top 1000 -Skip $skip -ErrorAction Stop); foreach ($x in $page) { $numbers.Add($x) }; $skip += 1000 } while ($page.Count -eq 1000)
                Add-TcTable 'phoneNumbers' @(foreach ($x in $numbers) {
                        $t = [string](Get-TcProperty $x 'AssignedPstnTargetId')
                        [ordered]@{
                            'Number'            = (Get-TcProperty $x 'TelephoneNumber')
                            'Type'              = [string](Get-TcProperty $x 'NumberType')
                            'Activation'        = [string](Get-TcProperty $x 'ActivationState')
                            'Assignment'        = [string](Get-TcProperty $x 'PstnAssignmentStatus')
                            'Assigned to'       = $(if ($assignees[$t]) { $assignees[$t] } else { $t })
                            'Capabilities'      = (Format-TcValue (Get-TcProperty $x 'Capability'))
                            'City'              = (Get-TcProperty $x 'City')
                            'Country'           = (Get-TcProperty $x 'IsoCountryCode')
                            'Partner'           = (Get-TcProperty $x 'PstnPartnerName')
                            'Porting'           = [string](Get-TcProperty $x 'PortInOrderStatus')
                            'Source'            = [string](Get-TcSafeProperty $x 'NumberSource')
                            'Emergency address' = [string](Get-TcSafeProperty $x 'CivicAddressId')
                        }
                    })
            }
        }

        @{
            Id       = 'TEL-02'
            Workload = 'Teams Phone'
            Title    = 'Resource accounts, auto attendants and call queues'
            Service  = 'Teams'
            Collect  = {
                $usage = @{ 'ce933385-9390-45d1-9512-c8d228074e07' = 'Auto attendant'; '11cd3e2e-fccb-42ad-ad00-878b93575e07' = 'Call queue' }
                Add-TcTable 'resourceAccounts' @(foreach ($r in @(Get-CsOnlineApplicationInstance -ErrorAction Stop)) {
                        [ordered]@{
                            'UPN'      = (Get-TcProperty $r 'UserPrincipalName')
                            'Name'     = (Get-TcProperty $r 'DisplayName')
                            'Number'   = (([string](Get-TcProperty $r 'PhoneNumber')) -replace '^tel:', '')
                            'Usage'    = $(if ($usage[[string](Get-TcProperty $r 'ApplicationId')]) { $usage[[string](Get-TcProperty $r 'ApplicationId')] } else { [string](Get-TcProperty $r 'ApplicationId') })
                            'ObjectId' = [string](Get-TcProperty $r 'ObjectId')
                        }
                    })
                $resourceNames = @{}; foreach ($r in Get-TcTable 'resourceAccounts') { $resourceNames[[string](Get-TcProperty $r 'ObjectId')] = (Get-TcProperty $r 'Name') }
                Invoke-TcCollectorPart 'Auto attendants' {
                    $autoAttendants = [System.Collections.Generic.List[object]]::new(); $skip = 0
                    do { $page = @(Get-CsAutoAttendant -First 100 -Skip $skip -ErrorAction Stop); foreach ($x in $page) { $autoAttendants.Add($x) }; $skip += 100 } while ($page.Count -eq 100)
                    Add-TcTable 'autoAttendants' @(foreach ($a in $autoAttendants) {
                            [ordered]@{
                                'Name'              = (Get-TcProperty $a 'Name')
                                'Language'          = (Get-TcProperty $a 'LanguageId')
                                'Time zone'         = (Get-TcProperty $a 'TimeZoneId')
                                'Resource accounts' = ((@((Get-TcProperty $a 'ApplicationInstances')) | ForEach-Object { if ($resourceNames[[string]$_]) { $resourceNames[[string]$_] } else { [string]$_ } }) -join ', ')
                                'Call flows'        = @((Get-TcProperty $a 'CallFlows')).Count
                                'Schedules'         = @((Get-TcProperty $a 'Schedules')).Count
                                'Operator'          = [string](Get-TcSafeProperty (Get-TcProperty $a 'Operator') 'Type')
                                'Directory lookup'  = [string](Get-TcSafeProperty $a 'DirectoryLookupScope')
                                'Identity'          = [string](Get-TcProperty $a 'Identity')
                            }
                        })
                }
                Invoke-TcCollectorPart 'Call queues' {
                    $callQueues = [System.Collections.Generic.List[object]]::new(); $skip = 0
                    do { $page = @(Get-CsCallQueue -First 100 -Skip $skip -ErrorAction Stop -WarningAction SilentlyContinue); foreach ($x in $page) { $callQueues.Add($x) }; $skip += 100 } while ($page.Count -eq 100)
                    Add-TcTable 'callQueues' @(foreach ($queue in $callQueues) {
                            [ordered]@{
                                'Name'              = (Get-TcProperty $queue 'Name')
                                'Routing'           = [string](Get-TcProperty $queue 'RoutingMethod')
                                'Agents'            = @((Get-TcProperty $queue 'Agents')).Count
                                'Lists'             = @((Get-TcProperty $queue 'DistributionLists')).Count
                                'Teams channel'     = [bool](Get-TcSafeProperty $queue 'ChannelId')
                                'Overflow'          = ('{0} after {1}' -f (Get-TcProperty $queue 'OverflowAction'), (Get-TcProperty $queue 'OverflowThreshold'))
                                'Expiration'        = ('{0} after {1} s' -f (Get-TcProperty $queue 'TimeoutAction'), (Get-TcProperty $queue 'TimeoutThreshold'))
                                'Resource accounts' = ((@((Get-TcProperty $queue 'ApplicationInstances')) | ForEach-Object { if ($resourceNames[[string]$_]) { $resourceNames[[string]$_] } else { [string]$_ } }) -join ', ')
                                'Presence'          = [bool](Get-TcProperty $queue 'PresenceBasedRouting')
                            }
                        })
                }
            }
        }

        @{
            Id       = 'TEL-03'
            Workload = 'Teams Phone'
            Title    = 'Direct Routing, voice routes and dial plans'
            Service  = 'Teams'
            Collect  = {
                Add-TcTable 'pstnGateways' @(foreach ($g in @(Get-CsOnlinePSTNGateway -ErrorAction Stop)) {
                        [ordered]@{
                            'FQDN'         = (Get-TcProperty $g 'FQDN')
                            'Port'         = (Get-TcProperty $g 'SipSignalingPort')
                            'Enabled'      = [bool](Get-TcProperty $g 'Enabled')
                            'Max sessions' = (Get-TcProperty $g 'MaxConcurrentSessions')
                        }
                    })
                Invoke-TcCollectorPart 'Voice routes' { Add-TcTable 'voiceRoutes' @(foreach ($r in @(Get-CsOnlineVoiceRoute -ErrorAction Stop)) {
                            [ordered]@{
                                'Name'     = [string](Get-TcProperty $r 'Identity')
                                'Pattern'  = (Get-TcProperty $r 'NumberPattern')
                                'Gateways' = (Format-TcValue (Get-TcProperty $r 'OnlinePstnGatewayList'))
                                'Usages'   = (Format-TcValue (Get-TcProperty $r 'OnlinePstnUsages'))
                                'Priority' = (Get-TcProperty $r 'Priority')
                            }
                        }) }
                Invoke-TcCollectorPart 'Voice routing policies' { Add-TcTable 'voiceRoutingPolicies' @(foreach ($r in @(Get-CsOnlineVoiceRoutingPolicy -ErrorAction Stop)) { [ordered]@{ 'Name' = [string](Get-TcProperty $r 'Identity'); 'PSTN usages' = (Format-TcValue (Get-TcProperty $r 'OnlinePstnUsages')) } }) }
                Invoke-TcCollectorPart 'Dial plans' { Add-TcTable 'dialPlans' @(foreach ($r in @(Get-CsTenantDialPlan -ErrorAction Stop)) {
                            [ordered]@{
                                'Name'        = [string](Get-TcProperty $r 'Identity')
                                'Rules'       = @((Get-TcProperty $r 'NormalizationRules')).Count
                                'Description' = (Get-TcProperty $r 'Description')
                            }
                        }) }
                Invoke-TcCollectorPart 'Translation rules' { if (Get-Command Get-CsTeamsTranslationRule -ErrorAction SilentlyContinue) {
                        Add-TcTable 'translationRules' @(foreach ($r in @(Get-CsTeamsTranslationRule -ErrorAction Stop)) {
                                [ordered]@{
                                    'Name'        = [string](Get-TcProperty $r 'Identity')
                                    'Pattern'     = (Get-TcProperty $r 'Pattern')
                                    'Translation' = (Get-TcProperty $r 'Translation')
                                }
                            })
                    } }
            }
        }

        @{
            Id       = 'TEL-04'
            Workload = 'Teams Phone'
            Title    = 'Emergency addresses and locations, conference bridges'
            Service  = 'Teams'
            Collect  = {
                $locations = @{}
                Invoke-TcCollectorPart 'Emergency locations' { foreach ($l in @(Get-CsOnlineLisLocation -ErrorAction Stop)) { $k = [string](Get-TcProperty $l 'CivicAddressId'); $locations[$k] = 1 + [int]$locations[$k] } }
                Add-TcTable 'emergencyAddresses' @(foreach ($a in @(Get-CsOnlineLisCivicAddress -ErrorAction Stop)) {
                        [ordered]@{
                            'Description'       = (Get-TcProperty $a 'Description')
                            'Company'           = (Get-TcProperty $a 'CompanyName')
                            'Address'           = ('{0} {1} {2}' -f (Get-TcProperty $a 'HouseNumber'), (Get-TcProperty $a 'StreetName'), (Get-TcProperty $a 'StreetSuffix')).Trim()
                            'City'              = (Get-TcProperty $a 'City')
                            'State or province' = (Get-TcProperty $a 'StateOrProvince')
                            'Postal code'       = (Get-TcProperty $a 'PostalCode')
                            'Country'           = (Get-TcProperty $a 'CountryOrRegion')
                            'Validation'        = [string](Get-TcSafeProperty $a 'ValidationStatus')
                            'Locations'         = [int]$locations[[string](Get-TcProperty $a 'CivicAddressId')]
                        }
                    })
                Invoke-TcCollectorPart 'Audio conferencing bridges' {
                    if (Get-Command Get-CsOnlineDialInConferencingBridge -ErrorAction SilentlyContinue) {
                        Add-TcTable 'conferenceBridges' @(foreach ($b in @(Get-CsOnlineDialinConferencingBridge -ErrorAction Stop)) {
                                [ordered]@{
                                    'Name'           = (Get-TcProperty $b 'Name')
                                    'Default number' = [string](Get-TcProperty $b 'DefaultServiceNumber')
                                    'Numbers'        = (Format-TcValue (Get-TcProperty $b 'ServiceNumbers'))
                                }
                            })
                    }
                }
            }
        }

        @{
            Id       = 'TEL-05'
            Workload = 'Teams Phone'
            Title    = 'Calling settings of voice users (forwarding, delegation)'
            Service  = 'Teams'
            Depth    = 'Complete'
            Requires = @('teamsUsers')
            Collect  = {
                $voiceUsers = @(Limit-TcCollectorRow 'voice users' @(Get-TcTable 'teamsUsers' | Where-Object { (Get-TcProperty $_ 'Enterprise Voice') }) ([int](Get-TcCollectionSetting 'maxCallingUsers')))
                if (-not (Get-Command Get-CsUserCallingSettings -ErrorAction SilentlyContinue)) { throw 'Get-CsUserCallingSettings is not recognized as a name of a cmdlet (MicrosoftTeams 4.0 or later is required)' }
                Add-TcTable 'userCallingSettings' @(foreach ($u in $voiceUsers) {
                        try {
                            $s = Get-CsUserCallingSettings -Identity (Get-TcProperty $u 'UPN') -ErrorAction Stop
                            [ordered]@{
                                'UPN'        = (Get-TcProperty $u 'UPN')
                                'Forwarding' = $(if ((Get-TcProperty $s 'IsForwardingEnabled')) { '{0} to {1}' -f (Get-TcProperty $s 'ForwardingType'), (Get-TcProperty $s 'ForwardingTarget') })
                                'Unanswered' = $(if ((Get-TcProperty $s 'IsUnansweredEnabled')) { '{0} after {1}' -f (Get-TcProperty $s 'UnansweredTarget'), (Get-TcProperty $s 'UnansweredDelay') })
                                'Delegates'  = (Format-TcValue (@((Get-TcProperty $s 'Delegates')) | ForEach-Object { (Get-TcProperty $_ 'Id') }))
                                'Call group' = (Format-TcValue (Get-TcProperty $s 'CallGroupTargets'))
                            }
                        }
                        catch { Add-TcCollectorWarning "Calling settings of $(Get-TcProperty $u 'UPN')" $_ }
                    })
            }
        }

        @{
            Id       = 'TEL-06'
            Workload = 'Teams Phone'
            Title    = 'Schedules, holidays and network topology (emergency, routing)'
            Service  = 'Teams'
            Collect  = {
                Invoke-TcCollectorPart 'Schedules and holidays' {
                    Add-TcTable 'phoneSchedules' @(foreach ($s in @(Get-CsOnlineSchedule -ErrorAction Stop)) {
                            [ordered]@{
                                'Name'    = (Get-TcProperty $s 'Name')
                                'Type'    = $(if ((Get-TcProperty $s 'FixedSchedule')) { 'Fixed dates (holidays)' } else { 'Weekly (business hours)' })
                                'Used by' = @((Get-TcProperty $s 'AssociatedConfigurationIds')).Count
                            }
                        })
                }
                Invoke-TcCollectorPart 'Network topology' {
                    $r = @(foreach ($x in @(Get-CsTenantNetworkSite -ErrorAction Stop)) {
                            [ordered]@{
                                'Type'   = 'Network site'
                                'Name'   = [string](Get-TcProperty $x 'NetworkSiteID')
                                'Detail' = ('{0} - emergency {1}' -f (Get-TcProperty $x 'Description'), (Get-TcProperty $x 'EmergencyCallRoutingPolicy')).Trim(' -')
                            }
                        })
                    $r += @(foreach ($x in @(Get-CsTenantNetworkSubnet -ErrorAction Stop)) {
                            [ordered]@{
                                'Type'   = 'Subnet'
                                'Name'   = ('{0}/{1}' -f (Get-TcProperty $x 'SubnetID'), (Get-TcProperty $x 'MaskBits'))
                                'Detail' = [string](Get-TcProperty $x 'NetworkSiteID')
                            }
                        })
                    $r += @(foreach ($x in @(Get-CsTenantTrustedIPAddress -ErrorAction Stop)) {
                            [ordered]@{
                                'Type'   = 'Trusted IP address'
                                'Name'   = ('{0}/{1}' -f (Get-TcProperty $x 'IPAddress'), (Get-TcProperty $x 'MaskBits'))
                                'Detail' = (Get-TcProperty $x 'Description')
                            }
                        })
                    Add-TcTable 'phoneNetworkTopology' $r
                }
            }
        }

    )
}
function Get-TcTeamsCollector {
    <#
    .SYNOPSIS
    Lists the Teams collectors, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @(
        @{
            Id       = 'TMS-01'
            Workload = 'Teams'
            Title    = 'Teams'
            Service  = 'Teams'
            Collect  = {
                Add-TcTable 'teams' @(foreach ($t in @(Get-Team -ErrorAction Stop)) {
                        [ordered]@{
                            'Id'          = (Get-TcProperty $t 'GroupId')
                            'Name'        = (Get-TcProperty $t 'DisplayName')
                            'Visibility'  = [string](Get-TcProperty $t 'Visibility')
                            'Archived'    = [bool](Get-TcProperty $t 'Archived')
                            'Alias'       = (Get-TcProperty $t 'MailNickName')
                            'Description' = (Limit-TcText ([string](Get-TcProperty $t 'Description')) 300)
                        }
                    })
                Invoke-TcCollectorPart 'Team activity (Microsoft 365 report)' {
                    Connect-TcTenant -Role $script:TcCurrentTenant['role']
                    Add-TcTable 'teamActivity' @(foreach ($r in Get-TcUsageReport 'getTeamsTeamActivityDetail' | Where-Object { (Get-TcProperty $_ 'Is Deleted') -ne 'True' }) {
                            [ordered]@{
                                'Team'             = (Get-TcProperty $r 'Team Name')
                                'Type'             = (Get-TcProperty $r 'Team Type')
                                'Last activity'    = (Get-TcProperty $r 'Last Activity Date')
                                'Active users'     = [int]('0' + (Get-TcProperty $r 'Active Users'))
                                'Guests'           = [int]('0' + (Get-TcProperty $r 'Guests'))
                                'Channel messages' = [int]('0' + (Get-TcProperty $r 'Channel Messages'))
                                'Meetings'         = [int]('0' + (Get-TcProperty $r 'Meetings Organized'))
                            }
                        })
                }
            }
        }

        @{
            Id       = 'TMS-02'
            Workload = 'Teams'
            Title    = 'Channels (standard, private, shared) and members per team'
            Service  = 'Teams'
            Depth    = 'Complete'
            Requires = @('teams')
            Collect  = {
                $teamRows = @(Limit-TcCollectorRow 'teams' @(Get-TcTable 'teams') ([int](Get-TcCollectionSetting 'maxTeamDetails')))
                $n = 0; $channels = [System.Collections.Generic.List[object]]::new()
                Add-TcTable 'teamComposition' @(foreach ($t in $teamRows) {
                        $n++
                        if ($n % 25 -eq 0) { Write-TcMessage -Message ('Teams detailed: {0}/{1}' -f $n, $teamRows.Count) }
                        try {
                            $teamChannels = @(Get-TeamChannel -GroupId (Get-TcProperty $t 'Id') -ErrorAction Stop)
                            foreach ($c in $teamChannels) {
                                $channels.Add([ordered]@{
                                        'Team'    = (Get-TcProperty $t 'Name')
                                        'Channel' = (Get-TcProperty $c 'DisplayName')
                                        'Type'    = [string](Get-TcProperty $c 'MembershipType')
                                    })
                            }
                            $m = @(Get-TeamUser -GroupId (Get-TcProperty $t 'Id') -ErrorAction Stop)
                            [ordered]@{
                                'Team'              = (Get-TcProperty $t 'Name')
                                'Owners'            = @($m | Where-Object Role -EQ 'owner').Count
                                'Members'           = @($m | Where-Object Role -EQ 'member').Count
                                'Guests'            = @($m | Where-Object Role -EQ 'guest').Count
                                'Standard channels' = @($teamChannels | Where-Object { [string](Get-TcProperty $_ 'MembershipType') -eq 'Standard' }).Count
                                'Private channels'  = @($teamChannels | Where-Object { [string](Get-TcProperty $_ 'MembershipType') -eq 'Private' }).Count
                                'Shared channels'   = @($teamChannels | Where-Object { [string](Get-TcProperty $_ 'MembershipType') -eq 'Shared' }).Count
                            }
                        }
                        catch { Add-TcCollectorWarning "Team $(Get-TcProperty $t 'Name')" $_ }
                    })
                Add-TcTable 'channels' $channels
            }
        }

        @{
            Id       = 'TMS-03'
            Workload = 'Teams'
            Title    = 'Organization settings and Teams policies'
            Service  = 'Teams'
            Collect  = {
                $settingKinds = [ordered]@{
                    'CsTenantFederationConfiguration'          = 'External access'
                    'CsTeamsClientConfiguration'               = 'Teams client'
                    'CsTeamsGuestMeetingConfiguration'         = 'Guests - meetings'
                    'CsTeamsGuestMessagingConfiguration'       = 'Guests - messaging'
                    'CsTeamsGuestCallingConfiguration'         = 'Guests - calling'
                    'CsTeamsMeetingConfiguration'              = 'Meetings'
                    'CsOnlineDialInConferencingTenantSettings' = 'Audio conferencing'
                    'CsTeamsAcsFederationConfiguration'        = 'ACS federation'
                }
                foreach ($k in $settingKinds.Keys) {
                    if (-not (Get-Command "Get-$k" -ErrorAction SilentlyContinue)) { continue }
                    Invoke-TcCollectorPart $settingKinds[$k] { Add-TcTable 'teamsSettings' -Append @(ConvertTo-TcSettingRow (& "Get-$k" -ErrorAction Stop) $settingKinds[$k]) }
                }
                $types = 'TeamsMeetingPolicy', 'TeamsMessagingPolicy', 'TeamsAppSetupPolicy', 'TeamsAppPermissionPolicy', 'TeamsChannelsPolicy', 'TeamsUpdateManagementPolicy', 'TeamsEventsPolicy',
                'TeamsFeedbackPolicy', 'TeamsFilesPolicy', 'TeamsMobilityPolicy', 'TeamsMeetingTemplatePermissionPolicy', 'TeamsEnhancedEncryptionPolicy', 'ExternalAccessPolicy',
                'TeamsCallingPolicy', 'TeamsCallParkPolicy', 'TeamsEmergencyCallingPolicy', 'TeamsEmergencyCallRoutingPolicy', 'TeamsIPPhonePolicy', 'TeamsVoiceApplicationsPolicy',
                'TeamsComplianceRecordingPolicy', 'TeamsSharedCallingRoutingPolicy', 'TeamsShiftsPolicy', 'TeamsVdiPolicy', 'OnlineVoicemailPolicy', 'CallingLineIdentity'
                $preset = '^(Global|Tag:(Default|AllOn|AllOff|RestrictedAnonymousAccess|RestrictedAnonymousNoRecording|RestrictedAnonymousNoRecordingIgnoringSearch|Kiosk|Firstline.*|FirstLine.*|Education_.*|PrivateMeetingAllowed|AllowCalling.*|DisallowCalling|PreventForwardingtoPhone|PreventTollBypass|Restricted.*|OrgWideDefault|.*_Default))$'
                foreach ($t in $types) {
                    if (-not (Get-Command "Get-Cs$t" -ErrorAction SilentlyContinue)) { continue }
                    Invoke-TcCollectorPart "$t policies" {
                        foreach ($p in @(& "Get-Cs$t" -ErrorAction Stop)) {
                            $id = [string](Get-TcProperty $p 'Identity')
                            Add-TcTable 'teamsPolicies' -Append @([ordered]@{
                                    'Type'        = $t
                                    'Identity'    = $id
                                    'Custom'      = ($id -notmatch $preset)
                                    'Description' = (Limit-TcText ([string](Get-TcSafeProperty $p 'Description')) 200)
                                })
                            if ($id -eq 'Global') { Add-TcTable 'teamsSettings' -Append @(ConvertTo-TcSettingRow $p "Global policy $t") }
                        }
                    }
                }
                Invoke-TcCollectorPart 'Organization Teams apps (Graph)' {
                    Connect-TcTenant -Role $script:TcCurrentTenant['role']
                    Add-TcTable 'teamsApps' @(foreach ($a in Get-TcGraphList "v1.0/appCatalogs/teamsApps?`$filter=distributionMethod eq 'organization'&`$expand=appDefinitions") {
                            $d = @((Get-TcProperty $a 'appDefinitions')) | Select-Object -Last 1
                            [ordered]@{
                                'Name'         = (Get-TcProperty $a 'displayName')
                                'Version'      = (Get-TcProperty $d 'version')
                                'Publishing'   = (Get-TcProperty $d 'publishingState')
                                'Distribution' = (Get-TcProperty $a 'distributionMethod')
                            }
                        })
                }
                Invoke-TcCollectorPart 'Teams devices (phones, rooms)' {
                    Connect-TcTenant -Role $script:TcCurrentTenant['role']
                    Add-TcTable 'teamsDevices' @(foreach ($d in Get-TcGraphList 'beta/teamwork/devices') {
                            [ordered]@{
                                'Type'     = (Get-TcProperty $d 'deviceType')
                                'Model'    = ('{0} {1}' -f (Get-TcProperty (Get-TcProperty $d 'hardwareDetail') 'manufacturer'), (Get-TcProperty (Get-TcProperty $d 'hardwareDetail') 'model')).Trim()
                                'User'     = (Get-TcProperty (Get-TcProperty $d 'currentUser') 'displayName')
                                'State'    = (Get-TcProperty $d 'healthStatus')
                                'Activity' = (Get-TcProperty $d 'activityState')
                            }
                        })
                }
            }
        }

        @{
            Id       = 'TMS-04'
            Workload = 'Teams'
            Title    = 'Teams users, voice and assigned policies'
            Service  = 'Teams'
            Collect  = {
                $p = @{ ErrorAction = 'Stop' }
                if ((Get-TcProperty (Get-Command Get-CsOnlineUser) 'Parameters').ContainsKey('ResultSize')) { $p['ResultSize'] = 100000 }
                $properties = 'TeamsMeetingPolicy', 'TeamsMessagingPolicy', 'TeamsAppSetupPolicy', 'TeamsAppPermissionPolicy', 'TeamsChannelsPolicy', 'TeamsUpdateManagementPolicy', 'TeamsEventsPolicy',
                'ExternalAccessPolicy', 'TeamsCallingPolicy', 'TeamsCallParkPolicy', 'TeamsEmergencyCallingPolicy', 'TeamsEmergencyCallRoutingPolicy', 'TeamsIPPhonePolicy',
                'TeamsVoiceApplicationsPolicy', 'TeamsComplianceRecordingPolicy', 'OnlineVoicemailPolicy', 'CallingLineIdentity', 'OnlineVoiceRoutingPolicy', 'TenantDialPlan', 'TeamsMobilityPolicy'
                Add-TcTable 'teamsUsers' @(foreach ($u in @(Get-CsOnlineUser @p)) {
                        $policies = @(foreach ($k in $properties) { $v = [string](Get-TcSafeProperty $u $k); if ($v) { '{0}={1}' -f $k, $v } })
                        [ordered]@{
                            'UPN'              = (Get-TcProperty $u 'UserPrincipalName')
                            'Name'             = (Get-TcProperty $u 'DisplayName')
                            'Enabled'          = [bool](Get-TcSafeProperty $u 'AccountEnabled' $true)
                            'Enterprise Voice' = [bool](Get-TcSafeProperty $u 'EnterpriseVoiceEnabled' $false)
                            'Number'           = (([string](Get-TcSafeProperty $u 'LineUri')) -replace '^tel:', '')
                            'Features'         = (Format-TcValue (Get-TcSafeProperty $u 'FeatureTypes'))
                            'Teams mode'       = [string](Get-TcSafeProperty $u 'TeamsUpgradeEffectiveMode')
                            'Policies'         = ($policies -join '; ')
                            'ObjectId'         = [string](Get-TcSafeProperty $u 'Identity')
                        }
                    })
            }
        }

    )
}
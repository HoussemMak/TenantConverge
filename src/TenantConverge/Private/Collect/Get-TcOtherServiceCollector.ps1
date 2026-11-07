function Get-TcOtherServiceCollector {
    <#
    .SYNOPSIS
    Lists the other services collectors, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @(
        @{
            Id       = 'AUT-01'
            Workload = 'Other services'
            Title    = 'Microsoft 365 activity per user and report privacy'
            Service  = 'Graph'
            Collect  = {
                Invoke-TcCollectorPart 'Report concealment setting' { $s = Get-TcGraphObject 'v1.0/admin/reportSettings'; Add-TcTable 'reportSettings' @([ordered]@{ 'Setting' = 'Names concealed in reports'; 'Value' = [bool](Get-TcProperty $s 'displayConcealedNames') }) }
                Add-TcTable 'userActivity' @(foreach ($r in Get-TcUsageReport 'getOffice365ActiveUserDetail' | Where-Object { (Get-TcProperty $_ 'Is Deleted') -ne 'True' }) {
                        [ordered]@{
                            'UPN'         = (Get-TcProperty $r 'User Principal Name')
                            'Name'        = (Get-TcProperty $r 'Display Name')
                            'Exchange'    = (Get-TcProperty $r 'Exchange Last Activity Date')
                            'OneDrive'    = (Get-TcProperty $r 'OneDrive Last Activity Date')
                            'SharePoint'  = (Get-TcProperty $r 'SharePoint Last Activity Date')
                            'Teams'       = (Get-TcProperty $r 'Teams Last Activity Date')
                            'Viva Engage' = (Get-TcProperty $r 'Yammer Last Activity Date')
                            'Products'    = (Get-TcProperty $r 'Assigned Products')
                        }
                    })
            }
        }

        @{
            Id       = 'AUT-02'
            Workload = 'Other services'
            Title    = 'Microsoft Secure Score and recommended actions'
            Service  = 'Graph'
            Collect  = {
                $s = @((Get-TcProperty (Get-TcGraphObject "v1.0/security/secureScores?`$top=1") 'value')) | Select-Object -First 1
                if (-not $s) { Add-TcCollectorNote 'No Secure Score has been calculated for this tenant.'; return }
                Add-TcTable 'secureScore' @([ordered]@{ 'Setting' = 'Current score'; 'Value' = [math]::Round([double](Get-TcProperty $s 'currentScore'), 1) }, [ordered]@{ 'Setting' = 'Maximum score'; 'Value' = [math]::Round([double](Get-TcProperty $s 'maxScore'), 1) },
                    [ordered]@{ 'Setting' = 'Percentage'; 'Value' = [math]::Round(100 * [double](Get-TcProperty $s 'currentScore') / [math]::Max(1, [double](Get-TcProperty $s 'maxScore'))) }, [ordered]@{ 'Setting' = 'Date'; 'Value' = (Format-TcValue (Get-TcProperty $s 'createdDateTime')) })
                $profiles = @{}
                try { foreach ($p in Get-TcGraphList "v1.0/security/secureScoreControlProfiles?`$top=200") { $profiles[[string](Get-TcProperty $p 'id')] = $p } } catch { Add-TcCollectorWarning 'Control profiles' $_ }
                Add-TcTable 'secureScoreActions' @(@(foreach ($c in @((Get-TcProperty $s 'controlScores'))) {
                            $p = $profiles[[string](Get-TcProperty $c 'controlName')]; $max = [double](Get-TcProperty $p 'maxScore' 0)
                            if ($max -and [double](Get-TcProperty $c 'score') -ge $max) { continue }
                            [ordered]@{
                                'Control'       = $(if ($p) { (Get-TcProperty $p 'title') } else { (Get-TcProperty $c 'controlName') })
                                'Category'      = (Get-TcProperty $c 'controlCategory')
                                'Score'         = [math]::Round([double](Get-TcProperty $c 'score'), 1)
                                'Maximum'       = $max
                                'Possible gain' = [math]::Round($max - [double](Get-TcProperty $c 'score'), 1)
                                'Cost'          = (Get-TcProperty $p 'implementationCost')
                                'User impact'   = (Get-TcProperty $p 'userImpact')
                                'Service'       = (Get-TcProperty $p 'service')
                            }
                        }) | Sort-Object { - (Get-TcProperty $_ 'Possible gain') })
            }
        }

        @{
            Id       = 'AUT-03'
            Workload = 'Other services'
            Title    = 'Planner (plans of Microsoft 365 groups)'
            Service  = 'Graph'
            Depth    = 'Complete'
            Requires = @('groups')
            Collect  = {
                $groups = @(Limit-TcCollectorRow 'Microsoft 365 groups' @(Get-TcTable 'groups' | Where-Object Type -EQ 'Microsoft 365') ([int](Get-TcCollectionSetting 'maxPlannerGroups')))
                $denied = 0
                Add-TcTable 'plannerPlans' @(foreach ($g in $groups) {
                        try {
                            foreach ($p in Get-TcGraphList "v1.0/groups/$(Get-TcProperty $g 'Id')/planner/plans") {
                                [ordered]@{
                                    'Group'   = (Get-TcProperty $g 'Name')
                                    'Plan'    = (Get-TcProperty $p 'title')
                                    'Created' = (Format-TcValue (Get-TcProperty $p 'createdDateTime'))
                                }
                            }
                        }
                        catch { $denied++; if ($denied -le 3) { Add-TcCollectorWarning "Plans of $(Get-TcProperty $g 'Name')" $_ } }
                    })
                if ($denied) { Add-TcCollectorNote ('Plans of {0} of {1} groups could not be read with delegated access (the account must be a member): application mode is recommended for a full Planner inventory.' -f $denied, $groups.Count) }
            }
        }

        @{
            Id       = 'AUT-04'
            Workload = 'Other services'
            Title    = 'Bookings and Viva Engage'
            Service  = 'Graph'
            Collect  = {
                Invoke-TcCollectorPart 'Bookings' { Add-TcTable 'bookings' @(foreach ($b in Get-TcGraphList 'v1.0/solutions/bookingBusinesses') {
                            [ordered]@{
                                'Name'      = (Get-TcProperty $b 'displayName')
                                'Email'     = (Get-TcProperty $b 'email')
                                'Type'      = (Get-TcProperty $b 'businessType')
                                'Published' = (Get-TcProperty $b 'isPublished')
                            }
                        }) }
                Invoke-TcCollectorPart 'Viva Engage communities' {
                    $c = try { Get-TcGraphList 'v1.0/employeeExperience/communities' } catch { Get-TcGraphList 'beta/employeeExperience/communities' }
                    Add-TcTable 'vivaCommunities' @(foreach ($x in $c) {
                            [ordered]@{
                                'Name'        = (Get-TcProperty $x 'displayName')
                                'Privacy'     = (Get-TcProperty $x 'privacy')
                                'Description' = (Limit-TcText ([string](Get-TcProperty $x 'description')) 200)
                            }
                        })
                }
            }
        }

        @{
            Id       = 'AUT-05'
            Workload = 'Other services'
            Title    = 'Products with no inventory API (checklist)'
            Service  = 'None'
            Collect  = {
                Add-TcTable 'manualProducts' @(
                    [ordered]@{
                        'Product'   = 'Microsoft Forms'
                        'Inventory' = 'No administration API'
                        'Migration' = 'Not covered by the usual copy tools'
                        'To do'     = 'Have owners list their active forms, export the responses to Excel, then recreate or duplicate the forms after cutover'
                    },
                    [ordered]@{
                        'Product'   = 'Loop'
                        'Inventory' = 'Workspaces stored in SharePoint Embedded'
                        'Migration' = 'Not supported by most tools'
                        'To do'     = 'Find the Loop workspaces in use, export the important pages, and confirm with the chosen tool'
                    },
                    [ordered]@{
                        'Product'   = 'Whiteboard'
                        'Inventory' = '.whiteboard files in OneDrive'
                        'Migration' = 'Follows OneDrive (files)'
                        'To do'     = 'Check that a sample opens after the copy'
                    },
                    [ordered]@{
                        'Product'   = 'To Do'
                        'Inventory' = 'Per user, in the mailbox'
                        'Migration' = 'Follows the mailbox if the tool copies tasks'
                        'To do'     = 'Confirm with the chosen tool, otherwise each user exports their own'
                    },
                    [ordered]@{
                        'Product'   = 'OneNote'
                        'Inventory' = 'Notebooks in SharePoint and OneDrive'
                        'Migration' = 'Follows the files, check internal links'
                        'To do'     = 'Test opening and sync after the copy'
                    },
                    [ordered]@{
                        'Product'   = 'Stream (on SharePoint)'
                        'Inventory' = 'Videos in SharePoint and OneDrive'
                        'Migration' = 'Follows the files, check transcripts and chapters'
                        'To do'     = 'Sample the Teams meeting recordings'
                    },
                    [ordered]@{
                        'Product'   = 'Teams recordings and chats'
                        'Inventory' = '1:1 and group chats in mailboxes'
                        'Migration' = 'Depends on the tool (often a read-only history)'
                        'To do'     = 'Decide how to keep the history'
                    },
                    [ordered]@{
                        'Product'   = 'Copilot and agents'
                        'Inventory' = 'Licenses and agents per tenant'
                        'Migration' = 'Agents and connectors must be recreated'
                        'To do'     = 'List Copilot Studio agents and Graph connectors before the source tenant closes'
                    })
            }
        }

    )
}
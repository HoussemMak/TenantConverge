function Get-TcEntraIdCollector {
    <#
    .SYNOPSIS
    Lists the Entra ID collectors, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @(
        @{
            Id       = 'ENT-01'
            Workload = 'Entra ID'
            Title    = 'Organization, domains and sync'
            Service  = 'Graph'
            Collect  = {
                $o = @((Get-TcProperty (Get-TcGraphObject 'v1.0/organization') 'value')) | Select-Object -First 1
                Add-TcTable 'organizationSettings' @(
                    [ordered]@{ 'Setting' = 'Name'; 'Value' = (Get-TcProperty $o 'displayName') }, [ordered]@{ 'Setting' = 'Tenant ID'; 'Value' = (Get-TcProperty $o 'id') },
                    [ordered]@{ 'Setting' = 'Created on'; 'Value' = (Format-TcValue (Get-TcProperty $o 'createdDateTime')) }, [ordered]@{ 'Setting' = 'Country'; 'Value' = (Get-TcProperty $o 'countryLetterCode') },
                    [ordered]@{ 'Setting' = 'Language'; 'Value' = (Get-TcProperty $o 'preferredLanguage') }, [ordered]@{ 'Setting' = 'AD sync enabled'; 'Value' = [bool](Get-TcProperty $o 'onPremisesSyncEnabled') },
                    [ordered]@{ 'Setting' = 'Last AD sync'; 'Value' = (Format-TcValue (Get-TcProperty $o 'onPremisesLastSyncDateTime')) },
                    [ordered]@{ 'Setting' = 'Days since last sync'; 'Value' = (Get-TcDaysSince (Get-TcProperty $o 'onPremisesLastSyncDateTime')) },
                    [ordered]@{ 'Setting' = 'Technical notification emails'; 'Value' = (Format-TcValue (Get-TcProperty $o 'technicalNotificationMails')) })
                Add-TcTable 'domains' @(foreach ($d in @((Get-TcProperty (Get-TcGraphObject 'v1.0/domains') 'value'))) {
                        [ordered]@{
                            'Domain'         = (Get-TcProperty $d 'id')
                            'Verified'       = [bool](Get-TcProperty $d 'isVerified')
                            'Default'        = [bool](Get-TcProperty $d 'isDefault')
                            'Initial'        = [bool](Get-TcProperty $d 'isInitial')
                            'Authentication' = (Get-TcProperty $d 'authenticationType')
                            'Services'       = (Format-TcValue (Get-TcProperty $d 'supportedServices'))
                        }
                    })
                Invoke-TcCollectorPart 'On-premises sync' {
                    $s = @(Get-TcGraphList 'v1.0/directory/onPremisesSynchronization')
                    foreach ($x in $s) { Add-TcTable 'organizationSettings' -Append @(ConvertTo-TcSettingRow (Get-TcProperty $x 'features') 'Sync') }
                }
                Invoke-TcCollectorPart 'Administrative units' {
                    Add-TcTable 'administrativeUnits' @(foreach ($u in Get-TcGraphList 'v1.0/directory/administrativeUnits') {
                            [ordered]@{
                                'Name'        = (Get-TcProperty $u 'displayName')
                                'Description' = (Get-TcProperty $u 'description')
                                'Membership'  = (Get-TcProperty $u 'membershipType')
                            }
                        })
                }
            }
        }

        @{
            Id       = 'ENT-02'
            Workload = 'Entra ID'
            Title    = 'Licenses and subscriptions'
            Service  = 'Graph'
            Collect  = {
                Add-TcTable 'licenses' @(foreach ($s in @((Get-TcProperty (Get-TcGraphObject 'v1.0/subscribedSkus') 'value'))) {
                        $purchased = [int](Get-TcProperty (Get-TcProperty $s 'prepaidUnits') 'enabled' 0)
                        [ordered]@{
                            'SKU'        = (Get-TcProperty $s 'skuPartNumber')
                            'SkuId'      = (Get-TcProperty $s 'skuId')
                            'State'      = (Get-TcProperty $s 'capabilityStatus')
                            'Purchased'  = $purchased
                            'Consumed'   = [int](Get-TcProperty $s 'consumedUnits')
                            'Available'  = $purchased - [int](Get-TcProperty $s 'consumedUnits')
                            'Suspended'  = [int](Get-TcProperty (Get-TcProperty $s 'prepaidUnits') 'suspended' 0)
                            'In warning' = [int](Get-TcProperty (Get-TcProperty $s 'prepaidUnits') 'warning' 0)
                            'Plans'      = (@((Get-TcProperty $s 'servicePlans') | ForEach-Object { (Get-TcProperty $_ 'servicePlanName') }) -join ', ')
                        }
                    })
            }
        }

        @{
            Id       = 'ENT-03'
            Workload = 'Entra ID'
            Title    = 'Users, guests and last sign-ins'
            Service  = 'Graph'
            Collect  = {
                $skus = @{}
                foreach ($l in Get-TcTable 'licenses') { $skus[[string](Get-TcProperty $l 'SkuId')] = (Get-TcProperty $l 'SKU') }
                if (-not $skus.Count) { try { foreach ($s in @((Get-TcProperty (Get-TcGraphObject 'v1.0/subscribedSkus') 'value'))) { $skus[[string](Get-TcProperty $s 'skuId')] = (Get-TcProperty $s 'skuPartNumber') } } catch { Add-TcCollectorWarning 'License names' $_ } }
                $fields = 'id,userPrincipalName,displayName,givenName,surname,userType,accountEnabled,createdDateTime,assignedLicenses,licenseAssignmentStates,onPremisesSyncEnabled,onPremisesImmutableId,onPremisesSamAccountName,onPremisesProvisioningErrors,employeeId,mail,mobilePhone,businessPhones,officeLocation,city,department,jobTitle,companyName,usageLocation,externalUserState,creationType,proxyAddresses'
                $hasSignIn = $true
                $u = try { Get-TcGraphList "v1.0/users?`$select=$fields,signInActivity&`$top=999" }
                catch { $hasSignIn = $false; Add-TcCollectorWarning 'Last sign-ins (needs an Entra ID P1 license and AuditLog.Read.All)' $_; Get-TcGraphList "v1.0/users?`$select=$fields&`$top=999" }
                Add-TcTable 'users' @(foreach ($x in $u) {
                        $signIn = Get-TcProperty $x 'signInActivity'
                        $dates = @((Get-TcProperty $signIn 'lastSignInDateTime'), (Get-TcProperty $signIn 'lastNonInteractiveSignInDateTime'), (Get-TcProperty $signIn 'lastSuccessfulSignInDateTime')) | Where-Object { $_ }
                        $days = @($dates | ForEach-Object { Get-TcDaysSince $_ } | Where-Object { $null -ne $_ } | Sort-Object | Select-Object -First 1)
                        $licenses = @((Get-TcProperty $x 'assignedLicenses') | ForEach-Object { $k = [string](Get-TcProperty $_ 'skuId'); if ($skus[$k]) { $skus[$k] } else { $k } })
                        [ordered]@{
                            'Id'                  = (Get-TcProperty $x 'id')
                            'UPN'                 = (Get-TcProperty $x 'userPrincipalName')
                            'Name'                = (Get-TcProperty $x 'displayName')
                            'Type'                = (Get-TcProperty $x 'userType')
                            'Enabled'             = [bool](Get-TcProperty $x 'accountEnabled')
                            'Created'             = (Format-TcValue (Get-TcProperty $x 'createdDateTime'))
                            'Days since creation' = (Get-TcDaysSince (Get-TcProperty $x 'createdDateTime'))
                            'Last sign-in'        = $(if ($dates) { Format-TcValue ($dates | Sort-Object -Descending | Select-Object -First 1) } else { $null })
                            'Days inactive'       = $(if (-not $hasSignIn) { $null } elseif ($days.Count) { $days[0] } else { -1 })
                            'Licenses'            = ($licenses -join ', ')
                            'License count'       = $licenses.Count
                            'Synced'              = [bool](Get-TcProperty $x 'onPremisesSyncEnabled')
                            'Email'               = (Get-TcProperty $x 'mail')
                            'Department'          = (Get-TcProperty $x 'department')
                            'Job title'           = (Get-TcProperty $x 'jobTitle')
                            'Company'             = (Get-TcProperty $x 'companyName')
                            'Country'             = (Get-TcProperty $x 'usageLocation')
                            'Invitation state'    = (Get-TcProperty $x 'externalUserState')
                            'Creation type'       = (Get-TcProperty $x 'creationType')
                            'License errors'      = @((Get-TcProperty $x 'licenseAssignmentStates') | Where-Object { (Get-TcProperty $_ 'state') -eq 'Error' }).Count
                            'Address count'       = @((Get-TcProperty $x 'proxyAddresses')).Count
                            'First name'          = (Get-TcProperty $x 'givenName')
                            'Last name'           = (Get-TcProperty $x 'surname')
                            'Employee ID'         = (Get-TcProperty $x 'employeeId')
                            'AD account'          = (Get-TcProperty $x 'onPremisesSamAccountName')
                            'AD anchor'           = [bool](Get-TcProperty $x 'onPremisesImmutableId')
                            'Sync errors'         = @((Get-TcProperty $x 'onPremisesProvisioningErrors')).Count
                            'Mobile'              = (Get-TcProperty $x 'mobilePhone')
                            'Phone'               = (Format-TcValue (Get-TcProperty $x 'businessPhones'))
                            'Office'              = (Get-TcProperty $x 'officeLocation')
                            'City'                = (Get-TcProperty $x 'city')
                            'Addresses'           = (Format-TcValue (@((Get-TcProperty $x 'proxyAddresses') | Where-Object { $_ -match '^smtp:' }) | ForEach-Object { $_ -replace '^smtp:', '' }))
                        }
                    })
                if (-not $hasSignIn) { Add-TcCollectorNote 'Last sign-ins are not available: ''Days inactive'' is empty.' }
            }
        }

        @{
            Id       = 'ENT-04'
            Workload = 'Entra ID'
            Title    = 'Groups'
            Service  = 'Graph'
            Collect  = {
                $fields = 'id,displayName,mail,mailNickname,groupTypes,securityEnabled,mailEnabled,membershipRule,visibility,resourceProvisioningOptions,createdDateTime,onPremisesSyncEnabled,assignedLicenses'
                $hasOwners = $true
                $g = try { Get-TcGraphList "v1.0/groups?`$select=$fields&`$expand=owners(`$select=id)&`$top=100" }
                catch { $hasOwners = $false; Add-TcCollectorWarning 'Group owners' $_; Get-TcGraphList "v1.0/groups?`$select=$fields&`$top=999" }
                Add-TcTable 'groups' @(foreach ($x in $g) {
                        $type = if (@((Get-TcProperty $x 'groupTypes')) -contains 'Unified') { 'Microsoft 365' } elseif ((Get-TcProperty $x 'mailEnabled') -and (Get-TcProperty $x 'securityEnabled')) { 'Mail-enabled security' } elseif ((Get-TcProperty $x 'mailEnabled')) { 'Distribution list' } else { 'Security' }
                        [ordered]@{
                            'Id'             = (Get-TcProperty $x 'id')
                            'Name'           = (Get-TcProperty $x 'displayName')
                            'Type'           = $type
                            'Team'           = (@((Get-TcProperty $x 'resourceProvisioningOptions')) -contains 'Team')
                            'Dynamic'        = [bool](Get-TcProperty $x 'membershipRule')
                            'Visibility'     = (Get-TcProperty $x 'visibility')
                            'Synced'         = [bool](Get-TcProperty $x 'onPremisesSyncEnabled')
                            'Group licenses' = @((Get-TcProperty $x 'assignedLicenses')).Count
                            'Owners'         = $(if ($hasOwners) { @((Get-TcProperty $x 'owners')).Count } else { $null })
                            'Email'          = (Get-TcProperty $x 'mail')
                            'Alias'          = (Get-TcProperty $x 'mailNickname')
                            'Created'        = (Format-TcValue (Get-TcProperty $x 'createdDateTime'))
                            'Members'        = $null
                        }
                    })
                if ($script:TcDepth -eq 'Complete') {
                    $n = 0
                    foreach ($l in @(Limit-TcCollectorRow 'groups' @(Get-TcTable 'groups') ([int](Get-TcCollectionSetting 'maxGroupMemberCounts')))) {
                        try { $l['Members'] = [int](Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$(Get-TcProperty $l 'Id')/members/`$count" -Headers @{ ConsistencyLevel = 'eventual' } -ErrorAction Stop) } catch { $n++; if ($n -le 3) { Add-TcCollectorWarning "Member count of $(Get-TcProperty $l 'Name')" $_ } }
                    }
                    if ($n) { Add-TcCollectorNote "Member count not read for $n groups." }
                }
                Invoke-TcCollectorPart 'Group settings' {
                    foreach ($s in @((Get-TcProperty (Get-TcGraphObject 'v1.0/groupSettings') 'value'))) { Add-TcTable 'groupSettings' -Append @(foreach ($v in @($s.values)) { [ordered]@{ 'Setting' = "$(Get-TcProperty $s 'displayName').$(Get-TcProperty $v 'name')"; 'Value' = (Get-TcProperty $v 'value') } }) }
                    foreach ($p in @((Get-TcProperty (Get-TcGraphObject 'v1.0/groupLifecyclePolicies') 'value'))) { Add-TcTable 'groupSettings' -Append @(ConvertTo-TcSettingRow $p 'Expiration') }
                    if (-not @(Get-TcTable 'groupSettings').Count) { Add-TcTable 'groupSettings' @([ordered]@{ 'Setting' = 'Group.Unified'; 'Value' = 'Default settings (anyone can create groups)' }) }
                }
            }
        }

        @{
            Id       = 'ENT-05'
            Workload = 'Entra ID'
            Title    = 'Admin roles (active and eligible)'
            Service  = 'Graph'
            Collect  = {
                $roleNames = @{}
                foreach ($d in Get-TcGraphList "v1.0/roleManagement/directory/roleDefinitions?`$select=id,displayName") { $roleNames[[string](Get-TcProperty $d 'id')] = (Get-TcProperty $d 'displayName') }
                $buildRow = { param($a, $type) $p = (Get-TcProperty $a 'principal'); [ordered]@{
                        'Role'           = $roleNames[[string](Get-TcProperty $a 'roleDefinitionId')]
                        'Principal'      = $(if ((Get-TcProperty $p 'userPrincipalName')) { (Get-TcProperty $p 'userPrincipalName') } else { (Get-TcProperty $p 'displayName') })
                        'Principal type' = ([string](Get-TcProperty $p '@odata.type') -replace '#microsoft\.graph\.', '')
                        'Assignment'     = $type
                        'Scope'          = (Get-TcProperty $a 'directoryScopeId')
                    } }
                Add-TcTable 'adminRoles' @(foreach ($a in Get-TcGraphList "v1.0/roleManagement/directory/roleAssignments?`$expand=principal") { & $buildRow $a 'Active' })
                Invoke-TcCollectorPart 'Eligible roles (PIM, Entra ID P2 license)' { Add-TcTable 'adminRoles' -Append @(foreach ($a in Get-TcGraphList "v1.0/roleManagement/directory/roleEligibilitySchedules?`$expand=principal") { & $buildRow $a 'Eligible' }) }
            }
        }

        @{
            Id       = 'ENT-06'
            Workload = 'Entra ID'
            Title    = 'Conditional Access, authentication and authorization'
            Service  = 'Graph'
            Collect  = {
                Invoke-TcCollectorPart 'Conditional Access policies (Entra ID P1 license)' {
                    Add-TcTable 'conditionalAccess' @(foreach ($p in @((Get-TcProperty (Get-TcGraphObject 'v1.0/identity/conditionalAccess/policies') 'value'))) {
                            $c = (Get-TcProperty $p 'conditions'); $u = (Get-TcProperty $c 'users'); $grantControls = (Get-TcProperty $p 'grantControls')
                            $controls = @((Get-TcProperty $grantControls 'builtInControls')) + @($(if ((Get-TcProperty $grantControls 'authenticationStrength')) { "strength:$(Get-TcProperty (Get-TcProperty $grantControls 'authenticationStrength') 'displayName')" }))
                            [ordered]@{
                                'Name'                         = (Get-TcProperty $p 'displayName')
                                'State'                        = (Get-TcProperty $p 'state')
                                'Users'                        = (Format-TcValue (@((Get-TcProperty $u 'includeUsers')) + @(@((Get-TcProperty $u 'includeGroups')) | ForEach-Object { "group:$_" }) + @(@((Get-TcProperty $u 'includeRoles')) | ForEach-Object { "role:$_" }) + @($(if ((Get-TcProperty $u 'includeGuestsOrExternalUsers')) { 'guests' }))))
                                'Exclusions'                   = (@((Get-TcProperty $u 'excludeUsers')).Count + @((Get-TcProperty $u 'excludeGroups')).Count + @((Get-TcProperty $u 'excludeRoles')).Count)
                                'Applications'                 = (Format-TcValue (Get-TcProperty (Get-TcProperty $c 'applications') 'includeApplications'))
                                'Client apps'                  = (Format-TcValue (Get-TcProperty $c 'clientAppTypes'))
                                'Platforms'                    = (Format-TcValue (Get-TcProperty (Get-TcProperty $c 'platforms') 'includePlatforms'))
                                'Locations'                    = (Format-TcValue (Get-TcProperty (Get-TcProperty $c 'locations') 'includeLocations'))
                                'Controls'                     = ("{0} ({1})" -f ($controls -join ', '), (Get-TcProperty $grantControls 'operator'))
                                'Session'                      = (Format-TcValue (Get-TcProperty $p 'sessionControls'))
                                'MFA for all'                  = ((Get-TcProperty $p 'state') -eq 'enabled' -and @((Get-TcProperty $u 'includeUsers')) -contains 'All' -and (@((Get-TcProperty $grantControls 'builtInControls')) -contains 'mfa' -or [bool](Get-TcProperty $grantControls 'authenticationStrength')))
                                'Blocks legacy authentication' = ((Get-TcProperty $p 'state') -eq 'enabled' -and @((Get-TcProperty $grantControls 'builtInControls')) -contains 'block' -and (@((Get-TcProperty $c 'clientAppTypes')) -contains 'exchangeActiveSync' -or @((Get-TcProperty $c 'clientAppTypes')) -contains 'other'))
                            }
                        })
                    Add-TcTable 'namedLocations' @(foreach ($l in @((Get-TcProperty (Get-TcGraphObject 'v1.0/identity/conditionalAccess/namedLocations') 'value'))) {
                            [ordered]@{
                                'Name'                = (Get-TcProperty $l 'displayName')
                                'Type'                = ([string](Get-TcProperty $l '@odata.type') -replace '#microsoft\.graph\.', '')
                                'Trusted'             = [bool](Get-TcProperty $l 'isTrusted')
                                'Ranges or countries' = (Format-TcValue $(if ((Get-TcProperty $l 'ipRanges')) { @((Get-TcProperty $l 'ipRanges') | ForEach-Object { (Get-TcProperty $_ 'cidrAddress') }) } else { (Get-TcProperty $l 'countriesAndRegions') }))
                            }
                        })
                }
                Invoke-TcCollectorPart 'Security defaults' { $d = Get-TcGraphObject 'v1.0/policies/identitySecurityDefaultsEnforcementPolicy'; Add-TcTable 'securitySettings' -Append @([ordered]@{ 'Setting' = 'Security defaults enabled'; 'Value' = [bool](Get-TcProperty $d 'isEnabled') }) }
                Invoke-TcCollectorPart 'Authorization policy' {
                    $a = Get-TcGraphObject 'v1.0/policies/authorizationPolicy'
                    $guestAccess = @{ 'a0b1b346-4d3e-4e8b-98f8-753987be4970' = 'Same as members'; '10dae51f-b6af-4016-8d66-8c2a99b929b3' = 'Limited (default)'; '2af84b1e-32c8-42b7-82bc-daa82404023b' = 'Restricted' }
                    Add-TcTable 'securitySettings' -Append @(
                        [ordered]@{ 'Setting' = 'Invitations allowed from'; 'Value' = (Get-TcProperty $a 'allowInvitesFrom') },
                        [ordered]@{ 'Setting' = 'Guest directory access'; 'Value' = $(if ($guestAccess[[string](Get-TcProperty $a 'guestUserRoleId')]) { $guestAccess[[string](Get-TcProperty $a 'guestUserRoleId')] } else { (Get-TcProperty $a 'guestUserRoleId') }) },
                        [ordered]@{ 'Setting' = 'Email-based self-service sign-up'; 'Value' = [bool](Get-TcProperty $a 'allowedToSignUpEmailBasedSubscriptions') },
                        [ordered]@{ 'Setting' = 'Email-verified users can join'; 'Value' = [bool](Get-TcProperty $a 'allowEmailVerifiedUsersToJoinOrganization') })
                    Add-TcTable 'securitySettings' -Append @(ConvertTo-TcSettingRow (Get-TcProperty $a 'defaultUserRolePermissions') 'User permissions')
                }
                Invoke-TcCollectorPart 'Authentication methods' {
                    $m = Get-TcGraphObject 'v1.0/policies/authenticationMethodsPolicy'
                    Add-TcTable 'securitySettings' -Append @(foreach ($x in @((Get-TcProperty $m 'authenticationMethodConfigurations'))) { [ordered]@{ 'Setting' = "Method $(Get-TcProperty $x 'id')"; 'Value' = (Get-TcProperty $x 'state') } })
                }
            }
        }

        @{
            Id       = 'ENT-07'
            Workload = 'Entra ID'
            Title    = 'Cross-tenant access, B2B and multitenant organization'
            Service  = 'Graph'
            Collect  = {
                Add-TcTable 'crossTenantSettings' @(ConvertTo-TcSettingRow (Get-TcGraphObject 'v1.0/policies/crossTenantAccessPolicy/default') 'Default')
                $partners = try { Get-TcGraphList "v1.0/policies/crossTenantAccessPolicy/partners?`$expand=identitySynchronization" } catch { Add-TcCollectorWarning 'Identity synchronization of the partners' $_; Get-TcGraphList 'v1.0/policies/crossTenantAccessPolicy/partners' }
                Add-TcTable 'crossTenantPartners' @(foreach ($p in $partners) {
                        $displayName = $null; $defaultDomain = $null
                        try { $i = Get-TcGraphObject ("v1.0/tenantRelationships/findTenantInformationByTenantId(tenantId='{0}')" -f (Get-TcProperty $p 'tenantId')); $displayName = (Get-TcProperty $i 'displayName'); $defaultDomain = (Get-TcProperty $i 'defaultDomainName') } catch { Add-TcCollectorWarning "Name of partner $(Get-TcProperty $p 'tenantId')" $_ }
                        [ordered]@{
                            'Tenant'                   = (Get-TcProperty $p 'tenantId')
                            'Name'                     = $displayName
                            'Domain'                   = $defaultDomain
                            'MFA trusted'              = (Get-TcProperty (Get-TcProperty $p 'inboundTrust') 'isMfaAccepted')
                            'Compliant device trusted' = (Get-TcProperty (Get-TcProperty $p 'inboundTrust') 'isCompliantDeviceAccepted')
                            'Inbound collaboration'    = (Get-TcProperty (Get-TcProperty (Get-TcProperty $p 'b2bCollaborationInbound') 'usersAndGroups') 'accessType')
                            'Outbound collaboration'   = (Get-TcProperty (Get-TcProperty (Get-TcProperty $p 'b2bCollaborationOutbound') 'usersAndGroups') 'accessType')
                            'Inbound direct connect'   = (Get-TcProperty (Get-TcProperty (Get-TcProperty $p 'b2bDirectConnectInbound') 'usersAndGroups') 'accessType')
                            'Outbound direct connect'  = (Get-TcProperty (Get-TcProperty (Get-TcProperty $p 'b2bDirectConnectOutbound') 'usersAndGroups') 'accessType')
                            'Inbound auto-redeem'      = (Get-TcProperty (Get-TcProperty $p 'automaticUserConsentSettings') 'inboundAllowed')
                            'Outbound auto-redeem'     = (Get-TcProperty (Get-TcProperty $p 'automaticUserConsentSettings') 'outboundAllowed')
                            'Inbound sync'             = (Get-TcProperty (Get-TcProperty (Get-TcProperty $p 'identitySynchronization') 'userSyncInbound') 'isSyncAllowed')
                        }
                    })
                Invoke-TcCollectorPart 'Multitenant organization' {
                    $m = Get-TcGraphObject 'v1.0/tenantRelationships/multiTenantOrganization'
                    Add-TcTable 'crossTenantSettings' -Append @([ordered]@{ 'Setting' = 'Multitenant organization'; 'Value' = ('{0} ({1})' -f (Get-TcProperty $m 'displayName'), (Get-TcProperty $m 'state')) })
                }
            }
        }

        @{
            Id       = 'ENT-08'
            Workload = 'Entra ID'
            Title    = 'Applications, service principals and consents'
            Service  = 'Graph'
            Collect  = {
                param($Role)
                $tenantId = (Get-TcProperty $script:TcTenants[$Role] 'tenantId')
                Add-TcTable 'applications' @(foreach ($a in Get-TcGraphList "v1.0/applications?`$select=id,appId,displayName,createdDateTime,signInAudience,passwordCredentials,keyCredentials&`$top=999") {
                        $expiries = @(@((Get-TcProperty $a 'passwordCredentials')) + @((Get-TcProperty $a 'keyCredentials')) | ForEach-Object { Get-TcDaysSince (Get-TcProperty $_ 'endDateTime') } | Where-Object { $null -ne $_ })
                        [ordered]@{
                            'Name'           = (Get-TcProperty $a 'displayName')
                            'AppId'          = (Get-TcProperty $a 'appId')
                            'Created'        = (Format-TcValue (Get-TcProperty $a 'createdDateTime'))
                            'Audience'       = (Get-TcProperty $a 'signInAudience')
                            'Secrets'        = @((Get-TcProperty $a 'passwordCredentials')).Count
                            'Certificates'   = @((Get-TcProperty $a 'keyCredentials')).Count
                            'Days to expiry' = $(if (@($expiries | Where-Object { $_ -le 0 }).Count) { -1 * (Get-TcProperty (@($expiries | Where-Object { $_ -le 0 }) | Measure-Object -Maximum) 'Maximum') } else { $null })
                            'Expired'        = @($expiries | Where-Object { $_ -gt 0 }).Count
                        }
                    })
                $principals = Get-TcGraphList "v1.0/servicePrincipals?`$select=id,appId,displayName,servicePrincipalType,appOwnerOrganizationId,accountEnabled,publisherName&`$top=999"
                $principalNames = @{}; foreach ($s in $principals) { $principalNames[[string](Get-TcProperty $s 'id')] = (Get-TcProperty $s 'displayName') }
                Add-TcTable 'servicePrincipals' @(foreach ($s in $principals | Where-Object { (Get-TcProperty $_ 'servicePrincipalType') -ne 'ManagedIdentity' }) {
                        $owner = [string](Get-TcProperty $s 'appOwnerOrganizationId')
                        $origin = if ($owner -in $script:TcMicrosoftTenantIds) { 'Microsoft' } elseif ($owner -eq $tenantId) { 'Internal' } else { 'Third party' }
                        [ordered]@{
                            'Name'      = (Get-TcProperty $s 'displayName')
                            'AppId'     = (Get-TcProperty $s 'appId')
                            'Publisher' = (Get-TcProperty $s 'publisherName')
                            'Origin'    = $origin
                            'Enabled'   = [bool](Get-TcProperty $s 'accountEnabled')
                            'Type'      = (Get-TcProperty $s 'servicePrincipalType')
                            'Id'        = (Get-TcProperty $s 'id')
                        }
                    })
                $upn = @{}; foreach ($u in Get-TcTable 'users') { $upn[[string](Get-TcProperty $u 'Id')] = (Get-TcProperty $u 'UPN') }
                Invoke-TcCollectorPart 'Delegated consents' {
                    Add-TcTable 'delegatedConsents' @(foreach ($g in Get-TcGraphList "v1.0/oauth2PermissionGrants?`$top=999") {
                            [ordered]@{
                                'Application'  = $principalNames[[string](Get-TcProperty $g 'clientId')]
                                'Consent type' = $(if ((Get-TcProperty $g 'consentType') -eq 'AllPrincipals') { 'Administrator (all)' } else { 'User' })
                                'Scopes'       = ([string](Get-TcProperty $g 'scope')).Trim()
                                'User'         = $(if ((Get-TcProperty $g 'principalId')) { $upn[[string](Get-TcProperty $g 'principalId')] })
                            }
                        })
                }
            }
        }

        @{
            Id       = 'ENT-09'
            Workload = 'Entra ID'
            Title    = 'Devices registered in Entra ID'
            Service  = 'Graph'
            Collect  = {
                Add-TcTable 'devices' @(foreach ($d in Get-TcGraphList "v1.0/devices?`$select=displayName,operatingSystem,operatingSystemVersion,trustType,approximateLastSignInDateTime,isCompliant,isManaged,accountEnabled,registrationDateTime&`$top=999") {
                        [ordered]@{
                            'Name'          = (Get-TcProperty $d 'displayName')
                            'OS'            = (Get-TcProperty $d 'operatingSystem')
                            'Version'       = (Get-TcProperty $d 'operatingSystemVersion')
                            'Join type'     = @{ AzureAd = 'Entra ID'; ServerAd = 'Hybrid'; Workplace = 'Registered' }[[string](Get-TcProperty $d 'trustType')]
                            'Compliant'     = (Get-TcProperty $d 'isCompliant')
                            'Managed'       = (Get-TcProperty $d 'isManaged')
                            'Enabled'       = [bool](Get-TcProperty $d 'accountEnabled')
                            'Last sign-in'  = (Format-TcValue (Get-TcProperty $d 'approximateLastSignInDateTime'))
                            'Days inactive' = (Get-TcDaysSince (Get-TcProperty $d 'approximateLastSignInDateTime'))
                        }
                    })
            }
        }

        @{
            Id       = 'ENT-10'
            Workload = 'Entra ID'
            Title    = 'MFA registration and methods'
            Service  = 'Graph'
            Collect  = {
                Add-TcTable 'mfaRegistrations' @(foreach ($r in Get-TcGraphList "v1.0/reports/authenticationMethods/userRegistrationDetails?`$top=999") {
                        [ordered]@{
                            'UPN'            = (Get-TcProperty $r 'userPrincipalName')
                            'Type'           = (Get-TcProperty $r 'userType')
                            'MFA registered' = [bool](Get-TcProperty $r 'isMfaRegistered')
                            'MFA capable'    = [bool](Get-TcProperty $r 'isMfaCapable')
                            'Passwordless'   = [bool](Get-TcProperty $r 'isPasswordlessCapable')
                            'Methods'        = (Format-TcValue (Get-TcProperty $r 'methodsRegistered'))
                            'Default method' = (Get-TcProperty $r 'defaultMfaMethod')
                            'Admin'          = [bool](Get-TcProperty $r 'isAdmin')
                        }
                    })
            }
        }

        @{
            Id       = 'ENT-11'
            Workload = 'Entra ID'
            Title    = 'Recent sign-ins: client apps, legacy authentication, countries'
            Service  = 'Graph'
            Collect  = {
                $days = [int](Get-TcCollectionSetting 'signInDays'); $pageSize = 999; $maxPages = [int](Get-TcCollectionSetting 'maxSignInPages')
                $buildUri = { "https://graph.microsoft.com/v1.0/auditLogs/signIns?`$filter=createdDateTime ge {0}&`$top={1}" -f (Get-Date).ToUniversalTime().AddDays(- $days).ToString('yyyy-MM-ddTHH:mm:ssZ'), $pageSize }
                $uri = & $buildUri
                $aggregates = @{}; $legacy = @{}; $pages = 0; $total = 0; $reduced = $false; $truncated = $false
                $modernClients = '^(Browser|Mobile Apps and Desktop clients)$'
                while ($uri -and $pages -lt $maxPages) {
                    $r = $null
                    for ($attempt = 1; $attempt -le 4 -and $null -eq $r; $attempt++) {
                        try { $r = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable -ErrorAction Stop }
                        catch {
                            $t = Get-TcErrorText $_
                            if ($attempt -ge 4 -or $t -notmatch 'Timeout|timed out|canceled|429|503|504|TooManyRequests') { if ($pages) { break }; throw }
                            if ($pages -eq 0 -and $t -match 'Timeout|timed out|canceled|504') {
                                # A large log: the first page exceeds the 300 second limit of the Graph client.
                                $pageSize = 100; $days = [math]::Max(1, [math]::Floor($days / 3)); $maxPages *= 5; $uri = & $buildUri; $reduced = $true
                            }
                            else { Start-Sleep -Seconds (10 * $attempt) }
                        }
                    }
                    if ($null -eq $r) { $truncated = $true; break }
                    foreach ($s in @((Get-TcProperty $r 'value'))) {
                        $total++
                        $outcome = if ([int](Get-TcProperty (Get-TcProperty $s 'status') 'errorCode') -eq 0) { 'Success' } else { 'Failure' }
                        foreach ($dimension in @(@('Client app', [string](Get-TcProperty $s 'clientAppUsed')), @('Application', [string](Get-TcProperty $s 'appDisplayName')), @('Country', [string](Get-TcProperty (Get-TcProperty $s 'location') 'countryOrRegion')), @('Result', $outcome))) {
                            $k = "$($dimension[0])|$($dimension[1])"
                            if (-not $aggregates.ContainsKey($k)) { $aggregates[$k] = @{ n = 0; u = @{} } }
                            $aggregates[$k]['n']++; $aggregates[$k]['u'][[string](Get-TcProperty $s 'userPrincipalName')] = 1
                        }
                        if ([string](Get-TcProperty $s 'clientAppUsed') -and [string](Get-TcProperty $s 'clientAppUsed') -notmatch $modernClients) {
                            $k = "$(Get-TcProperty $s 'userPrincipalName')|$(Get-TcProperty $s 'clientAppUsed')"
                            if (-not $legacy.ContainsKey($k)) { $legacy[$k] = @{ upn = (Get-TcProperty $s 'userPrincipalName'); client = (Get-TcProperty $s 'clientAppUsed'); n = 0; d = (Get-TcProperty $s 'createdDateTime') } }
                            $legacy[$k]['n']++
                        }
                    }
                    $uri = (Get-TcProperty $r '@odata.nextLink'); $pages++
                }
                if ($reduced) { Add-TcCollectorNote ('Large sign-in log (the 300 s limit was exceeded): read over {0} days, in pages of 100.' -f $days) }
                if ($truncated) { Add-TcCollectorLimit ('reading stopped after {0} pages (timeouts): sample of {1} sign-ins.' -f $pages, $total) }
                elseif ($uri) { Add-TcCollectorLimit ('sample of {0} sign-ins from the last {1} days ({2} pages).' -f $total, $days, $maxPages) }
                Add-TcTable 'signInSummary' @(foreach ($k in $aggregates.Keys | Sort-Object) {
                        $p = $k -split '\|', 2; [ordered]@{
                            'Dimension' = $p[0]
                            'Value'     = $(if ($p[1]) { $p[1] } else { '(empty)' })
                            'Sign-ins'  = (Get-TcProperty $aggregates[$k] 'n')
                            'Users'     = (Get-TcProperty $aggregates[$k] 'u').Count
                        }
                    })
                Add-TcTable 'legacySignIns' @(foreach ($h in $legacy.Values) {
                        [ordered]@{
                            'UPN'      = (Get-TcProperty $h 'upn')
                            'Client'   = (Get-TcProperty $h 'client')
                            'Sign-ins' = (Get-TcProperty $h 'n')
                            'Last'     = (Format-TcValue (Get-TcProperty $h 'd'))
                        }
                    })
            }
        }

        @{
            Id       = 'ENT-12'
            Workload = 'Entra ID'
            Title    = 'Application permissions granted to third-party and internal apps'
            Service  = 'Graph'
            Requires = @('servicePrincipals')
            Collect  = {
                $principals = @(Limit-TcCollectorRow 'third-party and internal applications' @(Get-TcTable 'servicePrincipals' | Where-Object { (Get-TcProperty $_ 'Origin') -in 'Third party', 'Internal' -and (Get-TcProperty $_ 'Id') }) ([int](Get-TcCollectionSetting 'maxPermissionApps')))
                $roles = @{}
                Add-TcTable 'applicationPermissions' @(foreach ($sp in $principals) {
                        try {
                            foreach ($a in Get-TcGraphList "v1.0/servicePrincipals/$(Get-TcProperty $sp 'Id')/appRoleAssignments") {
                                $resourceId = [string](Get-TcProperty $a 'resourceId')
                                if (-not $roles.ContainsKey($resourceId)) { $roles[$resourceId] = @{}; try { foreach ($x in @((Get-TcProperty (Get-TcGraphObject "v1.0/servicePrincipals/$resourceId`?`$select=appRoles") 'appRoles'))) { $roles[$resourceId][[string](Get-TcProperty $x 'id')] = (Get-TcProperty $x 'value') } } catch { Add-TcCollectorWarning "Permission names of $(Get-TcProperty $a 'resourceDisplayName')" $_ } }
                                [ordered]@{
                                    'Application' = (Get-TcProperty $sp 'Name')
                                    'Origin'      = (Get-TcProperty $sp 'Origin')
                                    'Resource'    = (Get-TcProperty $a 'resourceDisplayName')
                                    'Permission'  = $(if ($roles[$resourceId][[string](Get-TcProperty $a 'appRoleId')]) { $roles[$resourceId][[string](Get-TcProperty $a 'appRoleId')] } else { [string](Get-TcProperty $a 'appRoleId') })
                                    'Granted on'  = (Format-TcValue (Get-TcProperty $a 'createdDateTime'))
                                }
                            }
                        }
                        catch { Add-TcCollectorWarning "Permissions of $(Get-TcProperty $sp 'Name')" $_ }
                    })
            }
        }

        @{
            Id       = 'ENT-13'
            Workload = 'Entra ID'
            Title    = 'Risky users (Identity Protection)'
            Service  = 'Graph'
            Collect  = {
                Add-TcTable 'riskyUsers' @(foreach ($u in Get-TcGraphList "v1.0/identityProtection/riskyUsers?`$filter=riskState eq 'atRisk' or riskState eq 'confirmedCompromised'") {
                        [ordered]@{
                            'UPN'     = (Get-TcProperty $u 'userPrincipalName')
                            'Level'   = (Get-TcProperty $u 'riskLevel')
                            'State'   = (Get-TcProperty $u 'riskState')
                            'Detail'  = (Get-TcProperty $u 'riskDetail')
                            'Updated' = (Format-TcValue (Get-TcProperty $u 'riskLastUpdatedDateTime'))
                        }
                    })
            }
        }

    )
}
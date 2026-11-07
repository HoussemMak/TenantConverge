function Get-TcIntuneCollector {
    <#
    .SYNOPSIS
    Lists the Intune collectors, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @(
        @{
            Id       = 'INT-01'
            Workload = 'Intune'
            Title    = 'Managed devices'
            Service  = 'Graph'
            Collect  = {
                Add-TcTable 'managedDevices' @(foreach ($d in Get-TcGraphList "v1.0/deviceManagement/managedDevices?`$select=deviceName,operatingSystem,osVersion,complianceState,managedDeviceOwnerType,deviceEnrollmentType,lastSyncDateTime,model,manufacturer,serialNumber,userPrincipalName,isEncrypted") {
                        [ordered]@{
                            'Name'          = (Get-TcProperty $d 'deviceName')
                            'OS'            = (Get-TcProperty $d 'operatingSystem')
                            'Version'       = (Get-TcProperty $d 'osVersion')
                            'Compliance'    = (Get-TcProperty $d 'complianceState')
                            'Ownership'     = (Get-TcProperty $d 'managedDeviceOwnerType')
                            'Enrollment'    = (Get-TcProperty $d 'deviceEnrollmentType')
                            'Last sync'     = (Format-TcValue (Get-TcProperty $d 'lastSyncDateTime'))
                            'Days inactive' = (Get-TcDaysSince (Get-TcProperty $d 'lastSyncDateTime'))
                            'Model'         = (Get-TcProperty $d 'model')
                            'Manufacturer'  = (Get-TcProperty $d 'manufacturer')
                            'Serial number' = (Get-TcProperty $d 'serialNumber')
                            'User'          = (Get-TcProperty $d 'userPrincipalName')
                            'Encrypted'     = (Get-TcProperty $d 'isEncrypted')
                        }
                    })
            }
        }

        @{
            Id       = 'INT-02'
            Workload = 'Intune'
            Title    = 'Autopilot: devices and profiles'
            Service  = 'Graph'
            Collect  = {
                Add-TcTable 'autopilotDevices' @(foreach ($d in Get-TcGraphList 'v1.0/deviceManagement/windowsAutopilotDeviceIdentities') {
                        [ordered]@{
                            'Serial number'    = (Get-TcProperty $d 'serialNumber')
                            'Model'            = (Get-TcProperty $d 'model')
                            'Manufacturer'     = (Get-TcProperty $d 'manufacturer')
                            'Group tag'        = (Get-TcProperty $d 'groupTag')
                            'Enrollment state' = (Get-TcProperty $d 'enrollmentState')
                            'Last contact'     = (Format-TcValue (Get-TcProperty $d 'lastContactedDateTime'))
                        }
                    })
                Invoke-TcCollectorPart 'Autopilot deployment profiles' {
                    Add-TcTable 'autopilotProfiles' @(foreach ($p in Get-TcGraphList 'beta/deviceManagement/windowsAutopilotDeploymentProfiles') {
                            [ordered]@{
                                'Name'                 = (Get-TcProperty $p 'displayName')
                                'Type'                 = (Get-TcODataName (Get-TcProperty $p '@odata.type'))
                                'Device name template' = (Get-TcProperty $p 'deviceNameTemplate')
                                'Created'              = (Format-TcValue (Get-TcProperty $p 'createdDateTime'))
                            }
                        })
                }
            }
        }

        @{
            Id       = 'INT-03'
            Workload = 'Intune'
            Title    = 'Policies: compliance, configuration, catalog, scripts, security'
            Service  = 'Graph'
            Collect  = {
                $sources = [ordered]@{
                    'Compliance'              = "v1.0/deviceManagement/deviceCompliancePolicies?`$expand=assignments"
                    'Configuration'           = "v1.0/deviceManagement/deviceConfigurations?`$expand=assignments"
                    'Settings catalog'        = "beta/deviceManagement/configurationPolicies?`$expand=assignments"
                    'Administrative template' = 'beta/deviceManagement/groupPolicyConfigurations'
                    'Endpoint security'       = 'beta/deviceManagement/intents'
                    'Enrollment'              = 'v1.0/deviceManagement/deviceEnrollmentConfigurations'
                    'Script'                  = 'beta/deviceManagement/deviceManagementScripts'
                    'Proactive remediation'   = 'beta/deviceManagement/deviceHealthScripts'
                }
                Add-TcTable 'intunePolicies' @()
                foreach ($k in $sources.Keys) {
                    Invoke-TcCollectorPart "Policies - $k" {
                        Add-TcTable 'intunePolicies' -Append @(foreach ($p in Get-TcGraphList $sources[$k]) {
                                $displayName = if ((Get-TcProperty $p 'displayName')) { (Get-TcProperty $p 'displayName') } else { (Get-TcProperty $p 'name') }
                                [ordered]@{
                                    'Category'    = $k
                                    'Name'        = $displayName
                                    'Platform'    = $(if ((Get-TcProperty $p 'platforms')) { [string](Get-TcProperty $p 'platforms') } else { Get-TcODataName (Get-TcProperty $p '@odata.type') })
                                    'Assignments' = $(if ($p.ContainsKey('assignments')) { @((Get-TcProperty $p 'assignments')).Count } else { $null })
                                    'Modified'    = (Format-TcValue (Get-TcProperty $p 'lastModifiedDateTime'))
                                }
                            })
                    }
                }
            }
        }

        @{
            Id       = 'INT-04'
            Workload = 'Intune'
            Title    = 'Apps and app protection'
            Service  = 'Graph'
            Collect  = {
                Add-TcTable 'intuneApps' @(foreach ($a in Get-TcGraphList 'v1.0/deviceAppManagement/mobileApps') {
                        [ordered]@{
                            'Name'      = (Get-TcProperty $a 'displayName')
                            'Type'      = (Get-TcODataName (Get-TcProperty $a '@odata.type'))
                            'Publisher' = (Get-TcProperty $a 'publisher')
                            'Assigned'  = (Get-TcProperty $a 'isAssigned')
                            'Created'   = (Format-TcValue (Get-TcProperty $a 'createdDateTime'))
                        }
                    })
                Invoke-TcCollectorPart 'App protection (MAM)' { Add-TcTable 'appProtectionPolicies' @(foreach ($p in Get-TcGraphList 'v1.0/deviceAppManagement/managedAppPolicies') {
                            [ordered]@{
                                'Name'     = (Get-TcProperty $p 'displayName')
                                'Type'     = (Get-TcODataName (Get-TcProperty $p '@odata.type'))
                                'Modified' = (Format-TcValue (Get-TcProperty $p 'lastModifiedDateTime'))
                            }
                        }) }
            }
        }

        @{
            Id       = 'INT-05'
            Workload = 'Intune'
            Title    = 'Connectors and tokens: Apple (APNs, ABM, VPP), Android Enterprise'
            Service  = 'Graph'
            Collect  = {
                $l = [System.Collections.Generic.List[object]]::new()
                Invoke-TcCollectorPart 'Apple MDM certificate (APNs)' {
                    $a = $null
                    try { $a = Get-TcGraphObject 'v1.0/deviceManagement/applePushNotificationCertificate' }
                    catch { if ((Get-TcErrorText $_) -notmatch 'ResourceNotFound|NotFound|\b404\b') { throw } }   # No APNs certificate means no managed Apple device.
                    if ($a -and (Get-TcProperty $a 'appleIdentifier')) {
                        $l.Add([ordered]@{
                                'Type'           = 'Apple MDM certificate (APNs)'
                                'Name'           = (Get-TcProperty $a 'topicIdentifier')
                                'Account'        = (Get-TcProperty $a 'appleIdentifier')
                                'Expiration'     = (Format-TcValue (Get-TcProperty $a 'expirationDateTime'))
                                'Days remaining' = $(if ((Get-TcProperty $a 'expirationDateTime')) { - (Get-TcDaysSince (Get-TcProperty $a 'expirationDateTime')) })
                            })
                    } }
                Invoke-TcCollectorPart 'Apple Business Manager (ADE)' { foreach ($a in Get-TcGraphList 'beta/deviceManagement/depOnboardingSettings') {
                        $l.Add([ordered]@{
                                'Type'           = 'Apple Business Manager token'
                                'Name'           = (Get-TcProperty $a 'tokenName')
                                'Account'        = (Get-TcProperty $a 'appleIdentifier')
                                'Expiration'     = (Format-TcValue (Get-TcProperty $a 'tokenExpirationDateTime'))
                                'Days remaining' = $(if ((Get-TcProperty $a 'tokenExpirationDateTime')) { - (Get-TcDaysSince (Get-TcProperty $a 'tokenExpirationDateTime')) })
                            })
                    } }
                Invoke-TcCollectorPart 'VPP tokens' { foreach ($a in Get-TcGraphList 'v1.0/deviceAppManagement/vppTokens') {
                        $l.Add([ordered]@{
                                'Type'           = 'VPP token (Apple apps)'
                                'Name'           = (Get-TcProperty $a 'organizationName')
                                'Account'        = (Get-TcProperty $a 'appleId')
                                'Expiration'     = (Format-TcValue (Get-TcProperty $a 'expirationDateTime'))
                                'Days remaining' = $(if ((Get-TcProperty $a 'expirationDateTime')) { - (Get-TcDaysSince (Get-TcProperty $a 'expirationDateTime')) })
                            })
                    } }
                Invoke-TcCollectorPart 'Android Enterprise' { $a = Get-TcGraphObject 'beta/deviceManagement/androidManagedStoreAccountEnterpriseSettings'; if ((Get-TcProperty $a 'bindStatus') -and (Get-TcProperty $a 'bindStatus') -ne 'notBound') {
                        $l.Add([ordered]@{
                                'Type'           = 'Android Enterprise'
                                'Name'           = (Get-TcProperty $a 'bindStatus')
                                'Account'        = (Get-TcProperty $a 'ownerUserPrincipalName')
                                'Expiration'     = $null
                                'Days remaining' = $null
                            })
                    } }
                Add-TcTable 'intuneConnectors' $l
            }
        }

    )
}
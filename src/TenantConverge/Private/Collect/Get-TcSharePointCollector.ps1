function Get-TcSharePointCollector {
    <#
    .SYNOPSIS
    Lists the SharePoint and OneDrive collectors, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @(
        @{
            Id       = 'SPO-01'
            Workload = 'SharePoint and OneDrive'
            Title    = 'SharePoint and OneDrive tenant settings'
            Service  = 'Pnp'
            Collect  = {
                Add-TcTable 'sharePointSettings' @(ConvertTo-TcSettingRow (Get-PnPTenant -Connection $script:TcPnpConnection -ErrorAction Stop))
                Invoke-TcCollectorPart 'App catalog and home site' {
                    $p = @([ordered]@{
                            'Type'   = 'App catalog'
                            'Name'   = [string](Get-PnPTenantAppCatalogUrl -Connection $script:TcPnpConnection -ErrorAction Stop)
                            'Detail' = ''
                        })
                    try {
                        $h = Get-PnPHomeSite -Connection $script:TcPnpConnection -ErrorAction Stop; if ($h) {
                            $p += [ordered]@{
                                'Type'   = 'Home site'
                                'Name'   = [string]$h
                                'Detail' = ''
                            }
                        }
                    }
                    catch { Add-TcCollectorWarning 'Home site' $_ }
                    Add-TcTable 'sharePointCustomizations' -Append $p
                }
            }
        }

        @{
            Id       = 'SPO-02'
            Workload = 'SharePoint and OneDrive'
            Title    = 'SharePoint sites (all templates)'
            Service  = 'Pnp'
            Collect  = {
                $p = @{ Connection = $script:TcPnpConnection; ErrorAction = 'Stop' }
                if ($script:TcDepth -eq 'Complete') { $p['Detailed'] = $true }
                $s = @(Get-PnPTenantSite @p)
                Add-TcTable 'sites' @(foreach ($x in $s) {
                        $u = [uri](Get-TcProperty $x 'Url')
                        [ordered]@{
                            'Url'             = (Get-TcProperty $x 'Url')
                            'Path'            = (Get-TcProperty $u 'AbsolutePath').TrimEnd('/').ToLowerInvariant()
                            'Title'           = (Get-TcProperty $x 'Title')
                            'Template'        = (Get-TcProperty $x 'Template')
                            'Storage MB'      = [double](Get-TcSafeProperty $x 'StorageUsageCurrent' 0)
                            'Quota MB'        = [double](Get-TcSafeProperty $x 'StorageQuota' 0)
                            'Last modified'   = (Format-TcValue (Get-TcSafeProperty $x 'LastContentModifiedDate'))
                            'Days inactive'   = (Get-TcDaysSince (Get-TcSafeProperty $x 'LastContentModifiedDate'))
                            'Sharing'         = [string](Get-TcSafeProperty $x 'SharingCapability')
                            'Lock state'      = [string](Get-TcSafeProperty $x 'LockState')
                            'Owner'           = (Get-TcSafeProperty $x 'Owner')
                            'Group'           = $(if ([string](Get-TcSafeProperty $x 'GroupId') -notmatch '^(00000000-|$)') { [string](Get-TcProperty $x 'GroupId') })
                            'Teams'           = [bool](Get-TcSafeProperty $x 'IsTeamsConnected' $false)
                            'Hub'             = [bool](Get-TcSafeProperty $x 'IsHubSite' $false)
                            'Hub association' = $(if ([string](Get-TcSafeProperty $x 'HubSiteId') -notmatch '^(00000000-|$)') { [string](Get-TcProperty $x 'HubSiteId') })
                            'Label'           = [string](Get-TcSafeProperty $x 'SensitivityLabel')
                            'Custom scripts'  = ([string](Get-TcSafeProperty $x 'DenyAddAndCustomizePages') -eq 'Disabled')
                            'Language'        = (Get-TcSafeProperty $x 'LocaleId')
                        }
                    })
                Invoke-TcCollectorPart 'Hub sites' {
                    $sites = Get-TcTable 'sites'
                    Add-TcTable 'hubSites' @(foreach ($h in @(Get-PnPHubSite -Connection $script:TcPnpConnection -ErrorAction Stop)) {
                            $id = [string](Get-TcSafeProperty $h 'Id')
                            [ordered]@{
                                'Title'            = (Get-TcProperty $h 'Title')
                                'Url'              = (Get-TcProperty $h 'SiteUrl')
                                'Associated sites' = @($sites | Where-Object { (Get-TcProperty $_ 'Hub association') -eq $id -and (Get-TcProperty $_ 'Url') -ne (Get-TcProperty $h 'SiteUrl') }).Count
                            }
                        })
                }
            }
        }

        @{
            Id       = 'SPO-03'
            Workload = 'SharePoint and OneDrive'
            Title    = 'OneDrive accounts'
            Service  = 'Pnp'
            Collect  = {
                Add-TcTable 'oneDrive' @(foreach ($x in @(Get-PnPTenantSite -IncludeOneDriveSites -Filter "Url -like '-my.sharepoint.com/personal/'" -Connection $script:TcPnpConnection -ErrorAction Stop)) {
                        [ordered]@{
                            'Url'           = (Get-TcProperty $x 'Url')
                            'Owner'         = (Get-TcSafeProperty $x 'Owner')
                            'Storage MB'    = [double](Get-TcSafeProperty $x 'StorageUsageCurrent' 0)
                            'Quota MB'      = [double](Get-TcSafeProperty $x 'StorageQuota' 0)
                            'Last modified' = (Format-TcValue (Get-TcSafeProperty $x 'LastContentModifiedDate'))
                            'Days inactive' = (Get-TcDaysSince (Get-TcSafeProperty $x 'LastContentModifiedDate'))
                            'Lock state'    = [string](Get-TcSafeProperty $x 'LockState')
                        }
                    })
            }
        }

        @{
            Id       = 'SPO-04'
            Workload = 'SharePoint and OneDrive'
            Title    = 'Customizations: templates, scripts, SPFx, assets'
            Service  = 'Pnp'
            Collect  = {
                $c = $script:TcPnpConnection
                Invoke-TcCollectorPart 'Site designs' { Add-TcTable 'sharePointCustomizations' -Append @(foreach ($d in @(Get-PnPSiteDesign -Connection $c -ErrorAction Stop)) {
                            [ordered]@{
                                'Type'   = 'Site design'
                                'Name'   = (Get-TcProperty $d 'Title')
                                'Detail' = [string](Get-TcProperty $d 'WebTemplate')
                            }
                        }) }
                Invoke-TcCollectorPart 'Site scripts' { Add-TcTable 'sharePointCustomizations' -Append @(foreach ($d in @(Get-PnPSiteScript -Connection $c -ErrorAction Stop)) {
                            [ordered]@{
                                'Type'   = 'Site script'
                                'Name'   = (Get-TcProperty $d 'Title')
                                'Detail' = ''
                            }
                        }) }
                Invoke-TcCollectorPart 'Catalog apps (SPFx)' {
                    $apps = @()
                    try { $apps = @(Get-PnPApp -Scope Tenant -Connection $c -ErrorAction Stop) }
                    catch { if ((Get-TcErrorText $_) -match 'ResourceNotFound|tenantappcatalog') { Add-TcCollectorNote 'No tenant app catalog (SPFx): nothing to migrate here.' } else { throw } }
                    Add-TcTable 'sharePointCustomizations' -Append @(foreach ($a in $apps) {
                            [ordered]@{
                                'Type'   = 'SPFx app'
                                'Name'   = (Get-TcProperty $a 'Title')
                                'Detail' = ('deployed {0} - version {1}' -f (Get-TcProperty $a 'Deployed'), (Get-TcProperty $a 'AppCatalogVersion'))
                            }
                        }) }
                Invoke-TcCollectorPart 'Asset libraries' { $o = Get-PnPOrgAssetsLibrary -Connection $c -ErrorAction Stop; if ($o) {
                        Add-TcTable 'sharePointCustomizations' -Append @([ordered]@{
                                'Type'   = 'Asset library'
                                'Name'   = (Format-TcValue $o)
                                'Detail' = ''
                            })
                    } }
                Invoke-TcCollectorPart 'Term store' {
                    Add-TcTable 'termStore' @(foreach ($g in @(Get-PnPTermGroup -Connection $c -ErrorAction Stop)) {
                            $isSystem = [bool](Get-TcSafeProperty $g 'IsSystemGroup' $false) -or [bool](Get-TcSafeProperty $g 'IsSiteCollectionGroup' $false)
                            foreach ($termSet in @(Get-PnPTermSet -TermGroup (Get-TcProperty $g 'Name') -Connection $c -ErrorAction Stop)) {
                                $n = $null; try { $n = @(Get-PnPTerm -TermSet (Get-TcProperty $termSet 'Name') -TermGroup (Get-TcProperty $g 'Name') -Connection $c -ErrorAction Stop).Count } catch { Add-TcCollectorWarning "Terms of $(Get-TcProperty $termSet 'Name')" $_ }
                                [ordered]@{
                                    'Group'                = (Get-TcProperty $g 'Name')
                                    'Term set'             = (Get-TcProperty $termSet 'Name')
                                    'Terms'                = $n
                                    'System or collection' = $isSystem
                                }
                            }
                        })
                }
                if (-not @(Get-TcTable 'sharePointCustomizations').Count) { Add-TcTable 'sharePointCustomizations' @() }
            }
        }

        @{
            Id       = 'SPO-05'
            Workload = 'SharePoint and OneDrive'
            Title    = 'Site and OneDrive usage (Microsoft 365 reports)'
            Service  = 'Graph'
            Collect  = {
                Invoke-TcCollectorPart 'Site usage' {
                    Add-TcTable 'siteUsage' @(foreach ($r in Get-TcUsageReport 'getSharePointSiteUsageDetail' | Where-Object { (Get-TcProperty $_ 'Is Deleted') -ne 'True' }) {
                            [ordered]@{
                                'Url'           = (Get-TcProperty $r 'Site URL')
                                'Owner'         = (Get-TcProperty $r 'Owner Principal Name')
                                'Template'      = (Get-TcProperty $r 'Root Web Template')
                                'Files'         = [long]('0' + (Get-TcProperty $r 'File Count'))
                                'Active files'  = [long]('0' + (Get-TcProperty $r 'Active File Count'))
                                'Storage GB'    = (ConvertTo-TcGigabyte (Get-TcProperty $r 'Storage Used (Byte)'))
                                'Page views'    = [long]('0' + (Get-TcProperty $r 'Page View Count'))
                                'Last activity' = (Get-TcProperty $r 'Last Activity Date')
                            }
                        })
                }
                Invoke-TcCollectorPart 'OneDrive usage' {
                    Add-TcTable 'oneDriveUsage' @(foreach ($r in Get-TcUsageReport 'getOneDriveUsageAccountDetail' | Where-Object { (Get-TcProperty $_ 'Is Deleted') -ne 'True' }) {
                            [ordered]@{
                                'Url'           = (Get-TcProperty $r 'Site URL')
                                'Owner'         = (Get-TcProperty $r 'Owner Principal Name')
                                'Files'         = [long]('0' + (Get-TcProperty $r 'File Count'))
                                'Active files'  = [long]('0' + (Get-TcProperty $r 'Active File Count'))
                                'Storage GB'    = (ConvertTo-TcGigabyte (Get-TcProperty $r 'Storage Used (Byte)'))
                                'Last activity' = (Get-TcProperty $r 'Last Activity Date')
                            }
                        })
                }
            }
        }

        @{
            Id       = 'SPO-06'
            Workload = 'SharePoint and OneDrive'
            Title    = 'Per-site detail: lists and libraries'
            Service  = 'Graph'
            Depth    = 'Complete'
            Requires = @('sites')
            Collect  = {
                $excludedTemplates = '^(REDIRECTSITE|SRCHCEN|SPSMSITEHOST|APPCATALOG|POINTPUBLISHINGHUB|EDISC|SPSPERS|RedirectSite)'
                $sites = @(Limit-TcCollectorRow 'sites' @(Get-TcTable 'sites' | Where-Object { [string](Get-TcProperty $_ 'Template') -notmatch $excludedTemplates }) ([int](Get-TcCollectionSetting 'maxSiteDetails')))
                if (-not $sites.Count) { Add-TcCollectorNote 'No site to detail.'; Add-TcTable 'libraries' @(); return }
                $denied = 0; $n = 0
                Add-TcTable 'libraries' @(foreach ($s in $sites) {
                        $n++
                        if ($n % 25 -eq 0) { Write-TcMessage -Message ('Sites detailed: {0}/{1}' -f $n, $sites.Count) }
                        try {
                            $u = [uri](Get-TcProperty $s 'Url'); $sitePath = (Get-TcProperty $u 'AbsolutePath').TrimEnd('/')
                            $id = (Get-TcProperty (Get-TcGraphObject $(if ($sitePath) { "v1.0/sites/$(Get-TcProperty $u 'Host'):$sitePath`?`$select=id" } else { "v1.0/sites/$(Get-TcProperty $u 'Host')?`$select=id" })) 'id')
                            $drives = @{}; foreach ($d in Get-TcGraphList "v1.0/sites/$id/drives?`$select=name,webUrl,quota") { $drives[[string](Get-TcProperty $d 'webUrl')] = $d }
                            foreach ($l in Get-TcGraphList "v1.0/sites/$id/lists?`$select=displayName,list,lastModifiedDateTime,webUrl&`$top=200") {
                                if ((Get-TcProperty (Get-TcProperty $l 'list') 'hidden')) { continue }
                                $d = $drives[[string](Get-TcProperty $l 'webUrl')]
                                [ordered]@{
                                    'Site'          = (Get-TcProperty $s 'Url')
                                    'List'          = (Get-TcProperty $l 'displayName')
                                    'Template'      = (Get-TcProperty (Get-TcProperty $l 'list') 'template')
                                    'Size MB'       = $(if ($d) { [math]::Round([double](Get-TcProperty (Get-TcProperty $d 'quota') 'used') / 1MB, 1) })
                                    'Last modified' = (Format-TcValue (Get-TcProperty $l 'lastModifiedDateTime'))
                                }
                            }
                        }
                        catch { $denied++; if ($denied -le 3) { Add-TcCollectorWarning "Site detail $(Get-TcProperty $s 'Url')" $_ } }
                    })
                if ($denied) { Add-TcCollectorNote ('{0} of {1} sites could not be read with delegated access: the full detail needs the read-only application (Sites.Read.All) or site collection administrator rights.' -f $denied, $sites.Count) }
            }
        }

        @{
            Id       = 'SPO-07'
            Workload = 'SharePoint and OneDrive'
            Title    = 'SharePoint and OneDrive external users'
            Service  = 'Pnp'
            Collect  = {
                $max = [int](Get-TcCollectionSetting 'maxExternalUsers'); $position = 0; $l = [System.Collections.Generic.List[object]]::new()
                do {
                    try { $page = @(Get-PnPExternalUser -PageSize 50 -Position $position -Connection $script:TcPnpConnection -ErrorAction Stop) }
                    catch { if ($position -gt 0 -and (Get-TcErrorText $_) -match 'position') { break }; throw }  # The next page is empty.
                    foreach ($u in $page) {
                        $l.Add([ordered]@{
                                'Name'        = (Get-TcProperty $u 'DisplayName')
                                'Email'       = (Get-TcProperty $u 'Email')
                                'Accepted as' = (Get-TcProperty $u 'AcceptedAs')
                                'Invited by'  = (Get-TcProperty $u 'InvitedBy')
                                'Created'     = (Format-TcValue (Get-TcProperty $u 'WhenCreated'))
                            })
                    }
                    $position += 50
                } while ($page.Count -eq 50 -and $l.Count -lt $max)
                if ($page.Count -eq 50 -and $l.Count -ge $max) { Add-TcCollectorLimit ('only the first {0} external users were read, there may be more.' -f $l.Count) }
                Add-TcTable 'sharePointExternalUsers' $l
            }
        }

    )
}
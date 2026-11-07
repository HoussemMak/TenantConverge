function Get-TcPurviewCollector {
    <#
    .SYNOPSIS
    Lists the Purview collectors, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @(
        @{
            Id       = 'PUR-01'
            Workload = 'Purview'
            Title    = 'Sensitivity labels and their policies'
            Service  = 'Ipps'
            Collect  = {
                Add-TcTable 'sensitivityLabels' @(foreach ($l in @(Get-Label -ErrorAction Stop)) {
                        $actions = (@((Get-TcProperty $l 'LabelActions')) -join ' ')
                        [ordered]@{
                            'Name'         = (Get-TcProperty $l 'Name')
                            'Display name' = (Get-TcProperty $l 'DisplayName')
                            'Parent'       = [string](Get-TcSafeProperty $l 'ParentId')
                            'Priority'     = (Get-TcProperty $l 'Priority')
                            'Scope'        = (Format-TcValue (Get-TcProperty $l 'ContentType'))
                            'Encryption'   = ([bool](Get-TcSafeProperty $l 'EncryptionEnabled' $false) -or $actions -match '(?i)"Type"\s*:\s*"encrypt"')
                            'Marking'      = ($actions -match '(?i)applycontentmarking|applywatermarking')
                            'Disabled'     = [bool](Get-TcSafeProperty $l 'Disabled' $false)
                        }
                    })
                Invoke-TcCollectorPart 'Label policies' {
                    Add-TcTable 'labelPolicies' @(foreach ($p in @(Get-LabelPolicy -ErrorAction Stop)) {
                            [ordered]@{
                                'Name'      = (Get-TcProperty $p 'Name')
                                'Labels'    = (Format-TcValue (Get-TcProperty $p 'Labels'))
                                'Locations' = (Format-TcValue (@((Get-TcProperty $p 'ExchangeLocation')) + @((Get-TcProperty $p 'ModernGroupLocation'))))
                                'Status'    = [string](Get-TcProperty $p 'DistributionStatus')
                            }
                        })
                }
            }
        }

        @{
            Id       = 'PUR-02'
            Workload = 'Purview'
            Title    = 'Retention: policies and labels'
            Service  = 'Ipps'
            Collect  = {
                Add-TcTable 'retentionPolicies' @(foreach ($p in @(Get-RetentionCompliancePolicy -ErrorAction Stop)) {
                        $locations = @(foreach ($k in 'ExchangeLocation', 'SharePointLocation', 'OneDriveLocation', 'ModernGroupLocation', 'TeamsChannelLocation', 'TeamsChatLocation') { $v = @(Get-TcSafeProperty $p $k); if ($v.Count) { '{0}: {1}' -f ($k -replace 'Location', ''), (Format-TcValue $v) } })
                        [ordered]@{
                            'Name'      = (Get-TcProperty $p 'Name')
                            'Enabled'   = [bool](Get-TcProperty $p 'Enabled')
                            'Mode'      = [string](Get-TcProperty $p 'Mode')
                            'Locations' = ($locations -join ' | ')
                            'Status'    = [string](Get-TcProperty $p 'DistributionStatus')
                        }
                    })
                Invoke-TcCollectorPart 'Retention labels' { Add-TcTable 'retentionLabels' @(foreach ($t in @(Get-ComplianceTag -ErrorAction Stop)) {
                            [ordered]@{
                                'Name'     = (Get-TcProperty $t 'Name')
                                'Action'   = [string](Get-TcProperty $t 'RetentionAction')
                                'Duration' = [string](Get-TcProperty $t 'RetentionDuration')
                                'Record'   = [bool](Get-TcProperty $t 'IsRecordLabel')
                            }
                        }) }
            }
        }

        @{
            Id       = 'PUR-03'
            Workload = 'Purview'
            Title    = 'DLP and eDiscovery cases (holds)'
            Service  = 'Ipps'
            Collect  = {
                Invoke-TcCollectorPart 'DLP policies' { Add-TcTable 'dlpPolicies' @(foreach ($p in @(Get-DlpCompliancePolicy -ErrorAction Stop)) {
                            [ordered]@{
                                'Name'      = (Get-TcProperty $p 'Name')
                                'Mode'      = [string](Get-TcProperty $p 'Mode')
                                'Enabled'   = [bool](Get-TcProperty $p 'Enabled')
                                'Workloads' = (Format-TcValue (Get-TcProperty $p 'Workload'))
                            }
                        }) }
                Invoke-TcCollectorPart 'eDiscovery cases' {
                    Add-TcTable 'ediscoveryCases' @(foreach ($c in @(Get-ComplianceCase -ErrorAction Stop)) {
                            $h = $null; try { $h = @(Get-CaseHoldPolicy -Case (Get-TcProperty $c 'Name') -ErrorAction Stop).Count } catch { Add-TcCollectorWarning "Holds of $(Get-TcProperty $c 'Name')" $_ }
                            [ordered]@{
                                'Name'    = (Get-TcProperty $c 'Name')
                                'Status'  = [string](Get-TcProperty $c 'Status')
                                'Type'    = [string](Get-TcProperty $c 'CaseType')
                                'Holds'   = $h
                                'Created' = (Format-TcValue (Get-TcProperty $c 'CreatedDateTime'))
                            }
                        })
                }
            }
        }

    )
}
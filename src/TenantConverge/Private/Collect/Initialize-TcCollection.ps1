function Initialize-TcCollection {
    <#
    .SYNOPSIS
    Prepares a collection: depth, limits and an empty result.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Complete', 'Standard')][string]$Depth = 'Complete',
        [string]$ProjectName = '',
        [string]$Started = ''
    )

    $script:TcDepth = $Depth
    $script:TcCollectionSettings = @{
        inactiveDays = 90; maxSiteDetails = 800; maxTeamDetails = 600; maxPlannerGroups = 400; maxCallingUsers = 400; maxGroupMemberCounts = 800
        maxInboxRuleMailboxes = 600; maxSignInPages = 8; signInDays = 3; maxPermissionApps = 150; maxPublicFolders = 3000; maxExternalUsers = 2000
        mailboxThresholdGb = 45; siteThresholdGb = 100; oneDriveThresholdGb = 100; secretExpiryDays = 60; reportPeriod = 'D180'; dnsServer = '1.1.1.1'
    }
    $script:TcCollection = [ordered]@{}
    $script:TcCurrentTenant = $null
    $script:TcCurrentCollector = $null
    $script:TcResume = @{}
    $script:TcVerifiedServices = @{}
    $script:TcRunInfo = @{ project = $ProjectName; started = $Started }
    $script:TcLastSave = Get-Date
}

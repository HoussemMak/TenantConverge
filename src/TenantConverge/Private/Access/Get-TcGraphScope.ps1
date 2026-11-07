function Get-TcGraphScope {
    <#
    .SYNOPSIS
    Returns the delegated Graph scopes of the assessment, or the smaller base set used when consent is refused.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('Assessment', 'Base')][string]$Kind
    )

    if ($Kind -eq 'Base') {
        return @(
            'User.Read.All', 'Group.Read.All', 'Domain.Read.All', 'Directory.Read.All', 'Organization.Read.All', 'Policy.Read.All',
            'RoleManagement.Read.Directory', 'UserAuthenticationMethod.Read.All', 'AuditLog.Read.All', 'Reports.Read.All',
            'DeviceManagementServiceConfig.Read.All'
        )
    }

    @(
        'User.Read.All', 'Group.Read.All', 'GroupMember.Read.All', 'Directory.Read.All', 'Domain.Read.All', 'Organization.Read.All',
        'Policy.Read.All', 'RoleManagement.Read.Directory', 'RoleEligibilitySchedule.Read.Directory', 'UserAuthenticationMethod.Read.All', 'AuditLog.Read.All',
        'Reports.Read.All', 'ReportSettings.Read.All', 'Application.Read.All', 'Device.Read.All', 'DeviceManagementManagedDevices.Read.All',
        'DeviceManagementConfiguration.Read.All', 'DeviceManagementApps.Read.All', 'DeviceManagementScripts.Read.All', 'DeviceManagementServiceConfig.Read.All', 'DeviceManagementRBAC.Read.All',
        'Sites.Read.All', 'Team.ReadBasic.All', 'TeamSettings.Read.All', 'Channel.ReadBasic.All', 'AppCatalog.Read.All', 'TeamworkDevice.Read.All',
        'Tasks.Read', 'Bookings.Read.All', 'Community.Read.All', 'SecurityEvents.Read.All', 'OnPremDirectorySynchronization.Read.All',
        'CrossTenantInformation.ReadBasic.All', 'MultiTenantOrganization.Read.All', 'IdentityRiskyUser.Read.All'
    )
}

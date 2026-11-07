function Get-TcApplicationPermission {
    <#
    .SYNOPSIS
    Returns the Graph application permissions of the read-only application.

    .DESCRIPTION
    The delegated scopes of the assessment, plus what application mode needs for Planner, Teams and
    Intune scripts. Every one of them reads.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $equivalents = @{ 'Tasks.Read' = 'Tasks.Read.All' }
    $delegated = foreach ($scope in Get-TcGraphScope -Kind Assessment) {
        if ($equivalents.ContainsKey($scope)) { $equivalents[$scope] } else { $scope }
    }

    @($delegated) + @('ChannelMember.Read.All', 'TeamMember.Read.All', 'ChannelSettings.Read.All', 'DeviceManagementScripts.Read.All', 'Bookings.Read.All') |
        Sort-Object -Unique
}

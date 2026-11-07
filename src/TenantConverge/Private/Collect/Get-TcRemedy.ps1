function Get-TcRemedy {
    <#
    .SYNOPSIS
    Says what to do about a collector that could not collect.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Service,
        [AllowNull()][AllowEmptyString()][string]$Class,
        [string]$Role
    )

    $info = Get-TcServiceInfo $Service

    switch ($Class) {
        'Module missing' { return "Install the module: $($info['Install'])" }
        'Insufficient access' {
            $tenant = if ($Role) { Get-TcProperty $script:TcTenants $Role }
            if ($Service -in 'Exo', 'Ipps' -and (Get-TcApplicationAuth -Tenant $tenant)) {
                return 'This cmdlet is not available to the read-only application (Global Reader role). Microsoft does not support eDiscovery cases in application mode: read them in the Purview portal.'
            }
            if ($info['Access']) { return $info['Access'] }
            return 'Check the roles of the signed-in account (Global Administrator or Global Reader) and the consent to the permissions of the assessment.'
        }
        'Not configured' {
            if ($Service -eq 'Azure') {
                return "With the agreement of the customer, run Initialize-TcAccess -Project <project> -ExtendedAccess Azure, or give the signed-in account the Reader role. A Global Administrator may first have to turn on 'Access management for Azure resources'. If the tenant truly has no subscription, confirm it with the customer."
            }
            if ($script:TcUnattended) {
                return 'This access was not granted to the read-only application. With the agreement of the customer, run Initialize-TcAccess -ExtendedAccess, or run the assessment without -Unattended to get a sign-in window.'
            }
            return 'Without a PnP application, SharePoint is not collected. With a Global Administrator, once per tenant, run Initialize-TcAccess -Project <project> -DelegatedPnP, or -ExtendedAccess SharePoint for the read-only application.'
        }
        'License or service missing' { return 'The service or the license is not in this tenant: nothing to move for this part, or confirm with the customer.' }
        default { return 'Run this workload again with Invoke-TcAssessment -Workload. The details are in journal.log.' }
    }
}

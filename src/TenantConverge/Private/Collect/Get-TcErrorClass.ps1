function Get-TcErrorClass {
    <#
    .SYNOPSIS
    Sorts an error into a class: Not configured, Insufficient access, Module missing, License or service missing, or Failed.

    .DESCRIPTION
    Windows reports some of these errors in the language of the system, so the patterns also match French.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text
    )

    if ($Text -match '^NOTCONFIGURED') { return 'Not configured' }

    if ($Text -match "(?i)403|Forbidden|Authorization_RequestDenied|Insufficient privileges|insufficient_scope|AccessDenied|Access is denied|not authorized|UnauthorizedAccess|\b401\b|Unauthorized|does not have permission|n'est pas autoris|acc.s refus") {
        return 'Insufficient access'
    }

    if ($Text -match "(?i)is not recognized as (a|the) name of a cmdlet|CommandNotFoundException|n'est pas reconnu") {
        # An Exchange or Purview session only exposes the cmdlets of the role: a missing cmdlet is a right, not a module.
        if ($script:TcActive['Exo']) { return 'Insufficient access' }
        return 'Module missing'
    }

    # This class says there is nothing to move, and the plan drops the work. Only words that say a license is
    # lacking earn it: a failed read of the licenses uses the same word. In doubt, Failed shows a gap.
    if ($Text -match '(?i)\b50\d\b|\b429\b|TooManyRequests|Service ?unavailable|Bad ?Gateway|Gateway ?time-?out|Internal Server Error|timed? ?out|try again|temporar') {
        return 'Failed'
    }

    # The word on its own: assignedLicenses, licenseDetails or 'License count' in a message only quote a name.
    $license = '(?<![\w''"$/.=,-])licen[cs]es?(?![\w''"/-])'
    $lacking = "(?:\b(?:no|needs?|requires?|without|missing|lacks?|aucune|sans)\b|(?:does not|doesn't|do not|don't) have)[^.;:]{0,40}$license"
    $wanted = "$license[^.;:]{0,30}\b(?:required|missing|expired|invalid|absente?|manquante?|requise?)\b"
    if ($Text -match "(?i)$lacking|$wanted|not licensed|requires an? .{0,40}(?:subscription|Premium P[12])|SubscriptionNotFound|not provisioned|n'est pas provisionn|Tenant does not have") {
        return 'License or service missing'
    }

    'Failed'
}

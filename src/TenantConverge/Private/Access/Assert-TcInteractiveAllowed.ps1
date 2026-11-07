function Assert-TcInteractiveAllowed {
    <#
    .SYNOPSIS
    Stops a connection that would open a sign-in window during an unattended run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Service,
        [AllowNull()][string]$Domain
    )

    if ($script:TcUnattended) {
        throw "NOTCONFIGURED: $Service for $Domain would open a sign-in window, and this run is unattended. Grant this access to the read-only application with Initialize-TcAccess."
    }
}

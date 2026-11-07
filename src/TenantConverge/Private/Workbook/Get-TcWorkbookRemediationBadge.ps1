function Get-TcWorkbookRemediationBadge {
    <#
    .SYNOPSIS
    Returns Tested or Untested for each remediation of a plan, by identifier.

    .DESCRIPTION
    Tested takes a claim and its evidence. A claim alone reads Untested, the safe side.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    $badges = @{}
    foreach ($item in @(Get-TcProperty $Plan 'remediations' @())) {
        $tested = [bool](Get-TcProperty $item 'testedOnRealTenant') -and [bool](Get-TcProperty $item 'testedEvidence')
        $badges[[string](Get-TcProperty $item 'id')] = if ($tested) { 'Tested' } else { 'Untested' }
    }
    $badges
}

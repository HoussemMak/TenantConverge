function Get-TcRemediation {
    <#
    .SYNOPSIS
    Lists the remediation scripts, their risk, and the notice that they have never run on a real tenant.

    .DESCRIPTION
    UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.

    Reads the manifest and connects to nothing. Each entry gives the identifier, the title, the workload, the
    rules it answers, its nature (Decision, Partial, Report or Automated), its risk, whether it can be
    undone, the permissions it asks for, and whether it removes objects.

    .PARAMETER Id
    One identifier, or a wildcard pattern.

    .PARAMETER Workload
    Keeps one workload, such as 'Entra ID'.

    .PARAMETER Nature
    Keeps one nature.

    .EXAMPLE
    Get-TcRemediation -Workload 'Entra ID' | Format-Table Id, Nature, Risk, Reversible, Notice

    Shows the remediations of Entra ID.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Position = 0)][string]$Id = '*',
        [string]$Workload,
        [ValidateSet('Decision', 'Partial', 'Report', 'Automated')][string]$Nature
    )

    foreach ($entry in (Get-TcRemediationCatalog).Values) {
        if ($entry['id'] -notlike $Id) { continue }
        if ($Workload -and $entry['workload'] -ne $Workload) { continue }
        if ($Nature -and $entry['nature'] -ne $Nature) { continue }
        [pscustomobject]@{
            Id = $entry['id']; Title = $entry['title']; Workload = $entry['workload']; RuleIds = @($entry['ruleIds']); Nature = $entry['nature']; Risk = $entry['risk']; Reversible = $entry['reversible']
            RemovesObjects = [bool]$entry['removesObjects']; Permissions = @($entry['permissions']); AdminRoles = @($entry['roles']); TestedOnRealTenant = $entry['testedOnRealTenant']; TestedEvidence = $entry['testedEvidence']; Notice = $script:TcUntestedNotice
        }
    }
}

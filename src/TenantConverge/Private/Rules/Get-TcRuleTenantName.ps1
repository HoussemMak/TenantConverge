function Get-TcRuleTenantName {
    <#
    .SYNOPSIS
    Returns the display name of a role, or the role itself when the snapshot has no name for it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Role
    )

    $name = Get-TcProperty (Get-TcProperty $script:TcRuleRun['Tenants'] $Role) 'displayName'
    if ($name) { return [string]$name }
    $Role
}

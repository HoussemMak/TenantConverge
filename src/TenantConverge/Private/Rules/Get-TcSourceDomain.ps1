function Get-TcSourceDomain {
    <#
    .SYNOPSIS
    Returns the lowercase custom domains of a tenant: the primary domain and every verified domain.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Role
    )

    $names = @(Get-TcProperty (Get-TcProperty $script:TcRuleRun['Tenants'] $Role) 'primaryDomain')
    $names += @(Get-TcRuleRow $Role 'domains' | Where-Object { Test-TcRowTrue $_ 'Verified' } | ForEach-Object { Get-TcProperty $_ 'Domain' })
    @($names | Where-Object { $_ -and [string]$_ -notmatch '(?i)\.onmicrosoft\.com$' } | ForEach-Object { ([string]$_).ToLowerInvariant() } | Select-Object -Unique)
}

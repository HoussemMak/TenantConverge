function Get-TcRuleLicenseSku {
    <#
    .SYNOPSIS
    Returns the license migrated accounts are expected to get: -LicenseSku, or the most used one of the target.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:TcRuleRun['LicenseSku']) { return $script:TcRuleRun['LicenseSku'] }
    $top = Get-TcRuleRow 'Target' 'licenses' | Sort-Object { Get-TcRowInteger $_ 'Consumed' } -Descending | Select-Object -First 1
    [string](Get-TcProperty $top 'SKU' '')
}

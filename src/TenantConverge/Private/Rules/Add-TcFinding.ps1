function Add-TcFinding {
    <#
    .SYNOPSIS
    Records a finding of the running rule set, with its texts from the catalog.

    .DESCRIPTION
    Role is Target or S1 to S3, Both for a source compared with the target, or All for every tenant. The
    variant defaults to 'target' on the target, when the rule has one. A variant replaces only the fields
    it gives. -Severity is for a rule that computes its severity from what it found.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Id,
        [Parameter(Mandatory, Position = 1)][string]$Role,
        [System.Collections.IDictionary]$Values = @{},
        [AllowNull()][object[]]$Items = @(),
        [string]$Variant,
        [string]$Severity,
        [int]$MaxItems = 300
    )

    $run = $script:TcRuleRun
    $rule = (Get-TcRuleCatalog)[$Id]
    if (-not $rule) { throw "$Id is not in the rule catalog." }

    # Readiness trusts this: a table a rule missed counts against the workload the rule reports on.
    if ($run['Workload'] -and $run['Workload'] -ne $rule['workload']) { throw "$Id reports on $($rule['workload']) from the $($run['Workload']) rules." }

    $variants = Get-TcProperty $rule 'variants' @{}
    if (-not $Variant -and $Role -eq 'Target') { $Variant = 'target' }
    $override = if ($Variant) { Get-TcProperty $variants $Variant @{} } else { @{} }
    $field = { param($Name) Get-TcProperty $override $Name $rule[$Name] }

    $source = $run['Source']
    $code = switch ($Role) { 'Both' { $source } 'All' { 'Consolidation' } default { $Role } }
    $tenant = switch ($Role) {
        'Both' { '{0} to {1}' -f (Get-TcRuleTenantName $source), (Get-TcRuleTenantName 'Target') }
        'All' { 'All tenants' }
        default { Get-TcRuleTenantName $Role }
    }

    $fill = [ordered]@{}
    foreach ($key in $Values.Keys) { $fill[$key] = $Values[$key] }
    if (-not $fill.Contains('tenant')) { $fill['tenant'] = Get-TcRuleTenantName $code }

    $list = @($Items | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { [string]$_ })
    $level = if ($Severity) { $Severity } else { & $field 'severity' }

    $run['Findings'].Add([ordered]@{
            id = $Id; severity = $level; order = @('Critical', 'High', 'Medium', 'Low', 'Info').IndexOf($level)
            workload = $rule['workload']; role = $Role; code = $code; tenant = $tenant; category = & $field 'category'
            title = Format-TcRuleText (& $field 'title') $fill
            finding = Format-TcRuleText (& $field 'finding') $fill
            action = Format-TcRuleText (& $field 'action') $fill
            why = $rule['why']; owner = $rule['owner']; moment = $rule['moment']; effort = $rule['effort']; question = $rule['question']
            items = @($list | Select-Object -First $MaxItems); itemCount = $list.Count
        })
}

function Test-TcTaskCondition {
    <#
    .SYNOPSIS
    Tells whether a task applies to the tenants of its scope.

    .DESCRIPTION
    State is Applies when a condition table has rows or a condition rule fired, in any of the tenants.
    State is Absent when everything was read and nothing calls for the task: the service is not used, or
    the tenant does not have it. State is Unconfirmed when something could not be read, was only partly
    read, or when the rules of the workload stopped: that task stays in the plan, with the reason, because
    a service that was not collected is not a service that is absent.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][object]$Condition,
        [Parameter(Mandatory)][string[]]$Role,
        [Parameter(Mandatory)][hashtable]$Context
    )

    $applies = [pscustomobject]@{ State = 'Applies'; Reason = '' }
    if (-not $Condition) { return $applies }

    $reasons = [System.Collections.Generic.List[string]]::new()
    $dictionary = Get-TcTableDictionary

    foreach ($table in @(Get-TcProperty $Condition 'tables' @())) {
        foreach ($tenant in $Role) {
            $state = Get-TcTableState -Snapshot $Context['Snapshot'] -Role $tenant -Table $table
            if ($state.State -eq 'Collected') { return $applies }
            if ($state.State -eq 'NotFullyRead') {
                $reasons.Add(('{0} was not fully read in {1} ({2}).' -f $dictionary[$table]['label'], $Context['Names'][$tenant], $state.Status))
            }
            if ($state.State -eq 'NotCollected' -and $state.Status -ne 'License or service missing') {
                $reasons.Add(('{0} was not collected in {1} ({2}).' -f $dictionary[$table]['label'], $Context['Names'][$tenant], $state.Status))
            }
        }
    }

    foreach ($rule in @(Get-TcProperty $Condition 'rules' @())) {
        $workload = (Get-TcRuleCatalog)[$rule]['workload']
        foreach ($tenant in $Role) {
            if ($Context['Fired'].Contains("$rule|$tenant") -or $Context['Fired'].Contains("$rule|Consolidation")) { return $applies }
            if (@($Context['Unread'] | Where-Object { $_['role'] -in $tenant, 'All' -and $_['workload'] -eq $workload }).Count) {
                $reasons.Add(('{0} was not fully read in {1}.' -f $workload, $Context['Names'][$tenant]))
            }
            if (@($Context['RuleErrors'] | Where-Object { $_['role'] -in $tenant, 'All' -and $_['workload'] -eq $workload }).Count) {
                $reasons.Add(('The rules of {0} stopped for {1}.' -f $workload, $Context['Names'][$tenant]))
            }
        }
    }

    if ($reasons.Count) { return [pscustomobject]@{ State = 'Unconfirmed'; Reason = (@($reasons | Select-Object -Unique) -join ' ') } }
    [pscustomobject]@{ State = 'Absent'; Reason = '' }
}

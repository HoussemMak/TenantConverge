function Add-TcPlanRemediation {
    <#
    .SYNOPSIS
    Ties the remediation scripts to the plan: each action and task they serve lists them, and the scripts
    linked this way are returned with the fields of the plan contract.

    .DESCRIPTION
    An action is served by a script whose ruleIds hold its rule or its procedure, a task by a script whose
    taskIds hold its template. An action or a task that no script serves does not get the key.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowEmptyCollection()][object[]]$Action = @(),
        [AllowEmptyCollection()][object[]]$Task = @()
    )

    $catalog = Get-TcRemediationCatalog
    $byRule = @{}
    $byTask = @{}
    foreach ($entry in $catalog.Values) {
        foreach ($rule in @($entry['ruleIds'])) {
            if (-not $byRule.ContainsKey($rule)) { $byRule[$rule] = [System.Collections.Generic.List[string]]::new() }
            $byRule[$rule].Add($entry['id'])
        }
        foreach ($template in @($entry['taskIds'])) {
            if (-not $byTask.ContainsKey($template)) { $byTask[$template] = [System.Collections.Generic.List[string]]::new() }
            $byTask[$template].Add($entry['id'])
        }
    }

    $linked = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($row in $Action) {
        $ids = @(@($row['ruleId'], $row['procedure']) | Where-Object { $_ -and $byRule.ContainsKey($_) } | ForEach-Object { $byRule[$_] } | Sort-Object -Unique -Culture 'en-US')
        if (-not $ids.Count) { continue }
        $row['remediations'] = $ids
        foreach ($id in $ids) { [void]$linked.Add($id) }
    }
    foreach ($row in $Task) {
        $ids = @($row['procedure'] | Where-Object { $_ -and $byRule.ContainsKey($_) } | ForEach-Object { $byRule[$_] })
        if ($byTask.ContainsKey($row['templateId'])) { $ids += @($byTask[$row['templateId']]) }
        $ids = @($ids | Sort-Object -Unique -Culture 'en-US')
        if (-not $ids.Count) { continue }
        $row['remediations'] = $ids
        foreach ($id in $ids) { [void]$linked.Add($id) }
    }

    foreach ($entry in @($catalog.Values | Where-Object { $linked.Contains($_['id']) } | Sort-Object -Stable -Culture 'en-US' { $_['id'] })) {
        [ordered]@{
            id = $entry['id']; title = $entry['title']; workload = $entry['workload']; ruleIds = @($entry['ruleIds']); nature = $entry['nature']; risk = $entry['risk']
            reversible = [bool]$entry['reversible']; permissions = @($entry['permissions']); testedOnRealTenant = [bool]$entry['testedOnRealTenant']; testedEvidence = $entry['testedEvidence']
        }
    }
}

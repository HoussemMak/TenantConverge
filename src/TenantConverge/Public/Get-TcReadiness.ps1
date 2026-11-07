function Get-TcReadiness {
    <#
    .SYNOPSIS
    Returns the readiness score of each tenant, and the state of each of its workloads.

    .DESCRIPTION
    The most severe finding of a workload sets its state: Blocking for Critical, To address for High,
    Secondary for Medium, Passed otherwise. Their weights are 0, 0.35, 0.7 and 1. A workload with nothing
    against it reads Not collected, not Passed, when none of its collectors worked or none ran.

    Score is the one to report. It counts every workload the tenant has, and a workload earns its weight
    only if the rules read everything they needed for it, in this tenant and in the target, and none of
    them stopped. Whatever was not read could hide a blocker, so it counts as one, and losing a service
    can never raise Score. A workload whose service the tenant does not have (License or service missing,
    on every collector) leaves the count: there was nothing to read.

    CollectedScore averages the workloads that were read, with no penalty for the others. It says how
    the collected part looks, and it does go up when a bad workload is not collected. Compare it with
    Score to see how much of the picture is missing.

    Findings on all tenants together count for no tenant. A comparison finding counts for its source.

    .PARAMETER Snapshot
    The snapshot, as read from snapshot.json.

    .PARAMETER RuleSet
    The result of Invoke-TcRuleSet on this snapshot. Without it, the rules run first.

    .EXAMPLE
    Get-TcReadiness -Snapshot $snapshot | Format-Table Role, Tenant, Score, CollectedScore

    Shows the score of each tenant.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [System.Collections.IDictionary]$RuleSet
    )

    if (-not $RuleSet) { $RuleSet = Invoke-TcRuleSet -Snapshot $Snapshot }

    $states = [ordered]@{ 'Blocking' = 0.0; 'To address' = 0.35; 'Secondary' = 0.7; 'Passed' = 1.0; 'Not collected' = $null }
    $severities = 'Critical', 'High', 'Medium', 'Low', 'Info'
    $tenants = Get-TcProperty $Snapshot 'tenants'
    $coverage = @(Get-TcProperty $Snapshot 'coverage' @())
    $findings = @(Get-TcProperty $RuleSet 'findings' @())
    $unread = @(Get-TcProperty $RuleSet 'unread' @())
    $errors = @(Get-TcProperty $RuleSet 'errors' @())

    foreach ($role in @('Target', 'S1', 'S2', 'S3' | Where-Object { $tenants.Contains($_) })) {
        $counts = [ordered]@{}
        foreach ($state in $states.Keys) { $counts[$state] = 0 }
        [double]$credit = 0
        [double]$collected = 0
        $applicable = 0
        $read = 0

        $lines = foreach ($workload in $script:TcWorkloads) {
            $rows = @($findings | Where-Object { $_['code'] -eq $role -and $_['workload'] -eq $workload })
            $worst = if ($rows.Count) { (@($rows | ForEach-Object { $severities.IndexOf($_['severity']) }) | Measure-Object -Minimum).Minimum } else { 9 }

            $collectors = @($coverage | Where-Object { (Get-TcProperty $_ 'role') -eq $role -and (Get-TcProperty $_ 'workload') -eq $workload })
            $failed = @($collectors | Where-Object { (Get-TcProperty $_ 'status') -notin 'OK', 'Partial' })
            $absent = @($collectors | Where-Object { (Get-TcProperty $_ 'status') -eq 'License or service missing' })
            $reading = if (-not $collectors.Count) { 'None' }
            elseif ($failed.Count -eq $collectors.Count) { 'Failed' }
            elseif ($failed.Count -or @($collectors | Where-Object { (Get-TcProperty $_ 'status') -eq 'Partial' }).Count) { 'Partial' }
            else { 'OK' }

            $state = switch ($worst) { 0 { 'Blocking' } 1 { 'To address' } 2 { 'Secondary' } default { 'Passed' } }
            if ($state -eq 'Passed' -and $reading -in 'Failed', 'None') { $state = 'Not collected' }

            $missing = @($unread | Where-Object { $_['role'] -eq $role -and $_['workload'] -eq $workload } | ForEach-Object {
                    if ($_['tenantRole'] -eq $role) { $_['table'] } else { "$($_['tenantRole']).$($_['table'])" }
                })
            $stopped = @($errors | Where-Object { (Get-TcProperty $_ 'role') -in $role, 'All' -and (Get-TcProperty $_ 'workload') -eq $workload }).Count
            $weight = $states[$state]
            $isApplicable = -not ($collectors.Count -and $absent.Count -eq $collectors.Count)
            $complete = $state -ne 'Not collected' -and -not $missing.Count -and -not $stopped
            $earned = if ($complete) { $weight } else { 0.0 }

            $counts[$state]++
            if ($isApplicable) { $applicable++; $credit += $earned }
            if ($state -ne 'Not collected') { $read++; $collected += $weight }

            [pscustomobject][ordered]@{
                Workload = $workload; State = $state; Weight = $weight; Credit = $earned; Complete = $complete; Applicable = $isApplicable
                Coverage = $reading; Findings = $rows.Count; Open = @($rows | Where-Object { $_['severity'] -ne 'Info' }).Count; Unread = $missing; RulesStopped = $stopped
            }
        }

        [pscustomobject][ordered]@{
            Role           = $role
            Tenant         = [string](Get-TcProperty $tenants[$role] 'displayName' $role)
            Score          = ConvertTo-TcReadinessScore -Sum $credit -Count $applicable
            CollectedScore = ConvertTo-TcReadinessScore -Sum $collected -Count $read
            States         = $counts
            Workloads      = @($lines)
        }
    }
}

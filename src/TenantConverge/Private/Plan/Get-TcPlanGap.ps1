function Get-TcPlanGap {
    <#
    .SYNOPSIS
    Says what could not be read for one tenant, by workload, as text such as Intune (Insufficient access).

    .DESCRIPTION
    Puts together what the collectors missed and what the rules had to do without. A service the tenant
    does not have is not a gap: there was nothing to read. A tenant no collector reached is one, whole.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [Parameter(Mandatory)][string]$Role
    )

    $lines = @(@(Get-TcProperty $Context['Snapshot'] 'coverage' @()) | Where-Object { (Get-TcProperty $_ 'role') -eq $Role })
    $gaps = [System.Collections.Generic.List[string]]::new()

    foreach ($line in $lines) {
        $status = Get-TcProperty $line 'status'
        if ($status -notin 'OK', 'License or service missing') { $gaps.Add(('{0} ({1})' -f (Get-TcProperty $line 'workload'), $status)) }
    }
    foreach ($row in @($Context['Unread'] | Where-Object { $_['role'] -eq $Role })) { $gaps.Add(('{0} ({1})' -f $row['workload'], $row['status'])) }
    foreach ($row in @($Context['RuleErrors'] | Where-Object { $_['role'] -in $Role, 'All' })) { $gaps.Add(('{0} (rules stopped)' -f $row['workload'])) }

    if (-not $gaps.Count -and -not $lines.Count) { $gaps.Add('everything, no collector ran') }
    @($gaps | Select-Object -Unique)
}

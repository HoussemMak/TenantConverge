function Invoke-TcCollection {
    <#
    .SYNOPSIS
    Collects each tenant, collector by collector, and returns how many collectors were not collected.

    .DESCRIPTION
    On a resume, collectors that ended OK or Partial are kept and the others run again. A tenant of the
    interrupted run that this run leaves out is kept as it was. A partial snapshot is saved after each
    tenant and every few minutes, so a hard stop loses little.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowEmptyString()][string]$Folder = '',
        [Parameter(Mandatory)][string[]]$Role,
        [Parameter(Mandatory)][string[]]$Workload
    )

    $missing = 0

    foreach ($code in @($script:TcResume.Keys | Where-Object { $_ -notin $Role })) { Restore-TcResumedTenant -Role $code -KeepFailed }

    foreach ($code in $Role) {
        $tenant = $script:TcTenants[$code]

        Select-TcCollectionTenant -Role $code
        Restore-TcResumedTenant -Role $code
        $current = $script:TcCurrentTenant

        $done =@($current['coverage'] | ForEach-Object { Get-TcProperty $_ 'id' })
        $collectors = @(Get-TcCollector | Where-Object {
                $_['Workload'] -in $Workload -and ($script:TcDepth -eq 'Complete' -or (Get-TcProperty $_ 'Depth') -ne 'Complete')
            })

        $kind = if ($code -eq 'Target') { 'target tenant' } else { 'source tenant' }
        Write-TcPhase -Title "Assessment of $($current['tenant']) ($kind)" -StepCount $collectors.Count
        if ($done.Count) {
            Write-TcStepLine -Status Info -Text "Resume: $($done.Count) collectors already collected for $($current['tenant']) are kept as they are."
        }

        $isolated = @($collectors | Where-Object { $_['Service'] -in $script:TcIsolatedServices -and $_['Id'] -notin $done })
        $rank = 0
        foreach ($collector in $collectors) {
            $rank++
            if ($collector['Id'] -in $done) { continue }

            if ((Get-Date) - $script:TcLastSave -gt [timespan]::FromMinutes(3)) {
                Save-TcPartialSnapshot -Folder $Folder
                $script:TcLastSave = Get-Date
            }

            if ($collector['Service'] -in $script:TcIsolatedServices) {
                # All the PnP collectors of a tenant run at once, at the place of the first one.
                if ($collector['Id'] -eq $isolated[0]['Id']) {
                    $isolatedIds = @($isolated | ForEach-Object { $_['Id'] })
                    $ranks = @(for ($i = 0; $i -lt $collectors.Count; $i++) { if ($collectors[$i]['Id'] -in $isolatedIds) { $i + 1 } })
                    try {
                        $missing += [int](@(Invoke-TcIsolatedCollector -Collector $isolated -Role $code -Rank $ranks -Total $collectors.Count -Folder $Folder))[-1]
                    }
                    catch {
                        $missing += $isolated.Count
                        Write-TcStepLine -Status Warning -Text "Separate collectors: $(Get-TcErrorText $_)"
                    }
                }
                continue
            }

            $line = Invoke-TcCollector -Collector $collector -Role $code -Rank $rank -Total $collectors.Count
            if ($line['status'] -notin 'OK', 'Partial') { $missing++ }
        }

        if (Get-TcProperty $tenant 'tenantId') { $current['tenantId'] = [string]$tenant['tenantId'] }
        Disconnect-TcService
        Save-TcPartialSnapshot -Folder $Folder
    }

    $missing
}

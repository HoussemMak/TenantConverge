# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the Intune applications of the sources that the target lacks decided (procedure INT-APPS).

.DESCRIPTION
    Starts from the intuneApps tables of the sources and of the target. decisions\INT-APPS.csv: one row per application missing from the
    target, Recreate or Ignore. A package cannot be copied through Graph, so each Recreate row becomes an instruction for a person,
    with an automatic check of its presence.
    Applications are added with no assignment: the target group stays a decision of the device team.
#>
$c = Open-TcRemediation

$targetApps = @{}
foreach ($row in @(Get-TcRemediationTable 'Target' 'intuneApps')) { $targetApps[([string]$row['Name']).ToLowerInvariant()] = $true }

$proposals = @(foreach ($t in @($c.Tenants | Where-Object { $_ -ne 'Target' })) {
        Write-TcRemediationTenant $t
        $apps = @(Get-TcRemediationTable $t 'intuneApps')
        Write-TcRemediationNote ('{0} application(s) in Intune' -f $apps.Count)
        if (-not $apps.Count -and -not (Test-TcCollectionComplete $t 'intuneApps')) { Write-TcRemediationAlert 'Application collection incomplete: run Invoke-TcAssessment again.'; continue }
        foreach ($app in $apps) {
            if ($targetApps.ContainsKey(([string]$app['Name']).ToLowerInvariant())) { continue }
            [ordered]@{ Tenant = $t; Application = [string]$app['Name']; Type = [string]$app['Type']; Proposal = 'Recreate' }
        }
    })

$decisions = @(Get-TcDecision -Name 'INT-APPS' -Proposal $proposals -Key 'Tenant', 'Application' -Choice 'Recreate', 'Ignore')

foreach ($d in @($decisions | Where-Object { $_.Decision -eq 'Recreate' })) {
    Add-TcManualAction -Tenant 'Target' -Object $d.Application -Description ('Add {0} to the Intune of the target' -f $d.Application) -Minutes 1 -IntervalSeconds 20 -Data @{ Name = $d.Application } `
        -Instruction @('Add the application from the Microsoft Store, or package it as a Win32 app, in the same way as the other applications of the target.', 'Leave it with no assignment. The script sees it at the next run.') `
        -WaitUntil { param($a) [bool]@(Invoke-TcGraph -Tenant $a.tenant -Uri 'v1.0/deviceAppManagement/mobileApps?$select=id,displayName' -All | Where-Object { (Get-TcMember $_ 'displayName') -eq $a.data.Name }).Count }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $present = @(Invoke-TcGraph -Tenant $t -Uri 'v1.0/deviceAppManagement/mobileApps?$select=id,displayName' -All | ForEach-Object { Get-TcMember $_ 'displayName' })
    foreach ($d in @($decisions | Where-Object { $_.Decision -eq 'Recreate' })) {
        if ($d.Application -in $present) { New-TcRemediationResult OK ('{0} present in Intune' -f $d.Application) }
        else { New-TcRemediationResult Warning ('{0} missing from Intune' -f $d.Application) }
    }
}
Close-TcRemediation

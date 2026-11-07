# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Reads the secure score of each tenant and the gap with the target (procedure AUT-SECURE-SCORE).

.DESCRIPTION
    Data read: secureScore and securityActions tables of the snapshot. Read only.
    Produces two reports: the score and the gap in percentage points, then the recommended actions for the target. The actions of the
    sources are not carried over: no use investing in a tenant that will go away.
    In an -Apply run, the script reads the last score on each tenant. Running it after each cutover gives the trend.
    Limit: the maximum depends on licenses and active products, the comparison between tenants stays approximate.
#>
$c = Open-TcRemediation

$pctTarget = [double](Get-TcRemediationValue 'Target' 'secureScore' 'Percentage' 0)
$rows = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Secure score'
    $score = Get-TcRemediationValue $t 'secureScore' 'Current score'
    if ($null -eq $score) {
        if (Test-TcCollectionComplete $t 'secureScore') { Write-TcRemediationNote 'No score read' } else { Write-TcRemediationAlert 'Secure score: collection incomplete.' }
        continue
    }
    $max = [double](Get-TcRemediationValue $t 'secureScore' 'Maximum score' 0)
    $pct = if ($max) { [math]::Round(100 * [double]$score / $max, 1) } else { 0 }
    Write-TcRemediationNote ("Score {0} of {1}, or {2} %" -f $score, $max, $pct)
    [ordered]@{ Tenant = $t; Score = $score; Maximum = $max; Percent = $pct; 'Gap with the target (points)' = [math]::Round($pct - $pctTarget, 1); Date = (Get-TcRemediationValue $t 'secureScore' 'Date') }
}
if (@($rows | Where-Object { $_ }).Count) { Export-TcRemediationReport -Name 'secure-score' -Rows @($rows | Where-Object { $_ }) | Out-Null }

if ('Target' -in $c.Tenants) {
    $actions = @(Get-TcRemediationTable 'Target' 'secureScoreActions' | Where-Object { [double]('0' + $_['Possible gain']) -gt 0 } | Sort-Object { - [double]$_['Possible gain'] })
    if ($actions.Count) {
        Export-TcRemediationReport -Name 'recommended-actions-target' -Rows @($actions | ForEach-Object { [ordered]@{ Control = $_['Control']; Category = $_['Category']; 'Possible gain' = $_['Possible gain']; Cost = $_['Cost']; 'User impact' = $_['User impact']; Service = $_['Service'] } }) | Out-Null
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $s = @((Get-TcMember (Invoke-TcGraph -Tenant $t -Uri 'v1.0/security/secureScores?$top=1') 'value')) | Select-Object -First 1
    if (-not $s) { New-TcRemediationResult Warning 'no score returned'; return }
    $p = if ((Get-TcMember $s 'maxScore')) { [math]::Round(100 * (Get-TcMember $s 'currentScore') / (Get-TcMember $s 'maxScore'), 1) } else { 0 }
    New-TcRemediationResult OK ("{0} of {1}, or {2} %, read on {3}" -f (Get-TcMember $s 'currentScore'), (Get-TcMember $s 'maxScore'), $p, (Get-TcMember $s 'createdDateTime'))
}
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Confirms the unified audit log in each tenant and turns it back on if it is off (procedure UNIFIED-AUDIT-LOG).

.DESCRIPTION
    Each action reads the state on the tenant again; if the log is on, it is skipped and nothing is written.
    Turning it on can take 60 minutes: a warning at the check is not a failure.
    No undo: traceability stays useful, even after a rollback.
#>
$c = Open-TcRemediation

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $active = ConvertTo-TcBoolean (Get-TcRemediationValue $t 'exchangeSettings' "Unified audit log enabled")
    Write-TcRemediationNote ("Read: unified audit log {0}" -f $(if ($active) { 'active' } else { 'inactive' }))
    if (-not $active) { Write-TcRemediationAlert "The audit log is read as inactive: it will be turned back on at the -Apply run." }
    Add-TcCommandAction -Tenant $t -Service Exo -Command 'Set-AdminAuditLogConfig' -Parameters @{ UnifiedAuditLogIngestionEnabled = $true } -Object "Unified audit log" `
        -Description "Confirm the unified audit log, turn it back on if it is off" `
        -Reason 'Deliberately not undone: traceability stays useful after a rollback.' `
        -Test { param($a) [bool](Get-TcMember (Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command 'Get-AdminAuditLogConfig') 'UnifiedAuditLogIngestionEnabled') }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ([bool](Get-TcMember (Invoke-TcServiceCommand -Tenant $t -Service Exo -Command 'Get-AdminAuditLogConfig') 'UnifiedAuditLogIngestionEnabled')) { New-TcRemediationResult OK "audit log active" }
    else { New-TcRemediationResult Warning "audit log still inactive: activation can take 60 minutes, run again afterwards" }
}
Close-TcRemediation

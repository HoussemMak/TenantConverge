# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Blocks automatic forwarding to the outside, with validated exceptions only (procedure EXO-AUTO-FORWARD).

.DESCRIPTION
    Depends on the procedure EXO-FORWARDING: while forwardings of this tenant wait for a decision in decisions\EXO-FORWARDING.csv,
    the block is not planned, because it could cut a business flow.
    The mailboxes marked Keep get the exception policy.
#>
$c = Open-TcRemediation

$ExceptionName = (Get-TcObjectName ' - External forwarding exception')
$ForwardingFile = 'EXO-FORWARDING'
$forwardings = if (Test-TcDecisionFile $ForwardingFile) { @(Read-TcDecisionRow $ForwardingFile) } else { @() }

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $ofTenant = @($forwardings | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t })
    $pending = @($ofTenant | Where-Object { -not (Get-TcMember $_ 'Decision') })
    if ($pending.Count) {
        Write-TcRemediationAlert ("{0} forwarding(s) with no decision: block postponed so as not to cut a business flow (EXO-FORWARDING)" -f $pending.Count)
        continue
    }
    if (-not $ofTenant.Count -and @(Get-TcRemediationPlanAction -Procedure 'EXO-FORWARDING' -Tenant $t).Count) {
        Write-TcRemediationAlert 'The forwardings of this tenant have not been reviewed yet: run EXO-FORWARDING first'
        continue
    }
    Add-TcCommandAction -Tenant $t -Service Exo -Command 'Set-HostedOutboundSpamFilterPolicy' -Parameters @{ Identity = 'Default'; AutoForwardingMode = 'Off' } -Object 'Default outbound spam policy' `
        -Description 'Block external automatic forwarding by default' `
        -Test {
            param($a)
            $p = Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command 'Get-HostedOutboundSpamFilterPolicy' -Parameters @{ Identity = 'Default' }
            $a.undo = @{ command = 'Set-HostedOutboundSpamFilterPolicy'; parameters = @{ Identity = 'Default'; AutoForwardingMode = (Get-TcText $p 'AutoForwardingMode') } }
            return (Get-TcText $p 'AutoForwardingMode') -eq 'Off'
        }
    $exceptions = @($ofTenant | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Keep' } | ForEach-Object { (Get-TcMember $_ 'Mailbox') })
    if ($exceptions.Count) {
        Add-TcCommandAction -Tenant $t -Service Exo -Command 'New-HostedOutboundSpamFilterPolicy' -Parameters @{ Name = $ExceptionName; AutoForwardingMode = 'On' } -Object $ExceptionName `
            -Description "Create the exception policy" `
            -Test { param($a) [bool](Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command 'Get-HostedOutboundSpamFilterPolicy' | Where-Object Name -eq (Get-TcObjectName ' - External forwarding exception')) } `
            -Undo @{ command = 'Remove-HostedOutboundSpamFilterPolicy'; parameters = @{ Identity = $ExceptionName } }
        Add-TcCommandAction -Tenant $t -Service Exo -Command 'New-HostedOutboundSpamFilterRule' -Parameters @{ Name = $ExceptionName; HostedOutboundSpamFilterPolicy = $ExceptionName; From = $exceptions } -Object $ExceptionName `
            -Description ("Link the exception to the {0} validated mailbox(es)" -f $exceptions.Count) `
            -Test { param($a) [bool](Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command 'Get-HostedOutboundSpamFilterRule' | Where-Object Name -eq (Get-TcObjectName ' - External forwarding exception')) } `
            -Undo @{ command = 'Remove-HostedOutboundSpamFilterRule'; parameters = @{ Identity = $ExceptionName } }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $p = Invoke-TcServiceCommand -Tenant $t -Service Exo -Command 'Get-HostedOutboundSpamFilterPolicy' -Parameters @{ Identity = 'Default' }
    if ((Get-TcText $p 'AutoForwardingMode') -eq 'Off') { New-TcRemediationResult OK 'external forwarding blocked by default' } else { New-TcRemediationResult Blocking "default policy: $((Get-TcMember $p 'AutoForwardingMode'))" }
}
Close-TcRemediation

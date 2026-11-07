# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Prepares the mail flow test and reports its delivery (procedure MAIL-FLOW-TEST).

.DESCRIPTION
    Sending the test message belongs to the cutover: this script does not send it.
    Before: it checks the test addresses of the remediation settings, one internal and one external, and the sender.
    After, in an -Apply run: it reads the message trace of each recipient. An empty trace does not prove a failure: the trace can lag. It
    also gives the checks only an external mailbox can do.

    Risk to validate in a rehearsal: the test comes before the target accounts are opened, so the sending account is not open yet.
#>
$c = Open-TcRemediation

$Recipients = @((Get-TcRemediationOption 'TestRecipients') | Where-Object { $_ -and $_ -notmatch '^<' })
$accepted = @(Get-TcRemediationTable 'Target' 'acceptedDomains' | ForEach-Object { ([string]$_['Domain']).ToLowerInvariant() })

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $internalItems = @($Recipients | Where-Object { (Get-TcAddressDomain $_) -in $accepted })
    $externalUsers = @($Recipients | Where-Object { (Get-TcAddressDomain $_) -notin $accepted })
    Write-TcRemediationNote ("Test addresses: {0} internal, {1} external" -f $internalItems.Count, $externalUsers.Count)
    if (-not $internalItems.Count -or -not $externalUsers.Count) { Write-TcRemediationAlert 'TestRecipients must hold at least one real internal and one real external address in the remediation settings.' }
    $senderAddress = [string](Get-TcRemediationOption 'TestSender')
    if (-not $senderAddress) {
        $senderAddress = @((Get-TcMember ((@(Get-TcRemediationIdentity $t) | Select-Object -First 1)) 'rows') | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Create' -and (Get-TcMember $_ 'Type') -eq 'User' } | ForEach-Object { (Get-TcMember $_ 'Target UPN') }) | Select-Object -First 1
        Write-TcRemediationNote ("Sender: none in the remediation settings, the first account to create is used: {0}" -f $senderAddress)
    }
    Add-TcManualAction -Tenant $t -Object "External test $t" -Description "Confirm the mail test of $t from the external mailbox" -Instruction @(
        "Confirm that the message Cutover test $t arrived in the external mailbox: the module has no trace for this recipient.",
        'Reply to the migrated address, to test the inbound flow through the new MX.',
        'Read the headers of the message received: Authentication-Results must show spf=pass, dkim=pass and dmarc=pass.',
        'Record the result in the cutover tracking.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $end = Get-Date
    foreach ($d in $Recipients) {
        $traces = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-MessageTraceV2' -Parameters @{ RecipientAddress = $d; StartDate = $end.AddHours(-3); EndDate = $end } | Where-Object { (Get-TcText $_ 'Subject') -like "Cutover test $t*" })
        if (-not $traces.Count) { New-TcRemediationResult Warning "${d}: no trace of the test for 3 hours, message trace can lag" }
        elseif (@($traces | Where-Object { (Get-TcText $_ 'Status') -eq 'Delivered' }).Count) { New-TcRemediationResult OK "${d}: test message delivered" }
        else { New-TcRemediationResult Warning ("{0}: state {1}" -f $d, (($traces | ForEach-Object { (Get-TcText $_ 'Status') } | Select-Object -Unique) -join ', ')) 'Check the MX, the accepted domains and the connectors.' }
    }
}
Close-TcRemediation

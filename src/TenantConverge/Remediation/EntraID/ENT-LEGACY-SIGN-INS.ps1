# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Lists the legacy sign-ins and has the handling of each account decided (procedure ENT-LEGACY-SIGN-INS).

.DESCRIPTION
    Data read: the legacySignIns table of the snapshot, for each tenant of the plan.
    The first preview creates decisions\ENT-LEGACY-SIGN-INS.csv: one row per account and per client, with an owner to name and a
    handling to choose. ENT-LEGACY-AUTH reads this file: no block while a row has no decision.
    The choice Temporary exclusion takes the account out of the block policy; give an owner and a due date in Note.

    In an -Apply run, the script adds a read of the non-interactive sign-ins of the last 30 days (read only, beta API): the snapshot only
    read interactive sign-ins. The accounts found go to a report to carry into the file.

    Limits: the Unknown client does not prove a legacy protocol, it must be qualified; no recent trace does not prove no use, a device
    can serve only once a month.
#>
$c = Open-TcRemediation

$DecisionFile = 'ENT-LEGACY-SIGN-INS'
$DecisionKeys = @('Tenant', 'Account', 'Client')
$UnknownAccount = '(account not resolved)'
$LogDays = 30
$LegacyClients = @('Authenticated SMTP', 'Exchange ActiveSync', 'IMAP4', 'POP3', 'MAPI Over HTTP', 'Exchange Web Services', 'Other clients', 'Outlook Anywhere (RPC over HTTP)', 'Offline Address Book', 'Reporting Web Services', 'AutoDiscover')

$existingItems = Read-TcDecisionEntry -Name $DecisionFile -Key $DecisionKeys

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Legacy sign-ins read'
    $rows = @(Get-TcRemediationTable $t 'legacySignIns')
    if (-not $rows.Count -and -not (Test-TcCollectionComplete $t 'legacySignIns')) { Write-TcRemediationAlert 'Legacy sign-ins: incomplete collection, an empty table proves nothing.' }
    $byClient = @($rows | Group-Object { $_['Client'] } | ForEach-Object { '{0} ({1})' -f (Get-TcMember $_ 'Name'), (Get-TcCount $_) })
    Write-TcRemediationNote ("{0} line(s): {1}" -f $rows.Count, $(if ($byClient) { $byClient -join ', ' } else { 'none' }))
    $noAccount = @($rows | Where-Object { -not $_['UPN'] }).Count
    if ($noAccount) { Write-TcRemediationNote ("{0} row(s) with no resolved account: grouped by client app" -f $noAccount) }
    $groups = $rows | Group-Object { '{0}|{1}' -f $_['UPN'], $_['Client'] }
    foreach ($g in $groups) {
        $l = (@(Get-TcMember $g 'Group') | Select-Object -First 1)
        $client = [string]$l['Client']
        $row = [ordered]@{ Tenant = $t; Account = $(if ($l['UPN']) { $l['UPN'] } else { $UnknownAccount }); Client = $client
                             SignIns = (Get-TcMember (@((Get-TcMember $g 'Group') | ForEach-Object { [int]('0' + $_['Sign-ins']) }) | Measure-Object -Sum) 'Sum')
                             'Last sign-in' = (@((Get-TcMember $g 'Group') | ForEach-Object { [string]$_['Last'] }) | Sort-Object | Select-Object -Last 1)
                             'Device or software' = ''; Owner = ''
                             Proposal = $(if ($client -eq 'Authenticated SMTP') { 'Other sending method' } else { '' }) }
        $before = $existingItems[(Get-TcDecisionKey ([pscustomobject]$row) $DecisionKeys)]
        if ($before) { $row.'Device or software' = (Get-TcMember $before 'Device or software'); $row.Owner = (Get-TcMember $before 'Owner') }
        $row
    }
}

$decisions = @(Get-TcDecision -Name $DecisionFile -Proposal @($proposals | Where-Object { $_ }) -Key $DecisionKeys -Choice 'Modern client', 'Other sending method', 'Replacement', 'Drop', 'Temporary exclusion')
$noOwner = @($proposals | Where-Object { $_ -and -not (Get-TcMember $_ 'Owner') }).Count
if ($noOwner) { Write-TcRemediationNote ("{0} row(s) without an owner: Owner column of {1}.csv" -f $noOwner, $DecisionFile) }
if ($decisions.Count) {
    Export-TcRemediationReport -Name 'monday-plan' -Rows @($decisions | ForEach-Object { [ordered]@{ Tenant = (Get-TcMember $_ 'Tenant'); Account = (Get-TcMember $_ 'Account'); Client = (Get-TcMember $_ 'Client'); Handling = (Get-TcMember $_ 'Decision'); Owner = (Get-TcMember $_ 'Owner'); Note = (Get-TcMember $_ 'Note') } }) | Out-Null
}

foreach ($t in $c.Tenants) {
    Add-TcBlockAction -Tenant $t -Service Graph -Object 'Non-interactive logs' -Description ("Read the non-interactive legacy sign-ins of the last {0} days (read only)" -f $LogDays) `
        -Reason 'Read only.' -Block {
            param($a)
            $since = (Get-TcRemediationNow).ToUniversalTime().AddDays(-$LogDays).ToString('yyyy-MM-ddTHH:mm:ssZ')
            $seen = @{}
            foreach ($client in $LegacyClients) {
                $uri = "beta/auditLogs/signIns?`$filter=createdDateTime ge $since and signInEventTypes/any(t: t eq 'nonInteractiveUser') and clientAppUsed eq '$client'"
                foreach ($s in @(Invoke-TcGraph -Tenant $a.tenant -Uri $uri -All)) {
                    $k = '{0}|{1}' -f (Get-TcMember $s 'userPrincipalName'), (Get-TcMember $s 'clientAppUsed')
                    if (-not $seen[$k]) { $seen[$k] = [ordered]@{ Tenant = $a.tenant; Account = (Get-TcMember $s 'userPrincipalName'); Client = (Get-TcMember $s 'clientAppUsed'); Application = (Get-TcMember $s 'appDisplayName'); SignIns = 0; Last = (Get-TcMember $s 'createdDateTime') } }
                    $seen[$k].SignIns++
                }
            }
            Export-TcRemediationReport -Name "non-interactive-sign-ins-$($a.tenant)" -Rows @($seen.Values) | Out-Null
        }
}

Invoke-TcRemediationPlan
Close-TcRemediation

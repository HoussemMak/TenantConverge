# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Prepares the addresses of the synced target accounts that the cutover cannot write (procedure SYNCED-DUPLICATES).

.DESCRIPTION
    The cutover writes with Set-Mailbox, which Exchange Online refuses on an account synced from on-premises AD. When the address is
    already on the mailbox, there is nothing left to write: this script brings the addresses there before the domains are assigned.

    It produces in exports\:
      - synced-duplicates-<source>.csv: each synced duplicate, its addresses to add, its state;
      - Add-AdAddress-<source>.ps1: a standalone script for the on-premises AD of the target, a preview by default, with a log. Its -Remove
        mode takes the same addresses back in a rollback.

    Decision: decisions\SYNCED-DUPLICATES.csv, one row per source, to settle after the POC.
      On-premises AD   : run the AD script after the domains are verified, then this script watches the addresses arrive in the target mailboxes.
      Cloud attributes : switch the mailboxes to IsExchangeCloudManaged, then the cutover writes on its own. Microsoft does not support this
                         operation in application mode: a person does it, with an interactive sign-in. This script watches the result.
                         Beware of sync: wait for one cycle plus 24 hours after any on-premises change before this switch.

    Once the addresses of the source are frozen in source-addresses.json, the script reads this file rather than the snapshot, and it
    checks with Get-Mailbox: an address visible in Entra is not yet an address in Exchange.

    A Duplicate row with no mailbox in the source has no address to hold, but the cutover would try to write its source UPN. It must go
    to Exclude in the matrix: the script reports it, it does not fix it.

    Before the domains are verified, the script prepares the files and waits for nothing.
#>
$c = Open-TcRemediation

$AdMethod = 'On-premises AD'
$CloudMethod = 'Cloud attributes'
$ExpectedItems = @{}

$AdTemplate = @'
<#
.SYNOPSIS
    Adds the addresses of source {{SOURCE}} to the synced accounts of the target, or removes them (procedure SYNCED-DUPLICATES).

.DESCRIPTION
    Generated on {{DATE}} by SYNCED-DUPLICATES, from the matrix and the addresses of the source.
    Run it on a domain controller or on the Entra Connect server of the target, after the domains are verified in the target: an
    address whose domain is not verified in the target is ignored.

    Without -Apply: a preview, nothing is written. With -Apply: each address is added to proxyAddresses as secondary, in
    lowercase. The primary address is never touched. A Delta sync starts at the end if the ADSync module is there; otherwise,
    start it on the Entra Connect server.
    With -Remove, to go back: the same addresses leave proxyAddresses, still a preview without -Apply. Do this before removing
    the domain from the target. An address that became primary is not removed: it is reported.
    Each line shown also goes to the log, next to this script.

.EXAMPLE
    .\Add-AdAddress-{{SOURCE}}.ps1
    .\Add-AdAddress-{{SOURCE}}.ps1 -Apply
    .\Add-AdAddress-{{SOURCE}}.ps1 -Remove
    .\Add-AdAddress-{{SOURCE}}.ps1 -Remove -Apply
#>
[CmdletBinding()]
param([switch]$Apply, [switch]$Remove, [string]$Log)

$ErrorActionPreference = 'Stop'
if (-not $Log) { $Log = Join-Path $PSScriptRoot ('Add-AdAddress-{{SOURCE}}-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')) }
Import-Module ActiveDirectory

$Accounts = @(
{{DATA}}
)

function Write-Trace {
    param([string]$Text)
    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text
    Write-Host $line
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}

function Find-Account {
    param([string]$Upn)
    $found = @(Get-ADUser -Filter "UserPrincipalName -eq '$Upn'" -Properties proxyAddresses)
    if (-not $found.Count) { $found = @(Get-ADUser -Filter "mail -eq '$Upn'" -Properties proxyAddresses) }
    return $found
}

$added = 0; $present = 0; $notFound = 0; $removed = 0; $absent = 0; $primary = 0
Write-Trace ('Start, mode {0}{1}, {2} account(s)' -f $(if ($Apply) { 'APPLY' } else { 'PREVIEW' }), $(if ($Remove) { ', REMOVE' } else { '' }), $Accounts.Count)
foreach ($entry in $Accounts) {
    $user = @(Find-Account ($entry.Account -replace "'", "''"))
    if ($user.Count -ne 1) { $notFound++; Write-Trace ('NOT FOUND {0}: {1} account(s) found in AD' -f $entry.Account, $user.Count); continue }
    $current = @{}
    foreach ($value in $user[0].proxyAddresses) { $current[($value -replace '^(?i)smtp:', '').ToLowerInvariant()] = [string]$value }
    foreach ($address in $entry.Addresses) {
        if ($Remove) {
            if (-not $current.ContainsKey($address)) { $absent++; Write-Trace ('MISSING   {0}: {1}' -f $entry.Account, $address); continue }
            if ($current[$address] -cmatch '^SMTP:') { $primary++; Write-Trace ('PRIMARY   {0}: {1}, not removed' -f $entry.Account, $address); continue }
            if ($Apply) { Set-ADUser -Identity $user[0].ObjectGUID -Remove @{ proxyAddresses = $current[$address] } }
            $removed++
            Write-Trace ('{0} {1}: {2}' -f $(if ($Apply) { 'REMOVED  ' } else { 'TO REMOVE' }), $entry.Account, $address)
            continue
        }
        if ($current.ContainsKey($address)) { $present++; Write-Trace ('PRESENT   {0}: {1}' -f $entry.Account, $address); continue }
        if ($Apply) { Set-ADUser -Identity $user[0].ObjectGUID -Add @{ proxyAddresses = "smtp:$address" } }
        $added++
        Write-Trace ('{0} {1}: {2}' -f $(if ($Apply) { 'ADDED    ' } else { 'TO ADD   ' }), $entry.Account, $address)
    }
}
if ($Remove) { Write-Trace ('End: {0} address(es) {1}, {2} missing, {3} primary not removed, {4} account(s) not found' -f $removed, $(if ($Apply) { 'removed' } else { 'to remove' }), $absent, $primary, $notFound) }
else { Write-Trace ('End: {0} address(es) {1}, {2} present, {3} account(s) not found' -f $added, $(if ($Apply) { 'added' } else { 'to add' }), $present, $notFound) }
if ($Apply -and ($added -or $removed)) {
    if (Get-Command Start-ADSyncSyncCycle -ErrorAction SilentlyContinue) { Start-ADSyncSyncCycle -PolicyType Delta | Out-Null; Write-Trace 'Delta sync started' }
    else { Write-Trace 'ADSync module missing: run Start-ADSyncSyncCycle -PolicyType Delta on the Entra Connect server' }
}
if ($notFound -or $primary) { exit 1 }
'@

function Get-AdScriptText {
    param([string]$Source, [object[]]$Accounts)
    $named = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
    $data = ($Accounts | ForEach-Object { "    @{{ Account = {0}; Addresses = @({1}) }}" -f (& $named (Get-TcMember $_ 'Account')), (((Get-TcMember $_ 'Addresses') | ForEach-Object { & $named $_ }) -join ', ') }) -join ",`r`n"
    $text = $AdTemplate.Replace('{{SOURCE}}', $Source).Replace('{{DATE}}', (Get-Date -Format 'yyyy-MM-dd HH:mm')).Replace('{{DATA}}', $data)
    $f = Join-Path $c.Folder ("exports/Add-AdAddress-{0}.ps1" -f $Source)
    # with a BOM: Windows PowerShell 5.1, on the domain controller, would misread accents without it
    [System.IO.File]::WriteAllText($f, $text, [System.Text.UTF8Encoding]::new($true))
    return $f
}

function Get-MissingAddress {
    <# Addresses not yet on the target mailboxes, account by account: Exchange, not Entra, because the cutover reads Exchange. #>
    param([object[]]$Accounts)
    $m = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $Accounts) {
        $b = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-Mailbox' -Parameters @{ Identity = (Get-TcMember $e 'Account') }
        $seenItems = @((Get-TcMember $b 'EmailAddresses') | ForEach-Object { ([string]$_ -replace '^(?i)smtp:', '').ToLowerInvariant() })
        foreach ($x in (Get-TcMember $e 'Addresses')) { if ($x -notin $seenItems) { $m.Add("$((Get-TcMember $e 'Account')): $x") } }
    }
    return $m.ToArray()
}

function Test-CloudAttribute {
    param([object[]]$Accounts)
    foreach ($e in $Accounts) {
        if (-not (Get-TcMember (Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-Mailbox' -Parameters @{ Identity = (Get-TcMember $e 'Account') }) 'IsExchangeCloudManaged')) { return $false }
    }
    return $true
}

$target = @{}
foreach ($u in @(Get-TcRemediationTable 'Target' 'users')) { $target[([string]$u['UPN']).ToLowerInvariant()] = @(([string]$u['Addresses'] -split '[;,\s]+') | Where-Object { $_ } | ForEach-Object { ($_ -replace '^(?i)smtp:', '').ToLowerInvariant() }) }

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $mailboxes = @{}
    foreach ($b in @(Get-TcRemediationTable $t 'mailboxes')) { $mailboxes[([string]$b['UPN']).ToLowerInvariant()] = $b }
    $duplicates = @((Get-TcMember ((@(Get-TcRemediationIdentity $t) | Select-Object -First 1)) 'rows') | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Duplicate' })
    $syncedRows = @($duplicates | Where-Object { (Get-TcMember $_ 'Synced') })
    $frozen = Read-TcSourceAddress $t
    if ($null -ne $frozen) { Write-TcRemediationNote 'Addresses read from source-addresses.json: these are the ones the cutover writes when the domains are assigned' }
    $byAccount = [ordered]@{}
    $rows = foreach ($l in $syncedRows) {
        $b = $mailboxes[((Get-TcText $l 'Source UPN')).ToLowerInvariant()]
        $rawRows = if ($null -ne $frozen) { @($frozen[((Get-TcText $l 'Source UPN')).ToLowerInvariant()]) } elseif ($b) { @(([string]$b['Addresses'] -split '[;,\s]+') | Where-Object { $_ } | ForEach-Object { ($_ -replace '^(?i)smtp:', '').ToLowerInvariant() }) } else { @() }
        $addresses = @($rawRows | Where-Object { $_ -and (Get-TcAddressDomain $_) -in (Get-TcMember $i 'Domains') } | Select-Object -Unique)
        $key = ((Get-TcText $l 'Target UPN')).ToLowerInvariant()
        $newOnes = @($addresses | Where-Object { $_ -notin @($target[$key]) })
        foreach ($x in $newOnes) { if (-not $byAccount.Contains($key)) { $byAccount[$key] = [System.Collections.Generic.List[string]]::new() }; if ($x -notin $byAccount[$key]) { $byAccount[$key].Add($x) } }
        [ordered]@{ Source = $t; 'Source account' = (Get-TcMember $l 'Source UPN'); Name = (Get-TcMember $l 'Display name'); 'Target account' = (Get-TcMember $l 'Target UPN'); 'Addresses to add' = ($newOnes -join ' ')
                    'State' = $(if (-not $b) { 'No mailbox in the source: set it to Exclude in the matrix' } elseif ($newOnes.Count) { 'To add' } elseif ($addresses.Count) { 'Already present' } else { 'No address on a migrated domain' }) }
    }
    # a protected account has no place in the matrix: GO-NOGO already reports it, with another remedy
    $noMailbox = @($duplicates | Where-Object { -not $mailboxes[((Get-TcText $_ 'Source UPN')).ToLowerInvariant()] -and -not (Test-TcProtectedAccount (Get-TcMember $_ 'Source UPN') $i) })
    $accounts = @($byAccount.Keys | ForEach-Object { @{ Account = $_; Addresses = @($byAccount[$_]) } })
    $n = (Get-TcMember (@($accounts | ForEach-Object { (Get-TcCount (Get-TcMember $_ 'Addresses')) }) | Measure-Object -Sum) 'Sum')
    Write-TcRemediationNote ("{0} synced duplicate(s): {1} target account(s) receive {2} address(es), {3} duplicate(s) with no mailbox in the source" -f $syncedRows.Count, $accounts.Count, [int]$n, $noMailbox.Count)
    if ($noMailbox.Count) { Write-TcRemediationAlert ("{0} duplicate(s) with no mailbox in the source: the cutover would try to write their source UPN. Set them to Exclude in the matrix, then run New-TcPlan again." -f $noMailbox.Count) }
    [void](Export-TcRemediationReport -Name "synced-duplicates-$t" -Rows @($rows))
    $ExpectedItems[$t] = $accounts
    if ($accounts.Count) {
        Write-TcRemediationNote ("Script for on-premises AD: {0}" -f (Get-AdScriptText -Source $t -Accounts $accounts))
        [ordered]@{ Tenant = $t; Accounts = $accounts.Count; Addresses = [int]$n; Proposal = $AdMethod }
    }
}

$decisions = @(Get-TcDecision -Name 'SYNCED-DUPLICATES' -Proposal @($proposals) -Key 'Tenant' -Choice $AdMethod, $CloudMethod)

$verified = @()
if ($c.Apply) { $verified = @(Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/domains' -All | Where-Object { (Get-TcMember $_ 'isVerified') } | ForEach-Object { (Get-TcMember $_ 'id') }) }

foreach ($t in $c.Tenants) {
    $accounts = @($ExpectedItems[$t])
    if (-not $accounts.Count) { continue }
    $method = (Get-TcMember ($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | Select-Object -First 1) 'Decision')
    if (-not $method) { continue }
    $missing = @((Get-TcMember (Get-TcRemediationTenant $t) 'Domains') | Where-Object { $_ -notin $verified })
    if ($c.Apply -and $missing.Count) {
        Write-TcRemediationAlert ("{0} not verified in the target yet: step {1} comes after the domains are verified. Files ready, nothing to wait for now." -f ($missing -join ', '), $method)
        continue
    }
    if ($method -eq $AdMethod) {
        Add-TcManualAction -Tenant 'Target' -Object "AD addresses $t" -Description ("Add {0} account(s) of {1} in the on-premises AD of the target and wait for them" -f $accounts.Count, $t) -Who 'Team, access to the AD of the target' -Minutes 240 -IntervalSeconds 120 -Instruction @(
            "Copy to a domain controller or the Entra Connect server of the target: $(Join-Path $c.Folder "exports/Add-AdAddress-$t.ps1")",
            "Run it first with no parameter (preview), then with -Apply.",
            'The script watches the mailboxes of the target and goes on as soon as all the addresses arrive.') `
            -WaitUntil {
                param($a)
                $m = @(Get-MissingAddress $ExpectedItems[($a.object -replace '^Adresses AD ', '')])
                if ($m.Count) { Write-TcMessage -Message ("   {0} address(es) not arrived yet" -f $m.Count) }
                return -not $m.Count
            }
    }
    else {
        Add-TcManualAction -Tenant 'Target' -Object "Cloud attributes $t" -Description ("Switch {0} mailbox(es) of {1} to cloud-managed attributes" -f $accounts.Count, $t) -Who 'Exchange administrator, interactive sign-in' -Minutes 240 -IntervalSeconds 120 -Instruction @(
            "Connect to Exchange Online interactively with an administrator account: application mode is not supported for this operation.",
            'For each target account of the synced-duplicates report: Set-Mailbox -Identity <account> -IsExchangeCloudManaged $true',
            'The script watches the result and goes on alone. The cutover then writes the addresses.') `
            -WaitUntil { param($a) Test-CloudAttribute $ExpectedItems[($a.object -replace '^Attributs nuage ', '')] }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $accounts = @($ExpectedItems[$t])
    $method = (Get-TcMember ($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | Select-Object -First 1) 'Decision')
    if (-not $accounts.Count -or $method -ne $AdMethod) { return }
    if (@((Get-TcMember (Get-TcRemediationTenant $t) 'Domains') | Where-Object { $_ -notin $verified }).Count) { New-TcRemediationResult Info 'check skipped: domain not verified in the target yet'; return }
    $m = @(Get-MissingAddress $accounts)
    if ($m.Count) { New-TcRemediationResult Blocking ("{0} address(es) missing from the target" -f $m.Count) 'The cutover will fail on these accounts: run the AD script, then a Delta sync.' $m }
    else { New-TcRemediationResult OK ("all the addresses are on the {0} target account(s)" -f $accounts.Count) }
}
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the single account of each duplicate person confirmed and prepares what duplicates need next (procedure CON-IDENTITIES).

.DESCRIPTION
    Candidates: Duplicate rows of the draft, likely duplicate rows, external accounts of a source (#EXT#) and name matches of the
    plan. decisions\CON-IDENTITIES.csv has one row per source account: Duplicate, Create (same name) or Exclude. The proposed account
    is in the Single account column; another UPN of the target can be entered there, and it stays from one preview to the next.
    An external account with no account in the target cannot be created: it is proposed as Exclude.

    These decisions feed the matrix (IDENTITY-MATRIX, to run again afterwards).

    For confirmed duplicates, it produces two lists in exports\:
      - the mapping for the copy tool (source account to single account);
      - the addresses to add in on-premises AD for the synced accounts of the target. The cutover writes with Set-Mailbox, refused on
        these accounts. Graph only sees these addresses once the domain is verified in the target: run the script again then for the check.

    Limits: matching by name does not tell namesakes apart, only the decision counts. The merge into the mailbox of the single
    account must be validated at the POC. Warn the person that they leave their old account.
#>
$c = Open-TcRemediation

$DecisionName = 'CON-IDENTITIES'
$DecisionKey = @('Tenant', 'Source UPN')

function Get-NameKey {
    param([string]$Name)
    return ((($Name -replace '[\p{Cs}\p{Cn}]', '').Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '' -replace '[^a-zA-Z ]', '').Trim().ToLowerInvariant())
}

function Get-ExternalAddress {
    <# firstname_domain.com#EXT#@source becomes firstname@domain.com: the original address of an external account. #>
    param([string]$Upn)
    if ($Upn -match '^(.+)_([^_]+)#EXT#@') { return ('{0}@{1}' -f $Matches[1], $Matches[2]).ToLowerInvariant() }
    return ''
}

function Get-MigratedAddress {
    <# Addresses of the source on its migrated domains, the ones the single account must receive. #>
    param([string]$Source, [string]$Upn, [string[]]$Domains)
    $b = Get-TcRemediationTable $Source 'mailboxes' | Where-Object { $_['UPN'] -eq $Upn } | Select-Object -First 1
    $u = Get-TcRemediationTable $Source 'users' | Where-Object { $_['UPN'] -eq $Upn } | Select-Object -First 1
    $allItems = @($(if ($b) { ([string]$b['Addresses']) -split ';\s*' }), $(if ($u) { ([string]$u['Addresses']) -split ';\s*' }), $Upn)
    return @($allItems | ForEach-Object { $_ } | Where-Object { $_ -and (Get-TcAddressDomain $_) -in $Domains } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
}

function Test-AddressesVisible {
    <# True when each target account holds its original addresses; false while on-premises AD or the domain is not ready. #>
    param([object[]]$Rows)
    foreach ($g in $Rows | Group-Object 'Target account') {
        $proxy = @((Get-TcMember (Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/users/{0}?`$select=proxyAddresses" -f [uri]::EscapeDataString((Get-TcMember $g 'Name')))) 'proxyAddresses') | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
        foreach ($l in (Get-TcMember $g 'Group')) { if ("smtp:$((Get-TcMember $l 'Address'))" -notin $proxy) { return $false } }
    }
    return $true
}

$sources = @($c.Tenants | Where-Object { $_ -ne 'Target' })
$target = Get-TcRowIndex (Get-TcRemediationTable 'Target' 'users') 'UPN'
$entries = Read-TcDecisionEntry $DecisionName $DecisionKey

$byName = @{}
$codes = @{}
foreach ($s in (Get-TcSourceRole)) { $codes[(Get-TcRemediationTenant $s).Name] = $s }
foreach ($e in (Get-TcMember (Get-TcRemediationPlanAction -Procedure 'CON-IDENTITIES') 'items')) {
    $accounts = @([regex]::Matches([string]$e, '([^,:(]+?) \(([^)\s]+)\)') | ForEach-Object { @{ Name = (Get-TcMember (@(Get-TcMember $_ 'Groups')[1]) 'Value').Trim(); Upn = (Get-TcMember (@(Get-TcMember $_ 'Groups')[2]) 'Value') } })
    $chosenAccount = $accounts | Where-Object { (Get-TcMember $_ 'Name') -eq (Get-TcRemediationTenant 'Target')['Name'] } | Select-Object -First 1
    if ($chosenAccount) { foreach ($x in $accounts | Where-Object { $codes[(Get-TcMember $_ 'Name')] }) { $byName[$x.Upn.ToLowerInvariant()] = (Get-TcMember $chosenAccount 'Upn') } }
}

$proposals = [System.Collections.Generic.List[object]]::new()
$toCreate = [System.Collections.Generic.List[object]]::new()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Duplicate people'
    if ($t -eq 'Target') { Write-TcRemediationNote ("{0} target accounts in the snapshot, including {1} synced with on-premises AD" -f (Get-TcCount $target), @($target.Values | Where-Object { ConvertTo-TcBoolean $_['Synced'] }).Count); continue }
    $users = Get-TcRowIndex (Get-TcRemediationTable $t 'users') 'UPN'
    $n = @{ Draft = 0; SyncedDraft = 0; LikelyOnes = 0; ExternalUsers = 0; Name = 0 }
    foreach ($l in Import-TcMatrixDraft $t) {
        $k = (Get-TcMember $l 'Source UPN').ToLowerInvariant()
        $account = ''
        if ((Get-TcMember $l 'Decision') -eq 'Duplicate') { $account = (Get-TcMember $l 'Target UPN'); $origin = 'Draft'; $n.Draft++ }
        elseif ((Get-TcMember $l 'Notes') -match 'likely duplicate of ([^\s;]+)') { $account = $Matches[1]; $origin = 'Draft, to validate'; $n.LikelyOnes++ }
        elseif ((Get-TcMember $l 'Source UPN') -match '#EXT#') { $x = Get-ExternalAddress (Get-TcMember $l 'Source UPN'); if ($target[$x]) { $account = $target[$x]['UPN'] }; $origin = 'External account'; $n.ExternalUsers++ }
        elseif ($byName[$k]) { $account = $byName[$k]; $origin = 'Match by name'; $n.Name++ }
        else {
            if ((Get-TcMember $l 'Decision') -eq 'Create') { $toCreate.Add(@{ Tenant = $t; Name = (Get-TcMember $l 'Display name') }) }
            continue
        }
        $s = $entries[(Get-TcDecisionKey ([pscustomobject]@{ Tenant = $t; 'Source UPN' = (Get-TcMember $l 'Source UPN') }) $DecisionKey)]
        if ($s -and (Get-TcMember $s 'Single account')) { $account = (Get-TcMember $s 'Single account') }
        $d = if ($account) { $target[$account.ToLowerInvariant()] }
        if ((Get-TcMember $l 'Decision') -eq 'Duplicate' -and $d -and (ConvertTo-TcBoolean $d['Synced'])) { $n.SyncedDraft++ }
        $u = $users[$k]
        # With no mailbox in the source there is no address to assign: the cutover would write an invalid source UPN. Migration team accounts serve the migration.
        $noMailbox = -not @(Get-TcRemediationTable $t 'mailboxes' | Where-Object { $_['UPN'] -eq (Get-TcMember $l 'Source UPN') }).Count
        $proposals.Add([ordered]@{ Tenant = $t; 'Source UPN' = (Get-TcMember $l 'Source UPN'); Name = (Get-TcMember $l 'Display name'); 'Single account' = $account; 'Name in target' = $(if ($d) { $d['Name'] }); 'Synced' = $(if ($d -and (ConvertTo-TcBoolean $d['Synced'])) { 'Yes' } else { 'No' })
                                      'Days inactive' = $(if ($u) { $u['Days inactive'] }); Origin = $origin; Notes = $(if ($noMailbox) { ('{0}; no mailbox in the source' -f (Get-TcMember $l 'Notes')).TrimStart(' ;') } else { (Get-TcMember $l 'Notes') }); Proposal = $(if ($d -and -not $noMailbox -and -not (Test-TcProtectedAccount -Account ((Get-TcText $l 'Source UPN')))) { 'Duplicate' } else { 'Exclude' }) })
    }
    Write-TcRemediationNote ("{0} duplicate(s) of the draft, including {1} targeting a synced account; {2} likely to validate; {3} external account(s); {4} matched by name" -f (Get-TcMember $n 'Draft'), (Get-TcMember $n 'SyncedDraft'), (Get-TcMember $n 'LikelyOnes'), (Get-TcMember $n 'ExternalUsers'), (Get-TcMember $n 'Name'))
}

foreach ($g in $toCreate | Group-Object { Get-NameKey (Get-TcMember $_ 'Name') } | Where-Object { @((Get-TcMember (Get-TcMember $_ 'Group') 'Tenant') | Select-Object -Unique).Count -gt 1 }) {
    Write-TcRemediationAlert ("{0} is to be created from two sources: create the account with the first source to cut over, then Duplicate in the other" -f (Get-TcMember ((@(Get-TcMember $g 'Group') | Select-Object -First 1)) 'Name'))
}

$decisions = @(Get-TcDecision -Name $DecisionName -Proposal @($proposals) -Key $DecisionKey -Choice 'Duplicate', 'Create', 'Exclude')

$AdAddresses = @{}
foreach ($t in $sources) {
    $confirmed = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Duplicate' })
    $validItems = @($confirmed | Where-Object { (Get-TcMember $_ 'Single account') -and $target[(Get-TcMember $_ 'Single account').ToLowerInvariant()] })
    foreach ($d in $confirmed | Where-Object { $_ -notin $validItems }) { Write-TcRemediationAlert ("{0}: single account not found in the target for {1}" -f $t, (Get-TcMember $d 'Source UPN')) }
    if (-not $validItems.Count) { continue }

    $f = Export-TcRemediationReport -Name "mapping-copy-$t" -Rows @($validItems | ForEach-Object { [ordered]@{ Tenant = $t; 'Source account' = (Get-TcMember $_ 'Source UPN'); 'Single account' = (Get-TcMember $_ 'Single account') } })
    Add-TcManualAction -Tenant 'Target' -Object "Mapping plan ($t)" -Description ("Point {0} account(s) of {1} to their single account in the copy tool" -f $validItems.Count, $t) `
        -Instruction @("List: $f", 'To record in the mapping plan of the copy tool, before the pre-copy.')

    $domains = (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')
    $adRows = @(foreach ($d in $validItems | Where-Object { ConvertTo-TcBoolean $target[(Get-TcMember $_ 'Single account').ToLowerInvariant()]['Synced'] }) {
        foreach ($a in Get-MigratedAddress $t (Get-TcMember $d 'Source UPN') $domains) { [ordered]@{ Tenant = $t; 'Target account' = (Get-TcMember $d 'Single account'); 'Source account' = (Get-TcMember $d 'Source UPN'); Address = $a } }
    })
    if (-not $adRows.Count) { continue }
    $f = Export-TcRemediationReport -Name "on-premises-ad-addresses-$t" -Rows $adRows
    $object = "Addresses in on-premises AD ($t)"
    $AdAddresses[$object] = @($adRows | ForEach-Object { [pscustomobject]$_ })
    Add-TcManualAction -Tenant 'Target' -Object $object -Minutes 0 -Description ("Add {0} address(es) of {1} in on-premises AD, on {2} synced account(s)" -f $adRows.Count, $t, @($adRows | ForEach-Object { $_['Target account'] } | Select-Object -Unique).Count) `
        -Instruction @("List: $f", 'These target accounts come from on-premises AD: when the domains are assigned to target accounts, the change goes through Set-Mailbox, which is refused on them. Once the domains are verified in the target, add each address in proxyAddresses (smtp:address) in on-premises AD, then let the synchronization run.', 'To test at the POC. Run the script again: the check passes when Graph sees the addresses.') `
        -WaitUntil { param($a) Test-AddressesVisible $AdAddresses[$a.object] }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $confirmed = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Duplicate' -and (Get-TcMember $_ 'Single account') })
    $missing = @($confirmed | Where-Object { -not @(Invoke-TcGraph -Tenant $t -Uri ("v1.0/users?`$filter=userPrincipalName eq '{0}'&`$select=id" -f [uri]::EscapeDataString((Get-TcMember $_ 'Single account').Replace("'", "''"))) -All).Count })
    if ($missing.Count) { New-TcRemediationResult Blocking ("{0} single account(s) not found in the target" -f $missing.Count) } else { New-TcRemediationResult OK ("{0} single account(s) present in the target" -f $confirmed.Count) }
}
Close-TcRemediation

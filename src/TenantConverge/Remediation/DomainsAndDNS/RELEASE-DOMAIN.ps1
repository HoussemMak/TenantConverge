# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Releases the source from what stays on the domains, before the domains are removed (procedure RELEASE-DOMAIN).

.DESCRIPTION
    Run this script between the release of the UPNs and the removal of the domains. It waits for that moment: until the row UPNs released
    says Done in decisions\CUTOVER-STEPS.csv, it changes nothing, because taking an address off a domain still active bounces the
    mail sent to it.

    It plans, for each source:
      - the initial domain as the default domain: a default domain cannot be removed;
      - the dynamic lists, contacts and mail users still on the domain, read live with Get-Recipient because the snapshot does not give their
        secondary addresses; each object keeps its undo;
      - the accounts with no mailbox that nothing releases: Exchange does not see them and proxyAddresses is read-only.

    Decision: decisions\RELEASE-DOMAIN.csv, one row per account that would stay when the domains are removed.
      Delete        : deletes the account, then removes it from the recycle bin. Irreversible after the purge.
      Forced removal: removes the domain with forceDelete, which renames UPN, mail and proxyAddresses of the remaining accounts, without
                      disabling them. The domain is then already gone. Microsoft limit: 1000 objects.
      Keep          : the domain cannot be removed while the account stays on it.

    Emergency accounts, kept accounts and migration team accounts are never touched: the decision Delete is ignored and the forced
    removal of a domain is refused as soon as it aims at one. A display name held by several accounts gets no proposal: it is handled
    by hand. All the actions are critical: a failure stops the plan before the purge and the forced removal.
    Bookings pages are decided in the matrix (recreate or drop).
#>
$c = Open-TcRemediation

$RemovalMinutes = 60

function Test-AddressesReleased {
    <# True when the row UPNs released says Done: the addresses and UPNs are released, the freeze is in place. #>
    param([string]$Source)
    return (Test-TcCutoverStep -Tenant $Source -Step 'UPNs released')
}

function Test-AddressDomain {
    param([string]$Address, [string[]]$Domains)
    return $Address -match '^(?i)smtp:' -and (Get-TcAddressDomain $Address) -in $Domains
}

function Get-RemainingRecipient {
    param([string]$Tenant, [string[]]$Domains)
    $r = @(Invoke-TcServiceCommand -Tenant $Tenant -Service Exo -Command 'Get-Recipient' -Parameters @{ ResultSize = 'Unlimited'; RecipientType = @('DynamicDistributionGroup', 'MailContact', 'MailUser') })
    return @($r | Where-Object { @((Get-TcMember $_ 'EmailAddresses') | Where-Object { Test-AddressDomain ([string]$_) $Domains }).Count })
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $m = Get-TcRemediationIdentity $t
    Write-TcRemediationNote ("{0} Bookings page(s) to decide in the matrix, handled when mail addresses are released in the source" -f (Get-TcMember $m 'Bookings'))
    Write-TcRemediationNote ("{0} dynamic list(s), {1} contact(s) or mail user(s) read; their addresses are read live during the -Apply run" -f @(Get-TcRemediationTable $t 'dynamicGroups').Count, @(Get-TcRemediationTable $t 'contacts').Count)
    $names = @(Get-TcDomainHolder $t)
    Write-TcRemediationNote ("{0} object(s) would stay on the domains when they are removed from the source" -f $names.Count)
    $users = @(Get-TcRemediationTable $t 'users')
    foreach ($n in $names) {
        $found = @($users | Where-Object { $_['Name'] -eq $n })
        if ($found.Count -gt 1) { Write-TcRemediationAlert "$n is held by $($found.Count) accounts: no proposal, handle by hand."; continue }
        if (-not $found.Count) { Write-TcRemediationAlert "$n stays on the domain and is not an account in the snapshot: handle by hand."; continue }
        $u = $found[0]
        $l = @((Get-TcMember $m 'rows') | Where-Object { (Get-TcMember $_ 'Source UPN') -eq $u['UPN'] }) | Select-Object -First 1
        $over = @(([string]$u['Addresses'] -split '[;,\s]+') + @([string]$u['UPN']) | ForEach-Object { Get-TcAddressDomain $_ } | Where-Object { $_ -in (Get-TcMember $i 'Domains') } | Select-Object -Unique)
        [ordered]@{ Tenant = $t; Account = $u['UPN']; Name = $u['Name']; Id = $u['Id']; Active = $u['Enabled']; Licenses = $u['License count']; Matrix = $(if ($l) { (Get-TcMember $l 'Decision') } else { 'Missing' }); Domains = ($over -join ', ')
                    Proposal = $(if (Test-TcProtectedAccount $u['UPN'] $i) { 'Keep' } elseif ($l -and (Get-TcMember $l 'Decision') -eq 'Exclude') { 'Delete' } else { 'Forced removal' }) }
    }
}
$proposals = @($proposals)
[void](Export-TcRemediationReport -Name 'accounts-without-mailbox' -Rows $proposals)
$decisions = @(Get-TcDecision -Name 'RELEASE-DOMAIN' -Proposal $proposals -Key 'Tenant', 'Account' -Choice 'Delete', 'Forced removal', 'Keep')

foreach ($t in $c.Tenants) {
    $i = Get-TcRemediationTenant $t
    if ($c.Apply -and -not (Test-AddressesReleased $t)) {
        Write-TcRemediationAlert "${t}: the UPNs are not released in the source yet. Nothing is released: run this script at the right moment of the cutover."
        continue
    }

    $defaultValue = @(Get-TcRemediationTable $t 'domains' | Where-Object { $_['Default'] -and $_['Domain'] -in (Get-TcMember $i 'Domains') } | ForEach-Object { $_['Domain'] }) | Select-Object -First 1
    if ($defaultValue) {
        Add-TcGraphAction -Tenant $t -Method PATCH -Uri "v1.0/domains/$((Get-TcMember $i 'InitialDomain'))" -Body @{ isDefault = $true } -Object (Get-TcMember $i 'InitialDomain') -Description "Make $((Get-TcMember $i 'InitialDomain')) the default domain in place of $defaultValue" -Critical `
            -Undo @{ type = 'Graph'; tenant = $t; method = 'PATCH'; uri = "v1.0/domains/$defaultValue"; body = @{ isDefault = $true } } `
            -Test { param($a) [bool](Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri "v1.0/domains/$($a.object)") 'isDefault') }
    }

    Add-TcBlockAction -Tenant $t -Service Exo -Object 'Recipients outside the release step' -Description "Release the dynamic lists, contacts and mail users still on $((Get-TcMember $i 'Domains') -join ', ')" -Critical `
        -Data @{ Domains = @((Get-TcMember $i 'Domains')); Initial = (Get-TcMember $i 'InitialDomain') } `
        -Test {
            param($a)
            $a.data.Remaining = @(Get-RemainingRecipient -Tenant $a.tenant -Domains $a.data.Domains)
            return -not $a.data.Remaining.Count
        } `
        -Block {
            param($a)
            $commands = @{ DynamicDistributionGroup = 'Set-DynamicDistributionGroup'; MailContact = 'Set-MailContact'; MailUser = 'Set-MailUser' }
            $domains = @($a.data.Domains); $initial = $a.data.Initial
            $undos = [System.Collections.Generic.List[object]]::new()
            $failures = [System.Collections.Generic.List[string]]::new()
            foreach ($r in $a.data.Remaining) {
                $name = (Get-TcText $r 'PrimarySmtpAddress')
                $command = $commands[(Get-TcText $r 'RecipientType')]
                if ((Get-TcAddressDomain ((Get-TcText $r 'ExternalEmailAddress'))) -in $domains) { $failures.Add("${name}: external address on the domain, to fix by hand"); continue }
                $before = @((Get-TcMember $r 'EmailAddresses') | ForEach-Object { [string]$_ })
                $kept = @($before | Where-Object { -not (Test-AddressDomain $_ $domains) })
                if (-not @($kept | Where-Object { $_ -cmatch '^SMTP:' }).Count) {
                    $resume = @($kept | Where-Object { $_ -match '^(?i)smtp:' -and (Get-TcAddressDomain $_) -eq $initial }) | Select-Object -First 1
                    if ($resume) { $kept = @($kept | ForEach-Object { if ($_ -eq $resume) { 'SMTP:' + ($_ -replace '^(?i)smtp:', '') } else { $_ } }) }
                    else { $kept += 'SMTP:{0}@{1}' -f (Get-TcAddressPrefix $name), $initial }
                }
                try {
                    Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command $command -Parameters @{ Identity = (Get-TcText $r 'Guid'); EmailAddresses = $kept } | Out-Null
                    $undos.Add(@{ tenant = $a.tenant; service = 'Exo'; command = $command; parameters = @{ Identity = (Get-TcText $r 'Guid'); EmailAddresses = $before } })
                }
                catch { $failures.Add(("{0}: {1}" -f $name, (Get-TcErrorText $_))) }
            }
            $a.undo = $undos.ToArray()
            if ($failures.Count) { throw ("{0} recipient(s) not released out of {1}: {2}" -f $failures.Count, @($a.data.Remaining).Count, ($failures -join ' ; ')) }
        }

    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Delete' }) {
        if (Test-TcProtectedAccount (Get-TcMember $d 'Account') $i) { Write-TcRemediationAlert ("{0} is a protected account: decision Delete ignored" -f (Get-TcMember $d 'Account')); continue }
        Add-TcGraphAction -Tenant $t -Method DELETE -Uri "v1.0/users/$((Get-TcMember $d 'Id'))" -Object (Get-TcMember $d 'Account') -Description "Delete the account $((Get-TcMember $d 'Account'))" -Critical `
            -Undo @{ type = 'Graph'; tenant = $t; method = 'POST'; uri = "v1.0/directory/deletedItems/$((Get-TcMember $d 'Id'))/restore" } `
            -Test { param($a) Test-TcGraphAbsent -Tenant $a.tenant -Uri $a.uri }
        Add-TcGraphAction -Tenant $t -Method DELETE -Uri "v1.0/directory/deletedItems/$((Get-TcMember $d 'Id'))" -Object (Get-TcMember $d 'Account') -Description "Remove $((Get-TcMember $d 'Account')) from the recycle bin" -Critical `
            -Reason 'Final purge: a deleted account keeps its reference to the domain while it is in the recycle bin.' `
            -Test { param($a) Test-TcGraphAbsent -Tenant $a.tenant -Uri $a.uri }
    }

    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Keep' }) { Write-TcRemediationAlert ("{0} stays on {1}: the domain removal stops while this account is there" -f (Get-TcMember $d 'Account'), (Get-TcMember $d 'Domains')) }

    $forced = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Forced removal' })
    foreach ($n in @($forced | ForEach-Object { (Get-TcMember $_ 'Domains') -split ',\s*' } | Where-Object { $_ } | Select-Object -Unique)) {
        $aimedAt = @($forced | Where-Object { $n -in ((Get-TcMember $_ 'Domains') -split ',\s*') })
        $protected = @($aimedAt | Where-Object { Test-TcProtectedAccount (Get-TcMember $_ 'Account') $i } | ForEach-Object { (Get-TcMember $_ 'Account') })
        if ($protected.Count) { Write-TcRemediationAlert ("Forced removal of {0} refused: it would rename {1}, protected account(s)" -f $n, ($protected -join ', ')); continue }
        Add-TcBlockAction -Tenant $t -Service Graph -Object $n -Description "Forced removal of ${n}: renames the remaining accounts without disabling them" -Critical `
            -Data @{ Domain = $n; Accounts = @($aimedAt | ForEach-Object { (Get-TcMember $_ 'Id') }) } `
            -Reason 'The domain leaves the source: to go back, add it back to the source and rename the accounts.' `
            -Test { param($a) -not (Test-TcTenantDomain -Tenant $a.tenant -Domain $a.data.Domain) } `
            -Block {
                param($a)
                $n = $a.data.Domain
                $refs = @(Invoke-TcGraph -Tenant $a.tenant -Uri "v1.0/domains/$n/domainNameReferences" -All)
                $others = @($refs | Where-Object { (Get-TcMember $_ 'id') -notin $a.data.Accounts })
                if ($others.Count) { throw ("{0}: {1} reference(s) outside the decisions, forced removal refused: {2}" -f $n, $others.Count, (($others | ForEach-Object { (Get-TcMember $_ 'displayName') }) -join ', ')) }
                $info = Get-TcRemediationTenant $a.tenant
                $liveItems = @($refs | Where-Object { Test-TcProtectedAccount ((Get-TcText $_ 'userPrincipalName')) $info })
                if ($liveItems.Count) { throw ("{0}: forced removal refused, protected account(s) on the domain: {1}" -f $n, (($liveItems | ForEach-Object { (Get-TcMember $_ 'userPrincipalName') }) -join ', ')) }
                Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri "v1.0/domains/$n/forceDelete" -Body @{ disableUserAccounts = $false } | Out-Null
                $end = (Get-TcRemediationNow).AddMinutes($RemovalMinutes)
                while (Test-TcTenantDomain -Tenant $a.tenant -Domain $n) {
                    if ((Get-TcRemediationNow) -ge $end) { throw "$n still present after $RemovalMinutes minutes: the operation goes on, run again later." }
                    Wait-TcRemediation -Seconds 30
                }
            }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if (-not (Test-AddressesReleased $t)) { New-TcRemediationResult Info 'check skipped: the UPNs are not released in the source yet'; return }
    foreach ($d in (Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) {
        if (-not (Test-TcTenantDomain -Tenant $t -Domain $d)) { New-TcRemediationResult OK "${d}: already removed from the source"; continue }
        $refs = @(Invoke-TcGraph -Tenant $t -Uri "v1.0/domains/$d/domainNameReferences" -All)
        if ($refs.Count) { New-TcRemediationResult Blocking ("{0}: still {1} reference(s): {2}" -f $d, $refs.Count, (($refs | Select-Object -First 8 | ForEach-Object { (Get-TcMember $_ 'displayName') }) -join ', ')) }
        else { New-TcRemediationResult OK "${d}: no reference, the domain can be removed" }
    }
}
Close-TcRemediation

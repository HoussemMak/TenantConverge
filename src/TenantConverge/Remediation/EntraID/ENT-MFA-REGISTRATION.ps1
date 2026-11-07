# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Prepares the MFA registration: list of accounts, chosen method, campaign and Temporary Access Pass (procedure ENT-MFA-REGISTRATION).

.DESCRIPTION
    Data read: the list of enabled accounts with no method (plan), mailboxes, licenses and methods read.
    The first preview creates two files:
      - decisions\ENT-MFA-REGISTRATION.csv: one account per row, Register or Remove. Shared mailboxes, rooms, sync accounts and
        protected accounts are proposed for removal;
      - decisions\ENT-MFA-REGISTRATION-METHOD.csv: the method chosen by the customer. The campaign waits for this decision.
    Once the method is decided, and not before, the script enables it in the target if it is off, sets the Temporary Access Pass
    (one use, 60 minutes) and starts the campaign. Emergency, sync and migration team accounts are excluded from the campaign.

    Limits:
      - the campaign only prompts accounts that already do MFA: it does not reach accounts with no method, a direct message is still
        needed. That message belongs to the customer;
      - the Temporary Access Pass is a secret: the script never creates it, because it would have to show or write it.

    ENT-MFA refuses to enable the policy while the accounts file has rows with no decision.
    Run for a source (CUT-03): no write, only the list of accounts and the support instruction.
#>
$c = Open-TcRemediation

$PolicyUri = 'v1.0/policies/authenticationMethodsPolicy'
$MethodUri = "$PolicyUri/authenticationMethodConfigurations"
$PostponeDays = 1
$PassMinutes = 60
$RegistrationPage = 'https://aka.ms/mysecurityinfo'
$SyncRole = 'Directory Synchronization Accounts'
$MailboxTypesWithNoSignIn = @('SharedMailbox', 'RoomMailbox', 'EquipmentMailbox', 'SchedulingMailbox')

function Get-SyncAccount {
    param([string]$Tenant)
    return @(Get-TcRemediationTable $Tenant 'adminRoles' | Where-Object { $_['Role'] -eq $SyncRole } | ForEach-Object { $_['Principal'] } | Select-Object -Unique)
}

function Get-AccountProposal {
    <# A heuristic: the decision stays with the customer. An account with no mailbox and no license: to qualify, often a service account. #>
    param([string]$Account, [string]$MailboxType, $Licenses, [string[]]$Sync)
    if ($Account -in $Sync -or (Test-TcProtectedAccount -Account $Account)) { return 'Remove' }
    if ($MailboxType -in $MailboxTypesWithNoSignIn) { return 'Remove' }
    if ($MailboxType -or [int]('0' + $Licenses) -gt 0) { return 'Register' }
    return ''
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Accounts with no MFA method'
    $items = @(Get-TcRemediationPlanAction -Procedure 'ENT-MFA-REGISTRATION' -Tenant $t | ForEach-Object { (Get-TcMember $_ 'items') } | Where-Object { $_ })
    Write-TcRemediationNote ("{0} active account(s) with no MFA method registered" -f $items.Count)
    if (-not $items.Count -and -not (Test-TcCollectionComplete $t 'mfaRegistrations')) { Write-TcRemediationAlert 'MFA registrations: incomplete collection, an empty list proves nothing.' }
    $mailboxes = @{}; foreach ($b in Get-TcRemediationTable $t 'mailboxes') { $mailboxes[([string]$b['UPN']).ToLowerInvariant()] = [string]$b['Type'] }
    $accounts = @{}; foreach ($u in Get-TcRemediationTable $t 'users') { $accounts[([string]$u['UPN']).ToLowerInvariant()] = $u }
    $sync = Get-SyncAccount $t
    foreach ($e in $items) {
        $k = ([string]$e).ToLowerInvariant()
        $u = $accounts[$k]
        [ordered]@{ Tenant = $t; Account = $e; Name = $(if ($u) { $u['Name'] }); 'Mailbox type' = $(if ($mailboxes[$k]) { $mailboxes[$k] } else { 'None' })
                    Licenses = $(if ($u) { $u['License count'] }); 'Days inactive' = $(if ($u) { $u['Days inactive'] })
                    Proposal = (Get-AccountProposal $e $mailboxes[$k] $(if ($u) { $u['License count'] }) $sync) }
    }
}

$decisions = @(Get-TcDecision -Name 'ENT-MFA-REGISTRATION' -Proposal @($proposals | Where-Object { $_ }) -Key 'Tenant', 'Account' -Choice 'Register', 'Remove')
$removedItems = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Remove' } | ForEach-Object { '{0}|{1}' -f (Get-TcMember $_ 'Tenant'), (Get-TcMember $_ 'Account') })
$toJoin = @($proposals | Where-Object { $_ -and ('{0}|{1}' -f (Get-TcMember $_ 'Tenant'), (Get-TcMember $_ 'Account')) -notin $removedItems })
if ($toJoin.Count) { Export-TcRemediationReport -Name 'accounts-to-register' -Rows @($toJoin | ForEach-Object { [ordered]@{ Tenant = (Get-TcMember $_ 'Tenant'); Account = (Get-TcMember $_ 'Account'); Name = (Get-TcMember $_ 'Name'); 'Mailbox type' = (Get-TcMember $_ 'Mailbox type') } }) | Out-Null }

$methodProposals = foreach ($t in @($c.Tenants | Where-Object { $_ -eq 'Target' })) {
    [ordered]@{ Tenant = $t; 'Microsoft Authenticator (read)' = (Get-TcRemediationValue $t 'securitySettings' 'MicrosoftAuthenticator method'); 'Passkey (read)' = (Get-TcRemediationValue $t 'securitySettings' 'Fido2 method')
                Proposal = 'Microsoft Authenticator' }
}
$methods = @(Get-TcDecision -Name 'ENT-MFA-REGISTRATION-METHOD' -Proposal @($methodProposals | Where-Object { $_ }) -Key 'Tenant' -Choice 'Microsoft Authenticator', 'Passkey')

foreach ($t in $c.Tenants) {
    $n = @($toJoin | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t }).Count
    if ($t -ne 'Target') {
        Add-TcManualAction -Tenant $t -Object 'Monday support' -Description ("Plan level 1 support for the {0} account(s) to register in the target after the cutover" -f $n) -Who 'Team' `
            -Instruction @('MFA methods do not migrate: migrated accounts register in the target.', 'Temporary access passes are handed out when the target accounts are opened; plan level 1 support for the Monday of the cutover.', 'List: exports\accounts-to-register.csv in the log folder.')
        continue
    }
    Add-TcManualAction -Tenant $t -Object 'Message to accounts' -Description ("Send the registration message to the {0} account(s) on the list" -f $n) -Who 'Customer' `
        -Instruction @('The campaign does not reach accounts with no method: the direct message remains essential.', ("Send the approved message, with the link {0} and the deadline, to the accounts in exports\accounts-to-register.csv." -f $RegistrationPage))

    $m = $methods | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | Select-Object -First 1
    if (-not $m) { Write-TcRemediationAlert 'Targeted method not decided: the campaign waits for decisions\ENT-MFA-REGISTRATION-METHOD.csv.' }
    else {
        $authenticator = (Get-TcMember $m 'Decision') -eq 'Microsoft Authenticator'
        $methodId = if ($authenticator) { 'MicrosoftAuthenticator' } else { 'Fido2' }
        $backup = [string](Get-TcRemediationValue $t 'securitySettings' "Method $methodId")
        Write-TcRemediationNote ("Chosen method: {0}; state read: {1}" -f (Get-TcMember $m 'Decision'), $backup)
        $methodBody = if ($authenticator) { @{ '@odata.type' = '#microsoft.graph.microsoftAuthenticatorAuthenticationMethodConfiguration'; state = 'enabled' } }
                        else { @{ '@odata.type' = '#microsoft.graph.fido2AuthenticationMethodConfiguration'; state = 'enabled'; isSelfServiceRegistrationAllowed = $true } }
        Add-TcGraphAction -Tenant $t -Method PATCH -Uri "$MethodUri/$methodId" -Body $methodBody -Object "Method $methodId" `
            -Description ("Enable the {0} method in the authentication methods policy" -f (Get-TcMember $m 'Decision')) `
            -Test { param($a) (Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri $a.uri) 'state') -eq 'enabled' }

        Add-TcBlockAction -Tenant $t -Service Graph -Object 'Registration campaign' -Description ("Start the registration campaign, method {0}, postponement of {1} day(s)" -f (Get-TcMember $m 'Decision'), $PostponeDays) `
            -Data @{ Target = $(if ($authenticator) { 'microsoftAuthenticator' } else { 'fido2' }); ExcludedItems = @(@(Get-SyncAccount $t) + @(Get-TcRemediationTable $t 'users' | Where-Object { (Test-TcProtectedAccount -Account ([string]$_['UPN'])) } | ForEach-Object { $_['UPN'] })) } `
            -Test {
                param($a)
                $x = (Get-TcMember (Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri $PolicyUri) 'registrationEnforcement') 'authenticationMethodsRegistrationCampaign')
                return (Get-TcMember $x 'state') -eq 'enabled' -and @((Get-TcMember $x 'includeTargets') | Where-Object { (Get-TcMember $_ 'targetedAuthenticationMethod') -eq $a.data.Target }).Count -gt 0
            } `
            -Block {
                param($a)
                $before = (Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri $PolicyUri) 'registrationEnforcement')
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'PATCH'; uri = $PolicyUri; body = @{ registrationEnforcement = $before } }
                $excludedItems = foreach ($u in @(Get-TcEmergencyAccount) + @($a.data.ExcludedItems)) {
                    $l = @(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users?`$filter=userPrincipalName eq '{0}'&`$select=id" -f [uri]::EscapeDataString($u)) -All)
                    if ($l.Count) { @{ id = (Get-TcMember $l[0] 'id'); targetType = 'user' } }
                }
                $campaign = @{ state = 'enabled'; snoozeDurationInDays = $PostponeDays; enforceRegistrationAfterAllowedSnoozes = $true; excludeTargets = @($excludedItems | Where-Object { $_ })
                               includeTargets = @(@{ id = 'all_users'; targetType = 'group'; targetedAuthenticationMethod = $a.data.Target }) }
                Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri $PolicyUri -Body @{ registrationEnforcement = @{ authenticationMethodsRegistrationCampaign = $campaign } }
            }
    }

    if (-not $m) { continue }
    Add-TcGraphAction -Tenant $t -Method PATCH -Uri "$MethodUri/TemporaryAccessPass" -Object 'Temporary Access Pass' `
        -Body @{ '@odata.type' = '#microsoft.graph.temporaryAccessPassAuthenticationMethodConfiguration'; isUsableOnce = $true; defaultLifetimeInMinutes = $PassMinutes } `
        -Description ("Set the Temporary Access Pass: single use, {0} minutes" -f $PassMinutes) `
        -Test { param($a) $p = Invoke-TcGraph -Tenant $a.tenant -Uri $a.uri; (Get-TcMember $p 'isUsableOnce') -and (Get-TcMember $p 'defaultLifetimeInMinutes') -eq 60 }

    Add-TcManualAction -Tenant $t -Object 'Hard cases' -Description 'Hand out a Temporary Access Pass to the hard cases' -Who 'Team' `
        -Instruction @('Create the pass in Entra ID > Users > account > Authentication methods, after verifying the identity.', 'Hand it over through a secure channel. Never write it in a report, an ordinary email or a log.')
    Add-TcManualAction -Tenant $t -Object 'Last accounts' -Description 'Have the handling of the last accounts decided before enabling ENT-MFA' -Who 'Customer' `
        -Instruction @('Run this script again: the check gives the number of remaining accounts.', 'The customer decides how to handle the last accounts. ENT-MFA waits for these decisions to enable the policy.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $list = @(@($proposals | Where-Object { $_ -and ('{0}|{1}' -f (Get-TcMember $_ 'Tenant'), (Get-TcMember $_ 'Account')) -notin $removedItems }) | ForEach-Object { (Get-TcMember $_ 'Account') })
    $noMethod = @(Invoke-TcGraph -Tenant $t -Uri "v1.0/reports/authenticationMethods/userRegistrationDetails?`$filter=isMfaRegistered eq false" -All | ForEach-Object { (Get-TcMember $_ 'userPrincipalName') })
    $remaining = @($list | Where-Object { $_ -in $noMethod })
    Export-TcRemediationReport -Name 'remaining-accounts' -Rows @($remaining | ForEach-Object { [ordered]@{ Tenant = $t; Account = $_ } }) | Out-Null
    New-TcRemediationResult $(if ($remaining.Count) { 'Info' } else { 'OK' }) ("{0} account(s) out of {1} still with no method" -f $remaining.Count, $list.Count)
    $x = (Get-TcMember (Get-TcMember (Invoke-TcGraph -Tenant $t -Uri $PolicyUri) 'registrationEnforcement') 'authenticationMethodsRegistrationCampaign')
    if ((Get-TcMember $x 'state') -eq 'enabled') { New-TcRemediationResult OK 'registration campaign active' } else { New-TcRemediationResult Warning "registration campaign: $((Get-TcMember $x 'state'))" }
}
Close-TcRemediation

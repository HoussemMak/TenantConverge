# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Reinvites to the target the external users validated by site owners (procedure SPO-EXTERNAL).

.DESCRIPTION
    Reads spoExternalUsers: the address is in Accepted as, because the Email column is empty in the snapshot.
    An invitation can send an email to a real person: the decision is taken row by row in decisions\SPO-EXTERNAL.csv:
      Invite with email    : Microsoft sends the invitation;
      Invite without email : the guest account is created, with no message;
      Do not invite        : nothing is done.
    Nothing is sent without a decision. An address already in the target, or in an internal domain, is proposed as Do not invite: one
    guest per person. The Note column can give the address of the site to redirect the guest to.
    An action applies to the target.
    Limit: access to the site, library or folder stays to be given back by the owner, then confirmed. The snapshot does not say which
    sites each external user could reach.
#>
$c = Open-TcRemediation

function Get-TargetAccountValue {
    param([string]$Address)
    $f = $Address -replace "'", "''"
    return (@(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/users?`$filter=mail eq '{0}'&`$select=id,mail,userType" -f $f) -All) | Select-Object -First 1)
}

$inTargetTenant = @{}
foreach ($u in Get-TcRemediationTable 'Target' 'users') { foreach ($x in @($u['Email'], $u['UPN'])) { if ($x) { $inTargetTenant[([string]$x).ToLowerInvariant()] = [string]$u['Type'] } } }
$internalDomains = @(foreach ($t in (Get-TcProjectRole)) { Get-TcRemediationTable $t 'domains' | ForEach-Object { ([string]$_['Domain']).ToLowerInvariant() } })
$redirect = 'https://{0}.sharepoint.com' -f ((Get-TcMember (Get-TcRemediationTenant 'Target') 'InitialDomain') -replace '\.onmicrosoft\.com$', '')

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    if (-not (Test-TcCollectionComplete $t 'sharePointExternalUsers')) { Write-TcRemediationAlert 'External user collection incomplete: the list may be partial' }
    $list = @(Get-TcRemediationTable $t 'sharePointExternalUsers')
    $noAddress = @($list | Where-Object { -not ($_['Accepted as'] -or $_['Email']) })
    Write-TcRemediationNote ("{0} external user(s) to validate, {1} with no address" -f $list.Count, $noAddress.Count)
    foreach ($x in $noAddress) { Write-TcRemediationAlert ("External user with no address: {0}" -f $x['Name']) }
    $presentItems = 0
    foreach ($x in $list | Where-Object { $_['Accepted as'] -or $_['Email'] }) {
        $address = ([string]$(if ($x['Accepted as']) { $x['Accepted as'] } else { $x['Email'] })).ToLowerInvariant()
        $domain = ($address -split '@')[-1]
        $state = if ($inTargetTenant[$address]) { 'Already in the target ({0})' -f $inTargetTenant[$address] } elseif ($domain -in $internalDomains) { 'Internal domain' } else { '' }
        if ($state) { $presentItems++ }
        [ordered]@{ Tenant = $t; Address = $address; Name = $x['Name']; 'Created' = $x['Created']; 'State' = $state; Proposal = $(if ($state) { 'Do not invite' } else { '' }) }
    }
    Write-TcRemediationNote ("{0} address(es) already in the target or in an internal domain" -f $presentItems)
}
$decisions = @(Get-TcDecision -Name 'SPO-EXTERNAL' -Proposal @($proposals) -Key 'Tenant', 'Address' -Choice 'Invite with email', 'Invite without email', 'Do not invite')

$invited = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -in 'Invite with email', 'Invite without email' })
foreach ($d in $invited) {
    if ((Get-TcMember $d 'State')) { Write-TcRemediationAlert ("{0}: {1}, invitation ignored to avoid a duplicate" -f (Get-TcMember $d 'Address'), (Get-TcMember $d 'State')); continue }
    $withEmail = (Get-TcMember $d 'Decision') -eq 'Invite with email'
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Address') -Description ("Invite {0} to the target, {1}" -f (Get-TcMember $d 'Address'), $(if ($withEmail) { 'with email' } else { 'without email' })) `
        -Data @{ Address = (Get-TcMember $d 'Address'); Name = (Get-TcMember $d 'Name'); Email = $withEmail; Redirect = $(if ((Get-TcMember $d 'Note') -match '^https://') { (Get-TcText $d 'Note') } else { $redirect }) } `
        -Test { param($a) [bool](Get-TargetAccountValue $a.data.Address) } `
        -Block {
            param($a)
            $x = $a.data
            $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri 'v1.0/invitations' -Body @{ invitedUserEmailAddress = (Get-TcMember $x 'Address'); invitedUserDisplayName = (Get-TcMember $x 'Name'); inviteRedirectUrl = (Get-TcMember $x 'Redirect'); sendInvitationMessage = [bool](Get-TcMember $x 'Email') }
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "v1.0/users/$((Get-TcMember (Get-TcMember $r 'invitedUser') 'id'))" }
        }
}
if ($invited.Count) {
    Add-TcManualAction -Tenant 'Target' -Object 'Guest access' -Description "Give the site access back and have the owners confirm" `
        -Instruction @('SharePoint site of the target > Settings > Site permissions: give the guest back the site, library or folder.', 'The owner confirms that the access works. The sharing level of the site must allow guests (SPO-SHARING).')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $l = @($invited | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and -not (Get-TcMember $_ 'State') })
    if (-not $l.Count) { return }
    $missing = @($l | Where-Object { -not (Get-TargetAccountValue (Get-TcMember $_ 'Address')) })
    if ($missing.Count) { New-TcRemediationResult Blocking ("{0} guest(s) out of {1} missing from the target" -f $missing.Count, $l.Count) } else { New-TcRemediationResult OK ("{0} guest(s) present in the target" -f $l.Count) }
}
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the guests of the sources confirmed, reinvites them to the target after the copy, and cleans the stale guests of the target (procedure ENT-GUESTS).

.DESCRIPTION
    Sources: decisions\ENT-GUESTS.csv, one row per useful guest, choices Reinvite or Ignore, to settle with the owners. Stale guests
    (invitation never accepted, or inactive past the threshold) and people from a tenant of the project are set aside: the first go in
    a report, the second belong to CMP-CROSS-GUESTS (ID-03).

    The reinvitation is planned only once the copy of teams and sites is finished: decisions\ENT-GUESTS-COPY-DONE.csv, one row per
    source, decision Done. The invitation message goes to the guest: warn them through the owner.
    An address on a domain of the project is never reinvited: the person will have a member account in the target.

    Target: decisions\ENT-GUESTS-TARGET.csv, one row per stale guest outside cross guests, choices Delete or Keep.

    Limits: the memberships of guests are not in the snapshot. Enter the teams and sites to keep in the Note column; the owners
    restore the access. Automatic expiry of inactive guests (access review) needs a customer choice and is not set up here.
#>
$c = Open-TcRemediation

$Threshold = [int](Get-TcRemediationOption 'InactiveDays')
$InvitationReturn = 'https://myapps.microsoft.com'

$projectDomains = @(@(Get-TcRemediationTable 'Target' 'domains' | ForEach-Object { $_['Domain'] }) + @((Get-TcSourceRole) | ForEach-Object { $i = Get-TcRemediationTenant $_; @((Get-TcMember $i 'Domains')) + (Get-TcMember $i 'InitialDomain') }) | ForEach-Object { ([string]$_).ToLowerInvariant() })

function Test-Stale {
    param($Guest)
    return $Guest['Invitation state'] -eq 'PendingAcceptance' -or [int]$Guest['Days inactive'] -ge $Threshold -or [int]$Guest['Days inactive'] -eq -1
}

function Test-ProjectAddress { param([string]$Address) return (Get-TcAddressDomain $Address) -in $projectDomains }

function Test-AccountProtected { param([string]$Account) return (Test-TcProtectedAccount -Account ([string]$Account)) }

function Find-TargetGuest {
    param([string]$Address)
    return @(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/users?`$filter=mail eq '{0}'&`$select=id" -f [uri]::EscapeDataString($Address.Replace("'", "''"))) -All)
}

$sourceProperties = [System.Collections.Generic.List[object]]::new()
$targetProperty = [System.Collections.Generic.List[object]]::new()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Guests read'
    $guests = @(Get-TcRemediationTable $t 'users' | Where-Object { $_['Type'] -eq 'Guest' })
    if (-not $guests.Count -and -not (Test-TcCollectionComplete $t 'users')) { Write-TcRemediationAlert "${t}: user collection incomplete, the absence of guests proves nothing"; continue }
    $stale = @($guests | Where-Object { Test-Stale $_ })
    $crossOnes = @($guests | Where-Object { Test-ProjectAddress $_['Email'] })
    if ($t -eq 'Target') {
        $toReview = @($stale | Where-Object { -not (Test-ProjectAddress $_['Email']) -and -not (Test-AccountProtected $_['UPN']) })
        Write-TcRemediationNote ("Of {0} guests, {1} stale; {2} to review, not counting cross-tenant guests (CMP-CROSS-GUESTS)" -f $guests.Count, $stale.Count, $toReview.Count)
        foreach ($u in $toReview) {
            $targetProperty.Add([ordered]@{ Account = $u['UPN']; Id = $u['Id']; Name = $u['Name']; Email = $u['Email']; 'Invitation state' = $u['Invitation state']; 'Days inactive' = $u['Days inactive']; Proposal = '' })
        }
        continue
    }
    $useful = @($guests | Where-Object { -not (Test-Stale $_) -and -not (Test-ProjectAddress $_['Email']) })
    Write-TcRemediationNote ("Of {0} guests, {1} stale and {2} people from a tenant in scope; {3} to confirm" -f $guests.Count, $stale.Count, $crossOnes.Count, $useful.Count)
    if ($stale.Count) { Export-TcRemediationReport -Name "stale-guests-$t" -Rows @($stale | ForEach-Object { [ordered]@{ Account = $_['UPN']; Name = $_['Name']; Email = $_['Email']; 'Invitation state' = $_['Invitation state']; 'Days inactive' = $_['Days inactive'] } }) | Out-Null }
    foreach ($u in $useful) {
        $sourceProperties.Add([ordered]@{ Tenant = $t; Email = $u['Email']; Name = $u['Name']; 'Days inactive' = $u['Days inactive']; Company = $u['Company']; Proposal = 'Reinvite' })
    }
}

$sources = @($c.Tenants | Where-Object { $_ -ne 'Target' })
$sourceDecisions = @(Get-TcDecision -Name 'ENT-GUESTS' -Proposal @($sourceProperties) -Key 'Tenant', 'Email' -Choice 'Reinvite', 'Ignore')
$targetDecision = @(Get-TcDecision -Name 'ENT-GUESTS-TARGET' -Proposal @($targetProperty) -Key 'Account' -Choice 'Delete', 'Keep')
$copies = @(Get-TcDecision -Name 'ENT-GUESTS-COPY-DONE' -Proposal @($sources | ForEach-Object { [ordered]@{ Tenant = $_; Object = 'Copy of teams and sites to the target'; Proposal = '' } }) -Key 'Tenant' -Choice 'Done' | ForEach-Object { (Get-TcMember $_ 'Tenant') })

foreach ($t in $sources) {
    $toInvite = @($sourceDecisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Reinvite' })
    if (-not $toInvite.Count) { continue }
    if ($t -notin $copies) { Write-TcRemediationNote ("{0}: {1} reinvitation(s) decided, waiting for the copy to finish (ENT-GUESTS-COPY-DONE.csv)" -f $t, $toInvite.Count); continue }
    foreach ($d in $toInvite) {
        if (Test-ProjectAddress (Get-TcMember $d 'Email')) { Write-TcRemediationAlert ("{0}: {1} belongs to a domain in scope, it will not be reinvited" -f $t, (Get-TcMember $d 'Email')); continue }
        Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Email') -Description ("Reinvite {0} in the target (guest of {1})" -f (Get-TcMember $d 'Email'), $t) -Data @{ Address = (Get-TcMember $d 'Email'); Name = (Get-TcMember $d 'Name') } `
            -Test { param($a) [bool](Get-TcCount (Find-TargetGuest $a.data.Address)) } `
            -Block {
                param($a)
                $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri 'v1.0/invitations' -Body @{ invitedUserEmailAddress = $a.data.Address; invitedUserDisplayName = $a.data.Name; inviteRedirectUrl = $InvitationReturn; sendInvitationMessage = $true }
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = ("v1.0/users/{0}" -f (Get-TcMember (Get-TcMember $r 'invitedUser') 'id')) }
            }
    }
    $f = Export-TcRemediationReport -Name "guests-access-to-restore-$t" -Rows $toInvite
    Add-TcManualAction -Tenant 'Target' -Object "Guest access of $t" -Who 'Owners' -Description ("Restore the access of {0} guest(s) of {1}: teams, sites and groups" -f $toInvite.Count, $t) `
        -Instruction @("List, with the access noted in the Note column: $f", 'Each guest must accept the new invitation message. The owner then restores their access and confirms.')
}

foreach ($d in $targetDecision | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Delete' }) {
    if (Test-ProjectAddress (Get-TcMember $d 'Email')) { Write-TcRemediationAlert ("{0} falls under CMP-CROSS-GUESTS: decision ignored" -f (Get-TcMember $d 'Account')); continue }
    Add-TcGraphAction -Tenant 'Target' -Method DELETE -Uri "v1.0/users/$((Get-TcMember $d 'Id'))" -Object (Get-TcMember $d 'Account') -Description ("Delete the stale guest {0}" -f (Get-TcMember $d 'Email')) `
        -Test { param($a) -not @(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users?`$filter=id eq '{0}'&`$select=id" -f ($a.uri -replace '^.*/', '')) -All).Count } `
        -Undo @{ type = 'Graph'; tenant = 'Target'; method = 'POST'; uri = "v1.0/directory/deletedItems/$((Get-TcMember $d 'Id'))/restore" }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -eq 'Target' -or $t -notin $copies) { return }
    $expectedItems = @($sourceDecisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Reinvite' -and -not (Test-ProjectAddress (Get-TcMember $_ 'Email')) })
    $missing = @($expectedItems | Where-Object { -not (Get-TcCount (Find-TargetGuest (Get-TcMember $_ 'Email'))) })
    if ($missing.Count) { New-TcRemediationResult Warning ("{0} confirmed guest(s) missing from the target" -f $missing.Count) } else { New-TcRemediationResult OK ("{0} confirmed guest(s) present in the target" -f $expectedItems.Count) }
}
Close-TcRemediation

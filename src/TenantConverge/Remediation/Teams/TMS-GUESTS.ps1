# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Reinvites to the target the team guests validated by the owners and adds them to the copied teams (procedure TMS-GUESTS).

.DESCRIPTION
    The snapshot gives the number of guests per team, not their names. The named list is therefore read in the source, in an -Apply run,
    before planning: the first run only fills decisions\TMS-GUESTS.csv, since no row is decided. In preview, the script reads this file.
    An invitation can send an email to a real person: the decision is taken row by row (Invite with email, Invite without email, Do not
    invite) and nothing is sent without it.
    The guest enters the group of the copied team: Microsoft does not support adding a guest to a team with an application permission.
    The target team is found by its prefixed alias; the Note column can give the team identifier if the tool kept another alias.
    The copy of the teams must be finished. An action applies to the target.
    Limit: telling the guest that the organization changes in Teams stays with the owner. An invitation not accepted leaves the guest with no access.
#>
$c = Open-TcRemediation

$DecisionName = 'TMS-GUESTS'
$DecisionFile = $DecisionName

function Get-TargetAccountValue {
    param([string]$Address)
    $f = $Address -replace "'", "''"
    return (@(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/users?`$filter=mail eq '{0}'&`$select=id,mail,userType" -f $f) -All) | Select-Object -First 1)
}

function Get-TargetTeam {
    <# Identifier of the copied team: the one in the note, otherwise the prefixed alias. #>
    param([string]$Note, [string]$Alias)
    if ($Note -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { return $Note }
    $f = $Alias -replace "'", "''"
    return (Get-TcMember (@(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/groups?`$filter=mailNickname eq '{0}'&`$select=id" -f $f) -All) | Select-Object -First 1) 'id')
}

function Test-TeamMember {
    param([string]$Team, [string]$Account)
    return $Account -in @(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/groups/{0}/members?`$select=id" -f $Team) -All | ForEach-Object { (Get-TcMember $_ 'id') })
}

$known = if (Test-TcDecisionFile $DecisionFile) { @(Read-TcDecisionRow $DecisionFile) } else { @() }
$proposals = [System.Collections.Generic.List[object]]::new()
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $teams = @(Get-TcRemediationTable $t 'teams')
    $withGuests = @(Get-TcRemediationTable $t 'teamComposition' | Where-Object { [int]$_['Guests'] -gt 0 })
    $totalCount = [int](Get-TcMember (@($withGuests | ForEach-Object { [int]$_['Guests'] }) | Measure-Object -Sum) 'Sum')
    Write-TcRemediationNote ("{0} team(s) have {1} guest(s) according to the snapshot" -f $withGuests.Count, $totalCount)
    foreach ($l in $withGuests) {
        $e = $teams | Where-Object { $_['Name'] -ceq $l['Team'] } | Select-Object -First 1
        if (-not $e) { Write-TcRemediationAlert ("Team with no identifier in the snapshot: {0}" -f $l['Team']); continue }
        $alias = '{0}-{1}' -f (Get-TcMember $i 'Prefix'), ([string]$e['Alias'] -ireplace "^$((Get-TcMember $i 'Prefix'))-", '')
        if ($c.Apply) {
            foreach ($m in @(Invoke-TcGraph -Tenant $t -Uri ("v1.0/groups/{0}/members/microsoft.graph.user?`$select=id,displayName,mail,userType,otherMails" -f $e['Id']) -All | Where-Object { (Get-TcMember $_ 'userType') -eq 'Guest' })) {
                $address = ([string]$(if ((Get-TcMember $m 'mail')) { (Get-TcMember $m 'mail') } else { (@((Get-TcMember $m 'otherMails')) | Select-Object -First 1) })).ToLowerInvariant()
                if ($address) { $proposals.Add([ordered]@{ Tenant = $t; 'Team' = $l['Team']; Address = $address; Name = (Get-TcMember $m 'displayName'); 'Target alias' = $alias; Proposal = '' }) }
                else { Write-TcRemediationAlert ("Guest with no address in {0}: {1}" -f $l['Team'], (Get-TcMember $m 'displayName')) }
            }
        }
        else {
            foreach ($k in @($known | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Team') -eq $l['Team'] })) {
                $proposals.Add([ordered]@{ Tenant = $t; 'Team' = (Get-TcMember $k 'Team'); Address = (Get-TcMember $k 'Address'); Name = (Get-TcMember $k 'Name'); 'Target alias' = (Get-TcMember $k 'Target alias'); Proposal = '' })
            }
        }
    }
    if (-not $c.Apply -and -not @($known | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t }).Count -and $totalCount) {
        Write-TcRemediationAlert 'Named list missing from the snapshot: an -Apply run reads the guests in the source, without inviting anyone'
    }
}
$decisions = @(Get-TcDecision -Name $DecisionName -Proposal @($proposals) -Key 'Tenant', 'Team', 'Address' -Choice 'Invite with email', 'Invite without email', 'Do not invite')

$guests = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -in 'Invite with email', 'Invite without email' })
foreach ($d in $guests) {
    $withEmail = (Get-TcMember $d 'Decision') -eq 'Invite with email'
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object (Get-TcMember $d 'Address') -Description ("Invite {0} and add them to the copied team of {1}, {2}" -f (Get-TcMember $d 'Address'), (Get-TcMember $d 'Team'), $(if ($withEmail) { 'with email' } else { 'without email' })) `
        -Data @{ Address = (Get-TcMember $d 'Address'); Name = (Get-TcMember $d 'Name'); Email = $withEmail; Alias = (Get-TcMember $d 'Target alias'); Note = (Get-TcText $d 'Note') } `
        -Test {
            param($a)
            $x = $a.data
            $account = Get-TargetAccountValue (Get-TcMember $x 'Address')
            $team = Get-TargetTeam (Get-TcMember $x 'Note') (Get-TcMember $x 'Alias')
            return $account -and $team -and (Test-TeamMember $team (Get-TcMember $account 'id'))
        } `
        -Block {
            param($a)
            $x = $a.data
            $team = Get-TargetTeam (Get-TcMember $x 'Note') (Get-TcMember $x 'Alias')
            if (-not $team) { throw "Copied team not found (alias $((Get-TcMember $x 'Alias'))): finish the copy, or give its identifier in the Note column" }
            $undos = [System.Collections.Generic.List[object]]::new()
            $account = Get-TargetAccountValue (Get-TcMember $x 'Address')
            $accountId = (Get-TcMember $account 'id')
            if (-not $account) {
                $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri 'v1.0/invitations' -Body @{ invitedUserEmailAddress = (Get-TcMember $x 'Address'); invitedUserDisplayName = (Get-TcMember $x 'Name'); inviteRedirectUrl = 'https://teams.microsoft.com'; sendInvitationMessage = [bool](Get-TcMember $x 'Email') }
                $accountId = (Get-TcMember (Get-TcMember $r 'invitedUser') 'id')
                $undos.Add(@{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "v1.0/users/$accountId" })
            }
            for ($test = 1; $test -le 6; $test++) {
                try {
                    Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri ("v1.0/groups/{0}/members/`$ref" -f $team) -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$accountId" } | Out-Null
                    break
                }
                catch { if ($test -eq 6) { throw }; Wait-TcRemediation -Seconds (5 * $test) }
            }
            $undos.Insert(0, @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = ("v1.0/groups/{0}/members/{1}/`$ref" -f $team, $accountId) })
            $a.undo = $undos.ToArray()
        }
}
if ($guests.Count) {
    Add-TcManualAction -Tenant 'Target' -Object 'Team guests' -Description "Warn the guests and follow the acceptance" -Instruction @('The owner tells the guest that the organization changes in Teams.', 'Adding to the group sends no email from Microsoft, and the team can take 24 hours or more to show the guest.', 'An invitation not accepted leaves the guest with no access.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $l = @($guests | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t })
    if (-not $l.Count) { return }
    $missing = @($l | Where-Object { -not (Get-TargetAccountValue (Get-TcMember $_ 'Address')) })
    if ($missing.Count) { New-TcRemediationResult Blocking ("{0} guest(s) out of {1} missing from the target" -f $missing.Count, $l.Count) } else { New-TcRemediationResult OK ("{0} guest(s) present in the target" -f $l.Count) }
}
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Defines the periodic review of access and guest accounts of the target, according to the licenses present (task CLOSE-03, procedure ACCESS-REVIEW).

.DESCRIPTION
    Data read: licenses, users, admin roles and Azure subscriptions of the snapshot.
    The script produces three reports at each run: guests, admin roles and inactive member accounts. It serves as a periodic review, to
    run each quarter on a fresh snapshot.

    Licenses: a Graph access review needs Entra ID P2 or ID Governance, in sufficient number for all the targeted members or reviewers.
    Guests are billed per monthly active user and need a linked Azure subscription.
    The script compares the seats present with this need. With not enough licenses, it proposes the periodic report and refuses the review.

    decisions\ACCESS-REVIEW.csv: one row per scope, Periodic report or Graph review. The Graph review aims at the guests of Microsoft 365
    groups, each quarter, with the owners as reviewers. It needs a backup reviewer, entered in the column of that name. The decisions
    never apply on their own to accounts: no automatic deletion is turned on.

    Limits: the quarterly run is planned outside the script. Admin roles go through the report: their Graph review needs PIM, whose
    eligible assignments are not in the snapshot.
#>
$c = Open-TcRemediation

$DecisionFile = 'ACCESS-REVIEW'
$ReviewName = (Get-TcObjectName ' - Guests of Microsoft 365 groups')
$ReviewUri = 'v1.0/identityGovernance/accessReviews/definitions'
$GuestScope = 'Guests of Microsoft 365 groups'
$RoleScope = 'Admin roles'
$GovernancePlans = '\bAAD_PREMIUM_P2\b|Entra_(Identity|ID)_Governance|Entra_Suite'
$InactiveDays = [int](Get-TcRemediationOption 'InactiveDays')
$MonthsBetweenReviews = 3
$ReviewDays = 14

$existingItems = Read-TcDecisionEntry -Name $DecisionFile -Key @('Tenant', 'Scope')
$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Licenses and populations'
    $products = @(Get-TcRemediationTable $t 'licenses' | Where-Object { [string]$_['Plans'] -match $GovernancePlans -and [int]('0' + $_['Purchased']) -gt 0 })
    $seats = (Get-TcMember (@($products | ForEach-Object { [int]$_['Purchased'] }) | Measure-Object -Sum) 'Sum')
    $users = @(Get-TcRemediationTable $t 'users')
    $memberRows = @($users | Where-Object { $_['Type'] -eq 'Member' -and (ConvertTo-TcBoolean $_['Enabled']) })
    $guests = @($users | Where-Object { $_['Type'] -eq 'Guest' })
    $azure = @(Get-TcRemediationTable $t 'azureSubscriptions').Count
    if (-not $azure -and -not (Test-TcCollectionComplete $t 'azureSubscriptions')) { Write-TcRemediationAlert 'Azure subscriptions: collection incomplete, zero subscriptions proves nothing.' }
    Write-TcRemediationNote ("{0} P2 or ID Governance seat(s): {1}" -f [int]$seats, $(if ($products) { (@($products | ForEach-Object { '{0} ({1})' -f $_['SKU'], $_['Purchased'] }) -join ', ') } else { 'none' }))
    Write-TcRemediationNote ("{0} active member(s), {1} guest(s), {2} Azure subscription(s) read" -f $memberRows.Count, $guests.Count, $azure)
    $enough = [int]$seats -ge $memberRows.Count -and $azure -gt 0
    if (-not $enough) { Write-TcRemediationNote 'Not enough licenses for a Graph review: the periodic report is proposed' }

    $inactive = @($guests | Where-Object { "$($_['Days inactive'])" -eq '' -or [int]$_['Days inactive'] -ge $InactiveDays })
    Export-TcRemediationReport -Name "guests-$t" -Rows @($guests | ForEach-Object { [ordered]@{ Account = $_['UPN']; Name = $_['Name']; Email = $_['Email']; Active = $_['Enabled']; 'Invitation state' = $_['Invitation state']; Created = $_['Created']; 'Last sign-in' = $_['Last sign-in']; 'Days inactive' = $_['Days inactive']
                                                                                 'To review' = $(if ("$($_['Days inactive'])" -eq '' -or [int]$_['Days inactive'] -ge $InactiveDays) { 'Yes' } else { 'No' }) } }) | Out-Null
    Export-TcRemediationReport -Name "roles-admin-$t" -Rows @(Get-TcRemediationTable $t 'adminRoles' | ForEach-Object { [ordered]@{ Role = $_['Role']; Principal = $_['Principal']; Type = $_['Principal type']; Assignment = $_['Assignment']; Scope = $_['Scope'] } }) | Out-Null
    $inactiveMembers = @($memberRows | Where-Object { "$($_['Days inactive'])" -ne '' -and [int]$_['Days inactive'] -ge $InactiveDays })
    Export-TcRemediationReport -Name "inactive-members-$t" -Rows @($inactiveMembers | ForEach-Object { [ordered]@{ Account = $_['UPN']; Name = $_['Name']; 'Last sign-in' = $_['Last sign-in']; 'Days inactive' = $_['Days inactive']; Licenses = $_['License count'] } }) | Out-Null
    Write-TcRemediationNote ("{0} guest(s) to review out of {1}, {2} member(s) inactive for {3} days" -f $inactive.Count, $guests.Count, $inactiveMembers.Count, $InactiveDays)

    foreach ($scope in $GuestScope, $RoleScope) {
        $before = $existingItems[('{0}|{1}' -f $t, $scope).ToLowerInvariant()]
        [ordered]@{ Tenant = $t; Scope = $scope; 'P2 or ID Governance seats' = [int]$seats; 'Targeted members' = $memberRows.Count; Guests = $guests.Count; 'Azure subscriptions' = $azure
                    'Backup reviewer' = $(if ($before) { (Get-TcMember $before 'Backup reviewer') } else { '' })
                    Proposal = $(if ($enough -and $scope -eq $GuestScope) { 'Graph review' } else { 'Periodic report' }) }
    }
}
$decisions = @(Get-TcDecision -Name $DecisionFile -Proposal @($proposals | Where-Object { $_ }) -Key 'Tenant', 'Scope' -Choice 'Periodic report', 'Graph review')

foreach ($t in $c.Tenants) {
    Add-TcManualAction -Tenant $t -Object 'Periodic review' -Description 'Plan the quarterly review and name its owner' -Who 'Customer' `
        -Instruction @('Each quarter: refresh the snapshot, run this script again, hand the reports to the owner.', 'Removing a guest or a role stays a decision of the customer: this script touches no account.')

    $d = $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Scope') -eq $GuestScope -and (Get-TcMember $_ 'Decision') -eq 'Graph review' } | Select-Object -First 1
    if ($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Scope') -eq $RoleScope -and (Get-TcMember $_ 'Decision') -eq 'Graph review' }) { Write-TcRemediationAlert ("{0}: Graph review of roles not supported by this script: use PIM, in the portal" -f $t) }
    if (-not $d) { continue }
    if ([int](Get-TcMember $d 'P2 or ID Governance seats') -lt [int](Get-TcMember $d 'Targeted members') -or [int](Get-TcMember $d 'Azure subscriptions') -eq 0) { Write-TcRemediationAlert ("{0}: Graph review refused: {1} seat(s) for {2} targeted member(s), {3} Azure subscription(s) for guest billing" -f $t, (Get-TcMember $d 'P2 or ID Governance seats'), (Get-TcMember $d 'Targeted members'), (Get-TcMember $d 'Azure subscriptions')); continue }
    if (-not (Get-TcMember $d 'Backup reviewer')) { Write-TcRemediationAlert ("{0}: Graph review with no backup reviewer: fill in the column" -f $t); continue }
    Add-TcBlockAction -Tenant $t -Service Graph -Object $ReviewName -Description ("Create the quarterly access review of guests, backup reviewer {0}" -f (Get-TcMember $d 'Backup reviewer')) -Data @{ Backup = (Get-TcMember $d 'Backup reviewer') } `
        -Test { param($a) [bool]@(Invoke-TcGraph -Tenant $a.tenant -Uri $ReviewUri -All | Where-Object { (Get-TcMember $_ 'displayName') -eq $ReviewName }).Count } `
        -Block {
            param($a)
            $u = @(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users?`$filter=userPrincipalName eq '{0}'&`$select=id" -f [uri]::EscapeDataString($a.data.Backup)) -All) | Select-Object -First 1
            if (-not $u) { throw "Backup reviewer not found: $($a.data.Backup)" }
            $start = (Get-TcRemediationNow).ToString('yyyy-MM-dd')
            $body = @{
                displayName = $ReviewName; descriptionForAdmins = 'Quarterly review of the guests of Microsoft 365 groups.'; descriptionForReviewers = 'Confirm that each guest still needs this access.'
                scope = @{ '@odata.type' = '#microsoft.graph.accessReviewQueryScope'; query = "./members/microsoft.graph.user/?`$count=true&`$filter=(userType eq 'Guest')"; queryType = 'MicrosoftGraph' }
                instanceEnumerationScope = @{ '@odata.type' = '#microsoft.graph.accessReviewQueryScope'; query = "/v1.0/groups?`$filter=(groupTypes/any(c:c+eq+'Unified'))&`$count=true"; queryType = 'MicrosoftGraph' }
                reviewers = @(@{ query = './owners'; queryType = 'MicrosoftGraph' })
                fallbackReviewers = @(@{ query = "/users/$((Get-TcMember $u 'id'))"; queryType = 'MicrosoftGraph' })
                settings = @{ mailNotificationsEnabled = $true; reminderNotificationsEnabled = $true; justificationRequiredOnApproval = $true; defaultDecisionEnabled = $false; defaultDecision = 'None'
                              instanceDurationInDays = $ReviewDays; autoApplyDecisionsEnabled = $false; recommendationsEnabled = $true
                              recurrence = @{ pattern = @{ type = 'absoluteMonthly'; interval = $MonthsBetweenReviews; month = 0; dayOfMonth = 0; daysOfWeek = @(); firstDayOfWeek = 'sunday'; index = 'first' }
                                           range = @{ type = 'noEnd'; numberOfOccurrences = 0; startDate = $start } } }
            }
            $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri $ReviewUri -Body $body
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "$ReviewUri/$((Get-TcMember $r 'id'))" }
        }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if (-not ($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Graph review' -and (Get-TcMember $_ 'Scope') -eq $GuestScope })) { return }
    $r = @(Invoke-TcGraph -Tenant $t -Uri $ReviewUri -All | Where-Object { (Get-TcMember $_ 'displayName') -eq $ReviewName }) | Select-Object -First 1
    if ($r) { New-TcRemediationResult OK ("access review present, state {0}" -f (Get-TcMember $r 'status')) } else { New-TcRemediationResult Warning 'access review missing' }
}
Close-TcRemediation

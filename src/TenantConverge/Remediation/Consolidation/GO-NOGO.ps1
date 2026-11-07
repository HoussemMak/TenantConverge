# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Prepares the go/no-go file: blockers, readiness, prerequisites, points to settle (procedure GO-NOGO).

.DESCRIPTION
    Report go-nogo-file-<source>.csv, one row per point: category, state, source, what is left to do. It gathers:
      - the plan: all its blockers and what could not be read;
      - what the plan does not see, read in the data: matrix, protected accounts in the matrix, duplicates with no mailbox in the source,
        pending decisions, test addresses, Cloudflare token;
      - what no tool measures, to confirm by a person;
      - the points to settle by the committee.

    Decision: decisions\GO-NOGO.csv. Enter Settled, the decision maker and the chosen solution in Note.
    This script proposes no solution and takes no decision: the go/no-go stays a human entry, and so does the backup date. It writes to
    no tenant.
    For an up-to-date state, run Invoke-TcAssessment just before.
#>
$c = Open-TcRemediation

$MailPoint = 'Inbound mail during the cutover'
$People = @(
    @('Backup scheduled just before the cutover', 'The date of the last good backup is entered at the backup confirmation'),
    @('POC report and cutover rehearsal available', 'To present to the committee'),
    @('Critical applications ready', 'Confirm with the customer'),
    @('Communication sent', 'Confirm the announcements and the outage notice'),
    @('First-day support organized', 'Confirm the team and the hours'),
    @('Rollback plan reviewed', 'Recall the point of no return when the target accounts are opened'),
    @('Reachable person at each DNS host, during the whole cutover', 'See decisions\CON-DOMAINS.csv')
)

function Read-ExistingDecision {
    param([string]$Name)
    $f = $Name
    if (-not (Test-TcDecisionFile $f)) { return $null }
    return @(Read-TcDecisionRow $f)
}

function Get-GoPoint {
    param([string]$Tenant, [string]$Category, [string]$Point, [string]$State, [string]$Source, [string]$ToDo)
    return [ordered]@{ Tenant = $Tenant; 'Category' = $Category; Point = $Point; 'State' = $State; Source = $Source; 'To do' = $ToDo }
}

$removalDelay = [int](Get-TcRemediationOption 'DomainRemovalMinutes')
$decisions = @(Get-TcDecision -Name 'GO-NOGO' -Proposal @($c.Tenants | ForEach-Object { [ordered]@{ Tenant = $_; Point = $MailPoint } }) -Key 'Tenant', 'Point' -Choice 'Settled')

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $points = [System.Collections.Generic.List[object]]::new()

    $blockers = @(Get-TcRemediationPlanBlocker -Tenant $t)
    Write-TcRemediationNote ("Plan: {0} blocking action(s) for this source" -f $blockers.Count)
    foreach ($blocker in $blockers) { $points.Add((Get-GoPoint $t 'Plan' ([string]$blocker['title']) 'Blocking' ([string]$blocker['id']) ([string]$blocker['action']))) }

    $m = Get-TcRemediationIdentity $t
    $rows = @((Get-TcMember $m 'rows'))
    if ((Get-TcMember $m 'State') -ne 'Validated') { $points.Add((Get-GoPoint $t 'Matrix' 'Matrix still a draft' 'Blocking' 'IDENTITY-MATRIX' 'Have the customer validate it, then save it as identity-matrix-<role>.csv in the decisions folder.')) }
    $toValidate = @($rows | Where-Object { (Get-TcMember $_ 'Decision') -eq 'To review' }).Count
    if ($toValidate) { $points.Add((Get-GoPoint $t 'Matrix' "$toValidate row(s) still to validate" 'Blocking' 'IDENTITY-MATRIX' 'Get the decision of the customer for each account.')) }
    if ([int](Get-TcMember $m 'Bookings')) { $points.Add((Get-GoPoint $t 'Matrix' ("{0} Bookings page(s) to recreate or drop" -f (Get-TcMember $m 'Bookings')) 'To confirm' 'Matrix' 'A deleted page cannot be recovered: decide page by page.')) }

    # whatever the decision: blocking sign-ins leaves these accounts open, then its check fails because they are in the matrix and enabled
    $protected = @(Get-TcProtectedMatrixRow $t)
    if ($protected.Count) { $points.Add((Get-GoPoint $t 'Protected accounts' ("{0} protected account(s) in the matrix: the cutover would fail after freezing all the other accounts" -f $protected.Count) 'Blocking' 'IDENTITY-MATRIX' 'Remove these rows from the matrix: neither Exclude nor the kept accounts are enough. IDENTITY-MATRIX removes them at export.')) }

    $mailboxes = @{}
    foreach ($b in @(Get-TcRemediationTable $t 'mailboxes')) { $mailboxes[([string]$b['UPN']).ToLowerInvariant()] = 1 }
    $duplicates = @($rows | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Duplicate' })
    $noMailbox = @($duplicates | Where-Object { -not $mailboxes[((Get-TcText $_ 'Source UPN')).ToLowerInvariant()] })
    if ($noMailbox.Count) { $points.Add((Get-GoPoint $t 'Duplicates' ("{0} duplicate(s) with no mailbox in the source: the cutover would try to write their source UPN" -f $noMailbox.Count) 'Blocking' 'Cutover' 'Set them to Exclude in the matrix.')) }
    $syncedRows = @($duplicates | Where-Object { (Get-TcMember $_ 'Synced') -and $mailboxes[((Get-TcText $_ 'Source UPN')).ToLowerInvariant()] })
    if ($syncedRows.Count) {
        $method = @(Read-ExistingDecision 'SYNCED-DUPLICATES') | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') } | Select-Object -First 1
        $points.Add((Get-GoPoint $t 'Duplicates' ("{0} duplicate(s) tied to a synced account with a mailbox in the source" -f $syncedRows.Count) $(if ($method) { 'OK' } else { 'Blocking' }) 'SYNCED-DUPLICATES' $(if ($method) { "Chosen method: $((Get-TcMember $method 'Decision'))" } else { 'Choose On-premises AD or Cloud attributes after the POC.' })))
    }

    # counted against the plan: a row with no decision leaves the file when another source rewrites it
    $references = @(Get-TcDomainHolder $t).Count
    $decided = @(Read-ExistingDecision 'RELEASE-DOMAIN' | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') }).Count
    if ($references -gt $decided) { $points.Add((Get-GoPoint $t 'Domain release' ("{0} account(s) stay on the domain when it is removed, {1} decided" -f $references, $decided) 'Blocking' 'RELEASE-DOMAIN' 'Run RELEASE-DOMAIN in preview for this source, then decide in decisions\RELEASE-DOMAIN.csv.')) }

    $cloudflare = @((Get-TcMember $i 'Domains') | Where-Object { (Get-TcDnsHost $_) -eq 'Cloudflare' })
    if ($cloudflare.Count) {
        $var = [string](Get-TcRemediationOption 'DnsApiTokenVariable')
        $token = [bool][Environment]::GetEnvironmentVariable($var)
        $points.Add((Get-GoPoint $t 'Access' ("Cloudflare token on this computer for {0}" -f ($cloudflare -join ', ')) $(if ($token) { 'OK' } else { 'Blocking' }) 'Domain removal, verification and addresses' $(if ($token) { '' } else { "Set the environment variable $var before the cutover." })))
    }
    $manualOnes = @((Get-TcMember $i 'Domains') | Where-Object { (Get-TcDnsHost $_) -ne 'Cloudflare' })
    if ($manualOnes.Count) { $points.Add((Get-GoPoint $t 'Access' ("DNS entered by hand on the cutover evening for {0}" -f ($manualOnes -join ', ')) 'To confirm' 'Domain removal, verification and addresses' 'Plan a person for this.')) }

    $destination = @((Get-TcRemediationOption 'TestRecipients') | Where-Object { $_ -and $_ -notmatch '^<' })
    $points.Add((Get-GoPoint $t 'Prerequisite' ("{0} test address(es) in the remediation settings" -f $destination.Count) $(if ($destination.Count -ge 2) { 'OK' } else { 'Blocking' }) 'MAIL-FLOW-TEST' $(if ($destination.Count -ge 2) { '' } else { 'Enter at least one internal and one external address: without them the mail flow test cannot run.' })))

    foreach ($h in $People) { $points.Add((Get-GoPoint $t 'To confirm by a person' $h[0] 'To confirm' 'Committee' $h[1])) }

    $d = $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Point') -eq $MailPoint } | Select-Object -First 1
    $text = "Between the removal of the domains from the source and the move of the MX record, the domain exists in no tenant: inbound mail has no destination. Since the addresses are assigned after the MX, the window really runs until the domains are assigned to target accounts. Removing the domain can take up to $([math]::Round($removalDelay / 60)) hours."
    $points.Add((Get-GoPoint $t 'To settle by the committee' $text $(if ($d) { 'Settled' } else { 'Open' }) 'Domain move' $(if ($d) { "$((Get-TcMember $d 'Note')) ($((Get-TcMember $d 'Decision maker')))" } else { 'Open decision: record it in decisions\GO-NOGO.csv.' })))
    if (-not $d) { Write-TcRemediationAlert "TO SETTLE: $text" }

    $reportRows = $points.ToArray()
    [void](Export-TcRemediationReport -Name "go-nogo-file-$t" -Rows $reportRows)
    $nb = @($reportRows | Where-Object { $_['State'] -eq 'Blocking' }).Count
    Write-TcRemediationNote ("File: {0} point(s), {1} blocking, {2} warning(s), {3} to confirm" -f (Get-TcCount $reportRows), $nb, @($reportRows | Where-Object { $_['State'] -eq 'Warning' }).Count, @($reportRows | Where-Object { $_['State'] -eq 'To confirm' }).Count)
    if ($nb) { Write-TcRemediationAlert "$nb blocker(s) to clear before the GO of $t." }
}

Invoke-TcRemediationPlan
Close-TcRemediation

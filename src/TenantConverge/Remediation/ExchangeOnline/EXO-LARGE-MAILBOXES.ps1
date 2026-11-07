# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Finds the large mailboxes, checks the target capacity and enables the archives (procedure EXO-LARGE-MAILBOXES).

.DESCRIPTION
    Target tenant (BUILD-02, by default), or a source with -Tenant S1 (PREP-02).

    Data read: mailboxUsage, mailboxes, archives, users and matrices. The threshold comes from the LargeMailboxGb setting.
    exports\large-mailboxes-<tenant>.csv gives each mailbox, its size, its quota, its archive and the conclusion.
    In a source, names are concealed in the usage statistics: in an -Apply run, a direct read of the mailboxes produces
    exports\large-mailboxes-measured-<tenant>.csv with the real names.

    Alerts: user mailbox over 50 GB with a 100 GB quota, shared mailbox over 50 GB with no license.
    Actions: in a source, turning on the archive on the target account when the source mailbox has one. If the target mailbox does not
    exist yet (PREP-02), the action is postponed.
    Decision: decisions\EXO-LARGE-MAILBOXES.csv, one row per mailbox, Enable the archive or Keep. It needs a license and cannot be
    undone: with no decision, no archive is turned on. The direct measure only reads, and runs without one.

    Limits: the license stays a decision of PREP-02 and the pre-copy starts in the copy tool. Turning on an archive cannot be undone by the
    script: disabling it can lose its content.
#>
$c = Open-TcRemediation

$Threshold = [double](Get-TcRemediationOption 'LargeMailboxGb')
$StandardLimit = 50
$TargetQuota = 100
$Targets = @{}
$archives = [System.Collections.Generic.List[object]]::new()

function ConvertTo-Gigabyte {
    <# 12.3 GB (13,207,024,435 bytes): the number of bytes, in GB. #>
    param([string]$SizeValue)
    if ($SizeValue -match '\(([\d,\s]+) bytes\)') { return [math]::Round([double](($Matches[1] -replace '[^\d]', '')) / 1GB, 2) }
    return 0
}

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $usage = @(Get-TcRemediationTable $t 'mailboxUsage')
    if (-not $usage.Count -and -not (Test-TcCollectionComplete $t 'mailboxUsage')) { Write-TcRemediationAlert 'Mailbox usage collection incomplete: run Invoke-TcAssessment again'; continue }
    $largeItems = @($usage | Where-Object { [double]$_['Size GB'] -ge $Threshold } | Sort-Object { [double]$_['Size GB'] } -Descending)
    $totalCount = (Get-TcMember (@($usage | ForEach-Object { [double]$_['Size GB'] }) | Measure-Object -Sum) 'Sum')
    Write-TcRemediationNote ("{0} mailbox(es) of {1} GB or more; total volume {2:N1} GB" -f $largeItems.Count, $Threshold, $totalCount)

    $noQuota = 0; $noLicense = 0
    $rows = foreach ($u in $largeItems) {
        $b = Get-TcRemediationTable $t 'mailboxes' | Where-Object { $_['UPN'] -eq $u['UPN'] } | Select-Object -First 1
        $a = Get-TcRemediationTable $t 'archives' | Where-Object { $_['UPN'] -eq $u['UPN'] } | Select-Object -First 1
        $account = Get-TcRemediationTable $t 'users' | Where-Object { $_['UPN'] -eq $u['UPN'] } | Select-Object -First 1
        $sizeValue = [double]$u['Size GB']
        $type = if ($b) { $b['Type'] } else { '' }
        $conclusion = 'Pre-copy first'
        if ($sizeValue -gt $StandardLimit -and $type -eq 'SharedMailbox' -and $account -and [int]$account['License count'] -eq 0) { $conclusion = 'License required'; $noLicense++ }
        elseif ($sizeValue -gt $StandardLimit -and [double]$u['Quota GB'] -lt $TargetQuota) { $conclusion = '100 GB quota required'; $noQuota++ }
        [pscustomobject][ordered]@{ 'Mailbox' = $u['UPN']; Type = $type; 'Size GB' = $sizeValue; 'Quota GB' = $u['Quota GB']; Archive = $u['Archive']; 'Archive GB' = $(if ($a) { $a['Size GB'] }); Conclusion = $conclusion }
    }
    if (@($rows).Count) { Export-TcRemediationReport -Name "large-mailboxes-$t" -Rows @($rows) | Out-Null }
    if ($noQuota) { Write-TcRemediationAlert ("{0} mailbox(es) over 50 GB with a quota under 100 GB" -f $noQuota) }
    if ($noLicense) { Write-TcRemediationAlert ("{0} shared mailbox(es) over 50 GB with no license: an Exchange Online Plan 2 license or equivalent is required" -f $noLicense) }

    if ($t -eq 'Target') { continue }

    $concealedOnes = @($largeItems | Where-Object { $_['UPN'] -notmatch '@' }).Count
    if ($concealedOnes) { Write-TcRemediationNote ("{0} mailbox(es) have a concealed name in the usage statistics: the direct measure gives their name" -f $concealedOnes) }
    Add-TcBlockAction -Tenant $t -Service Exo -Object 'Measure' -Data @{ Mailboxes = @(Get-TcRemediationTable $t 'mailboxes' | ForEach-Object { $_['UPN'] }) } -Description ("Measure the mailboxes of {0} directly" -f $t) -Reason 'Read only: the report stays in the log folder.' `
        -Block {
            param($a)
            $measures = foreach ($upn in $a.data.Mailboxes) {
                $s = Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command 'Get-EXOMailboxStatistics' -Parameters @{ UserPrincipalName = $upn }
                $go = ConvertTo-Gigabyte ((Get-TcText $s 'TotalItemSize'))
                if ($go -ge $Threshold) { [pscustomobject][ordered]@{ 'Mailbox' = $upn; 'Size GB' = $go; 'Items' = (Get-TcMember $s 'ItemCount') } }
            }
            Export-TcRemediationReport -Name ("large-mailboxes-measured-{0}" -f $a.tenant) -Rows @($measures | Sort-Object 'Size GB' -Descending) | Out-Null
        }

    foreach ($b in Get-TcRemediationTable $t 'mailboxes' | Where-Object { ConvertTo-TcBoolean $_['Archive'] }) {
        $l = @((Get-TcMember (Get-TcRemediationIdentity $t) 'rows')) | Where-Object { $_['Source UPN'] -eq $b['UPN'] } | Select-Object -First 1
        if (-not $l -or $l['Decision'] -notin 'Create', 'Duplicate') { Write-TcRemediationAlert ("{0} has an archive but no target account decided in the matrix" -f $b['UPN']); continue }
        $target = if ($l['Decision'] -eq 'Create') { $l['Temporary UPN'] } else { $l['Target UPN'] }
        $Targets[$target] = @($l['Temporary UPN'], $l['Target UPN'])
        $archives.Add([ordered]@{ Tenant = $t; Mailbox = $b['UPN']; 'Target account' = $target; Proposal = 'Enable the archive' })
    }

    Add-TcManualAction -Tenant $t -Object 'Pre-copy' -Description ("Start the pre-copy of the largest mailboxes of {0} first" -f $t) `
        -Instruction @("Confirm the target license: over 50 GB, a 100 GB quota is needed.", "A shared mailbox over 50 GB needs an Exchange Online Plan 2 license or equivalent, otherwise the copy can stop halfway.",
                    "Start these mailboxes first in the copy tool: a late pre-copy can overflow into the cutover window.")
}

$decisions = @(Get-TcDecision -Name 'EXO-LARGE-MAILBOXES' -Proposal @($archives) -Key 'Tenant', 'Mailbox' -Choice 'Enable the archive', 'Keep')
foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Enable the archive' }) {
    $target = (Get-TcText $d 'Target account')
    Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'Enable-Mailbox' -Parameters @{ Identity = $target; Archive = $true } -Object $target -Description ("Enable the archive of {0}" -f $target) `
        -Reason "Disabling an archive can lose its content: going back is decided separately." `
        -Test {
            param($a)
            foreach ($i in @($Targets[$a.parameters.Identity]) | Where-Object { $_ }) {
                try { $m = Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-Mailbox' -Parameters @{ Identity = $i } } catch { continue }
                $a.parameters.Identity = $i
                return (Get-TcText $m 'ArchiveStatus') -eq 'Enabled'
            }
            return Test-TcPostponed $a ("{0} has no mailbox in the target yet (PREP-02)" -f $a.parameters.Identity)
        }
}

Invoke-TcRemediationPlan
Close-TcRemediation

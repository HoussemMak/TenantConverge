# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Assigns the telephony licenses to the validated voice users, in the target (procedure TEL-USERS).

.DESCRIPTION
    decisions\TEL-USERS.csv has one row per voice user, matched with the matrix. Resource accounts are not users: TEL-VOICE-APPS handles them.
    For each Prepare row whose account exists in the target: Teams Phone add-on, and a calling plan if the decision TEL-ROUTING-TARGET
    is CallingPlan. The plan stops at the available licenses: the rest waits for the order (CMP-VOICE-LICENSES).
    The number is assigned by TEL-NUMBERS: Set-CsPhoneNumberAssignment then turns on voice for the account. No user of the source has
    its own calling policy according to the snapshot: no policy assignment is planned here.
#>
$c = Open-TcRemediation

$TypeFile = 'TEL-ROUTING-TARGET'
$targetType = if (Test-TcDecisionFile $TypeFile) { @(Read-TcDecisionRow $TypeFile | ForEach-Object { (Get-TcMember $_ 'Decision') } | Where-Object { $_ }) | Select-Object -First 1 }

$targetAccounts = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($u in Get-TcRemediationTable 'Target' 'users') { [void]$targetAccounts.Add([string]$u['UPN']) }
$matrices = @{}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $matrix = @{}
    foreach ($l in @((Get-TcMember (Get-TcRemediationIdentity $t) 'rows'))) { $matrix[((Get-TcText $l 'Source UPN')).ToLowerInvariant()] = $l }
    $matrices[$t] = $matrix
    $voice = @(Get-TcRemediationTable $t 'teamsUsers' | Where-Object { ConvertTo-TcBoolean $_['Enterprise Voice'] })
    $people = @($voice | Where-Object { $_['Features'] -notmatch 'VoiceApp' })
    Write-TcRemediationNote ("{0} voice account(s): {1} user(s), {2} resource account(s) handled by TEL-VOICE-APPS" -f $voice.Count, $people.Count, ($voice.Count - $people.Count))
    foreach ($u in $people) {
        $l = $matrix[([string]$u['UPN']).ToLowerInvariant()]
        [ordered]@{ Tenant = $t; 'Source account' = $u['UPN']; Name = $u['Name']; 'Number' = $u['Number']; 'Matrix decision' = $(if ($l) { (Get-TcMember $l 'Decision') }); 'Final account' = $(if ($l) { (Get-TcMember $l 'Target UPN') }); 'Temporary account' = $(if ($l) { (Get-TcMember $l 'Temporary UPN') })
                    Proposal = $(if ($l -and (Get-TcMember $l 'Decision') -ne 'Exclude') { 'Prepare' } else { 'Exclude' }) }
    }
}
$decisions = @(Get-TcDecision -Name 'TEL-USERS' -Proposal @($proposals) -Key 'Tenant', 'Source account' -Choice 'Prepare', 'Exclude')

function Get-TargetLicense {
    param([string]$Reason)
    return @(Get-TcRemediationTable 'Target' 'licenses' | Where-Object { $_['SKU'] -match $Reason -and [int]$_['Purchased'] -gt 0 }) | Select-Object -First 1
}

$plannedLicenses = [System.Collections.Generic.List[object]]::new()
$phone = Get-TargetLicense '^MCOEV$'
if ($phone) { $plannedLicenses.Add($phone) } else { Write-TcRemediationAlert 'Teams Phone license missing from the target: order it first (CMP-VOICE-LICENSES).' }
if ($targetType -eq 'CallingPlan') {
    $callingPlan = Get-TargetLicense 'MCOPSTN|Calling_Plan'
    if ($callingPlan) { $plannedLicenses.Add($callingPlan) } else { Write-TcRemediationAlert 'CallingPlan type chosen, but no calling plan in the target: order it first (CMP-VOICE-LICENSES).' }
}
if (-not $targetType) { Write-TcRemediationAlert 'Number type not decided (TEL-ROUTING-TARGET): only the Teams Phone add-ons are planned.' }

foreach ($licenseRow in $plannedLicenses) {
    $sku = [string]$licenseRow['SkuId']
    $rest = [int]$licenseRow['Available']
    $postponed = 0; $missing = 0
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Prepare' -and (Get-TcMember $_ 'Tenant') -in $c.Tenants }) {
        $account = @((Get-TcMember $d 'Final account'), (Get-TcMember $d 'Temporary account') | Where-Object { $_ -and $targetAccounts.Contains([string]$_) }) | Select-Object -First 1
        if (-not $account) { $missing++; continue }
        if ($rest -le 0) { $postponed++; continue }
        $rest--
        Add-TcGraphAction -Tenant 'Target' -Method POST -Uri "v1.0/users/$account/assignLicense" -Body @{ addLicenses = @(@{ skuId = $sku; disabledPlans = @() }); removeLicenses = @() } -Object ([string]$account) `
            -Description ("Assign {0} to {1}" -f $licenseRow['SKU'], $account) `
            -Test { param($a) [bool]@((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users/{0}?`$select=assignedLicenses" -f $a.object)) 'assignedLicenses') | Where-Object { (Get-TcMember $_ 'skuId') -eq $a.body.addLicenses[0].skuId }).Count } `
            -Undo @{ type = 'Graph'; tenant = 'Target'; method = 'POST'; uri = "v1.0/users/$account/assignLicense"; body = @{ addLicenses = @(); removeLicenses = @($sku) } }
    }
    if ($missing) { Write-TcRemediationAlert ("{0}: {1} account(s) not in the target yet, run again after they are created and after a new snapshot" -f $licenseRow['SKU'], $missing) }
    if ($postponed) { Write-TcRemediationAlert ("{0}: {1} assignment(s) postponed, no license left (CMP-VOICE-LICENSES)" -f $licenseRow['SKU'], $postponed) }
}

if ($decisions.Count) {
    Add-TcManualAction -Tenant 'Target' -Object 'Voice pilot group' -Description 'Test voice on a pilot group before the other users' `
        -Instruction @('After TEL-NUMBERS, make one inbound and one outbound call with each pilot account, in the Teams client.', 'The number cannot be assigned without a license: check this before the transfer day.')
}

Invoke-TcRemediationPlan -Verify {
    $n = 0; $short = 0
    foreach ($a in $script:TcRemediationRun['Actions'] | Where-Object { (Get-TcMember $_ 'type') -eq 'Graph' }) {
        $n++
        $licenseRow = @((Get-TcMember (Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/users/{0}?`$select=assignedLicenses" -f $a.object)) 'assignedLicenses') | Where-Object { (Get-TcMember $_ 'skuId') -eq $a.body.addLicenses[0].skuId }).Count
        if (-not $licenseRow) { $short++ }
    }
    if ($short) { New-TcRemediationResult Blocking ("{0} license assignment(s) missing out of {1}" -f $short, $n) } else { New-TcRemediationResult OK ("{0} license assignment(s) in place" -f $n) }
}
Close-TcRemediation

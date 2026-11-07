# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Removes the licenses of the source accounts, license by license, on decision (procedure LICENSE-REMOVAL).

.DESCRIPTION
    The target is refused: this script only touches the sources. If the target is asked for, it stops before any action.

    A license still carries the mail of the account: in an -Apply run, a tenant is handled only if the row Accounts opened says Done in
    decisions\CUTOVER-STEPS.csv and if decisions\TENANT-CLOSURE.csv holds its complete written authorization. Otherwise, nothing for this tenant.

    Decision: decisions\LICENSE-REMOVAL.csv, one row per license of each source. Remove or Keep.
    A license with 10000 units or more is a free offer: no proposal.
    Each license removed takes back the accounts that hold it, read live, except protected accounts (emergency, rescue, migration team,
    kept accounts); Undo-TcRemediation gives it back to these accounts, with their disabled plans. A license assigned through a group refuses
    removal account by account: the action fails and names the accounts.

    In an -Apply run, the report subscriptions-<tenant>.csv gives the state and the next change date of each subscription, for the reseller.
    Canceling a subscription has no API: it stays to do with the reseller.
#>
$c = Open-TcRemediation

if ('Target' -in $c.Tenants) {
    throw 'This is the target tenant: this script refuses to handle it. No action, no decision.'
}

function Get-LicenseAccount {
    <# Accounts that hold the license, except protected accounts. Filtered here: a Graph filter on assignedLicenses needs an advanced query. #>
    param([string]$Tenant, [string]$SkuId)
    $i = Get-TcRemediationTenant $Tenant
    return @(Invoke-TcGraph -Tenant $Tenant -Uri 'v1.0/users?$select=id,userPrincipalName,assignedLicenses&$top=999' -All | Where-Object { @((Get-TcMember $_ 'assignedLicenses') | Where-Object { (Get-TcMember $_ 'skuId') -eq $SkuId }).Count -and -not (Test-TcProtectedAccount (Get-TcMember $_ 'userPrincipalName') $i) })
}

function Get-RemovalRefusal {
    <# What forbids removing the licenses of a tenant: the cutover must be over and its closure authorized in writing. #>
    param([string]$Tenant)
    $r = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-TcCutoverStep -Tenant $Tenant -Step 'Accounts opened')) { $r.Add('the cutover is not recorded as done in the decisions') }
    $a = (Read-TcDecisionEntry -Name 'TENANT-CLOSURE' -Key 'Tenant')[$Tenant.ToLowerInvariant()]
    if (-not $a -or $a.'Decision' -ne 'Allowed' -or -not $a.'Decision maker' -or -not $a.Date -or -not ([string]$a.Note).Trim()) { $r.Add('no complete written authorization in TENANT-CLOSURE.csv') }
    return $r.ToArray()
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $licenses = @(Get-TcRemediationTable $t 'licenses')
    $paid = @($licenses | Where-Object { [int]$_['Purchased'] -lt 10000 })
    Write-TcRemediationNote ("{0} license(s), {1} of them paid: {2}" -f $licenses.Count, $paid.Count, (($paid | ForEach-Object { '{0} {1}/{2}' -f $_['SKU'], $_['Consumed'], $_['Purchased'] }) -join ', '))
    foreach ($l in $licenses) {
        [ordered]@{ Tenant = $t; License = $l['SKU']; SkuId = $l['SkuId']; 'Purchased' = $l['Purchased']; 'Consumed' = $l['Consumed']; Proposal = $(if ([int]$l['Purchased'] -lt 10000) { 'Remove' } else { '' }) }
    }
}
$decisions = @(Get-TcDecision -Name 'LICENSE-REMOVAL' -Proposal @($proposals) -Key 'Tenant', 'License' -Choice 'Remove', 'Keep')

foreach ($t in $c.Tenants) {
    $refusal = @(Get-RemovalRefusal $t)
    if ($refusal.Count) {
        if ($c.Apply) { Write-TcRemediationAlert ("{0}: licenses not removed, {1}." -f $t, ($refusal -join ' ; ')); continue }
        Write-TcRemediationNote ("{0}: to gather before the -Apply run: {1}" -f $t, ($refusal -join ' ; '))
    }
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Remove' }) {
        Add-TcBlockAction -Tenant $t -Service Graph -Object (Get-TcMember $d 'License') -Description ("Remove {0} from its {1} account(s) read in {2}" -f (Get-TcMember $d 'License'), (Get-TcMember $d 'Consumed'), $t) -Data @{ SkuId = (Get-TcMember $d 'SkuId') } `
            -Test {
                param($a)
                $a.data.Accounts = @(Get-LicenseAccount -Tenant $a.tenant -SkuId $a.data.SkuId)
                return -not $a.data.Accounts.Count
            } `
            -Block {
                param($a)
                $sku = $a.data.SkuId
                $undos = [System.Collections.Generic.List[object]]::new()
                $failures = [System.Collections.Generic.List[string]]::new()
                foreach ($u in $a.data.Accounts) {
                    $uri = "v1.0/users/$((Get-TcMember $u 'id'))/assignLicense"
                    $before = @((Get-TcMember $u 'assignedLicenses') | Where-Object { (Get-TcMember $_ 'skuId') -eq $sku }) | Select-Object -First 1
                    try {
                        Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri $uri -Body @{ addLicenses = @(); removeLicenses = @($sku) } | Out-Null
                        $undos.Add(@{ type = 'Graph'; tenant = $a.tenant; method = 'POST'; uri = $uri; body = @{ addLicenses = @(@{ skuId = $sku; disabledPlans = @((Get-TcMember $before 'disabledPlans')) }); removeLicenses = @() } })
                    }
                    catch { $failures.Add(("{0}: {1}" -f (Get-TcMember $u 'userPrincipalName'), (Get-TcErrorText $_))) }
                }
                $a.undo = $undos.ToArray()
                if ($failures.Count) { throw ("{0} account(s) out of {1} failed: {2}" -f $failures.Count, @($a.data.Accounts).Count, ($failures -join ' ; ')) }
            }
    }
    $removedOnes = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Remove' })
    if ($removedOnes.Count) {
        Add-TcManualAction -Tenant $t -Object "Cancellation $t" -Description "Cancel the subscriptions of $t with the reseller" -Who 'Customer and reseller' -Instruction @(
            ("Subscriptions to cancel with the reseller: {0}." -f (($removedOnes | ForEach-Object { (Get-TcMember $_ 'License') }) -join ', ')),
            'Rely on the subscriptions report for the dates. No API allows the cancellation.')
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $subscriptions = @(Invoke-TcGraph -Tenant $t -Uri 'v1.0/directory/subscriptions' -All)
    [void](Export-TcRemediationReport -Name "subscriptions-$t" -Rows @($subscriptions | ForEach-Object { [ordered]@{ License = (Get-TcMember $_ 'skuPartNumber'); 'State' = (Get-TcMember $_ 'status'); Seats = (Get-TcMember $_ 'totalLicenses'); 'Test' = (Get-TcMember $_ 'isTrial'); 'Next change' = (Get-TcMember $_ 'nextLifecycleDateTime') } }))
    if (@(Get-RemovalRefusal $t).Count) { New-TcRemediationResult Info 'check skipped: this tenant was not handled'; return }
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Remove' }) {
        $n = @(Get-LicenseAccount -Tenant $t -SkuId (Get-TcMember $d 'SkuId')).Count
        if ($n) { New-TcRemediationResult Blocking ("{0}: still held by {1} account(s)" -f (Get-TcMember $d 'License'), $n) } else { New-TcRemediationResult OK ("{0}: removed from all unprotected accounts" -f (Get-TcMember $d 'License')) }
    }
}
Close-TcRemediation

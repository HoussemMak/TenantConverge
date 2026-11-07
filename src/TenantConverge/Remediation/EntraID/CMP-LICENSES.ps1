# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Works out the licenses to order for each source before PREP-02 (procedure CMP-LICENSES).

.DESCRIPTION
    Buys nothing. The need comes from the matrix of the source: the validated matrix if it exists, otherwise the draft.
    The rows Create of type User are counted, by SKU. The rows To review of type User give the maximum need while the matrix is not
    validated, except likely duplicates and external accounts (#EXT#), which need no license. The available count comes from the
    licenses table of the target, cumulated in the order of the sources: each source uses what the previous one did not take.

    exports\licenses-to-order.csv gives the quantity per source. The order goes through the purchasing channel of the customer, before
    PREP-02: with no license, no mailbox and no OneDrive, and the pre-copy cannot start. Ordering before the exclusions creates a
    surplus: the script says so while the matrix is not validated. Run again after the order: the check reads the licenses available in
    the target.
#>
$c = Open-TcRemediation

$DefaultSku = Get-TcRemediationLicense

function Get-AvailableUnit {
    param([string]$Sku)
    $l = Get-TcRemediationTable 'Target' 'licenses' | Where-Object { $_['SKU'] -eq $Sku } | Select-Object -First 1
    return $(if ($l) { [int]$l['Available'] } else { 0 })
}

function Get-LiveAvailableUnit {
    param([string]$Sku)
    $s = @(Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/subscribedSkus' -All) | Where-Object { (Get-TcMember $_ 'skuPartNumber') -eq $Sku } | Select-Object -First 1
    return $(if ($s) { [int](Get-TcMember (Get-TcMember $s 'prepaidUnits') 'enabled') - [int](Get-TcMember $s 'consumedUnits') } else { 0 })
}

$order = @(@((Get-TcSourceRole)) | Where-Object { $_ -in $c.Tenants })
$rest = @{}
$rows = [System.Collections.Generic.List[object]]::new()
$NeedBySku = @{}
foreach ($t in $order) {
    Write-TcRemediationTenant $t 'License need'
    $m = Import-TcSourceMatrix $t
    if ((Get-TcMember $m 'State') -eq 'missing') { Write-TcRemediationAlert "${t}: no matrix, run IDENTITY-MATRIX first"; continue }
    $users = @((Get-TcMember $m 'Rows') | Where-Object { (Get-TcMember $_ 'Type') -eq 'User' -and (Get-TcMember $_ 'Source UPN') -notmatch '#EXT#' })
    $closed = @($users | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Create' })
    $toValidate = @($users | Where-Object { (Get-TcMember $_ 'Decision') -eq 'To review' -and (Get-TcMember $_ 'Notes') -notmatch 'likely duplicate' })
    $bySku = @{}
    foreach ($l in $closed) { $s = if ((Get-TcMember $l 'License')) { (Get-TcMember $l 'License') } else { $DefaultSku }; $bySku[$s] = 1 + [int]$bySku[$s] }
    if (-not $bySku.Count) { $bySku[$DefaultSku] = 0 }
    foreach ($s in $bySku.Keys) {
        if (-not $rest.ContainsKey($s)) { $rest[$s] = Get-AvailableUnit $s }
        $takenOnes = [math]::Min($rest[$s], $bySku[$s])
        $rest[$s] -= $takenOnes
        $command = $bySku[$s] - $takenOnes
        $NeedBySku[$s] = $bySku[$s] + [int]$NeedBySku[$s]
        $rows.Add([ordered]@{ Source = $t; Matrix = (Get-TcMember $m 'State'); SKU = $s; 'To create' = $bySku[$s]; 'To validate' = $toValidate.Count; 'Taken from available' = $takenOnes; 'To order' = $command; 'To order at most' = $command + $toValidate.Count })
        Write-TcRemediationNote ("{0}: {1} account(s) to create, {2} still to validate; to order: {3}, {4} at most (matrix {5})" -f $s, $bySku[$s], $toValidate.Count, $command, ($command + $toValidate.Count), (Get-TcMember $m 'State'))
        if ($command -or $toValidate.Count) {
            Add-TcManualAction -Tenant 'Target' -Object "Licenses $s ($t)" -Who 'Customer' -Minutes 0 -Description ("Order {0} {1} license(s) for {2}" -f $command, $s, $t) `
                -Instruction @($(if ((Get-TcMember $m 'State') -eq 'Draft') { 'Matrix not validated: the quantity will drop with the exclusions and duplicates. Wait for the validated matrix, without delaying the pre-copy.' } else { 'Quantity taken from the validated matrix.' }), 'Order through the purchasing channel of the customer. Run the script again to check that the licenses are visible.') `
                -WaitUntil { param($a) $sku = ($a.object -split ' ')[1]; (Get-LiveAvailableUnit $sku) -ge [int]$NeedBySku[$sku] }
        }
    }
    if ((Get-TcMember $m 'State') -eq 'validated' -and $toValidate.Count) { Write-TcRemediationAlert ("{0}: the validated matrix still contains {1} row(s) marked To review" -f $t, $toValidate.Count) }
}

if ($rows.Count) { Export-TcRemediationReport -Name 'licenses-to-order' -Rows @($rows) | Out-Null }

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne $order[0]) { return }
    foreach ($s in @($NeedBySku.Keys)) {
        $n = Get-LiveAvailableUnit $s
        if ($n -ge $NeedBySku[$s]) { New-TcRemediationResult OK ("{0}: {1} available for {2} accounts to create" -f $s, $n, $NeedBySku[$s]) } else { New-TcRemediationResult Warning ("{0}: {1} available for {2} accounts to create" -f $s, $n, $NeedBySku[$s]) }
    }
}
Close-TcRemediation

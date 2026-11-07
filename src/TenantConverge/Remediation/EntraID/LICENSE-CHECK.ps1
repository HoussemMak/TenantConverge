# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Checks the licenses available in the target before the pre-copy (procedure LICENSE-CHECK).

.DESCRIPTION
    Report licenses-<tenant>.csv: need per license from the matrix (rows Create of type User), accounts still To review that could add to
    it, available count read in the target, and what is short.
    What is short is settled by a purchase: the script orders nothing and assigns nothing. The assignment happens at PREP-02.
    In an -Apply run, the available counts are read live in the target.
#>
$c = Open-TcRemediation

$DefaultSku = Get-TcRemediationLicense
$Needs = @{}
$target = @(Get-TcRemediationTable 'Target' 'licenses')

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $m = Get-TcRemediationIdentity $t
    if ((Get-TcMember $m 'State') -ne 'Validated') { Write-TcRemediationAlert 'The matrix is still a draft: the needs remain an estimate.' }
    $create = @((Get-TcMember $m 'rows') | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Create' -and (Get-TcMember $_ 'Type') -eq 'User' })
    $toCheck = @((Get-TcMember $m 'rows') | Where-Object { (Get-TcMember $_ 'Decision') -eq 'To review' -and (Get-TcMember $_ 'Type') -eq 'User' })
    $bySku = $create | Group-Object { if ((Get-TcMember $_ 'License')) { (Get-TcMember $_ 'License') } else { $DefaultSku } }
    $skus = @(@($bySku | ForEach-Object { (Get-TcMember $_ 'Name') }) + $(if ($toCheck.Count) { $DefaultSku }) | Where-Object { $_ } | Select-Object -Unique)
    $rows = foreach ($s in $skus) {
        $need = [int](Get-TcMember (@($bySku | Where-Object { (Get-TcMember $_ 'Name') -eq $s }) | Measure-Object -Property Count -Sum) 'Sum')
        $toValidate = if ($s -eq $DefaultSku) { $toCheck.Count } else { 0 }
        $l = $target | Where-Object { $_['SKU'] -eq $s } | Select-Object -First 1
        $available = if ($l) { [int]$l['Available'] } else { 0 }
        $Needs["$t|$s"] = $need
        Write-TcRemediationNote ("{0}: {1} to create, {2} to validate, {3} available in the target" -f $s, $need, $toValidate, $available)
        if ($available -lt $need) { Write-TcRemediationAlert ("{0}: {1} license(s) short for the accounts to create" -f $s, ($need - $available)) }
        [ordered]@{ Tenant = $t; License = $s; 'Accounts to create' = $need; 'Accounts to validate' = $toValidate; 'Present in target' = $(if ($l) { 'Yes' } else { 'No' }); Available = $available; Short = [math]::Max(0, $need - $available); 'Short if everything is validated' = [math]::Max(0, $need + $toValidate - $available) }
    }
    [void](Export-TcRemediationReport -Name "licenses-$t" -Rows @($rows))
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $direct = @(Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/subscribedSkus' -All)
    foreach ($k in @($Needs.Keys | Where-Object { $_ -like "$t|*" })) {
        $s = ($k -split '\|')[1]
        $l = $direct | Where-Object { (Get-TcMember $_ 'skuPartNumber') -eq $s } | Select-Object -First 1
        $available = if ($l) { [int](Get-TcMember (Get-TcMember $l 'prepaidUnits') 'enabled') - [int](Get-TcMember $l 'consumedUnits') } else { 0 }
        if ($available -ge $Needs[$k]) { New-TcRemediationResult OK ("{0}: {1} available for {2} account(s)" -f $s, $available, $Needs[$k]) }
        else { New-TcRemediationResult Blocking ("{0}: {1} available for {2} account(s)" -f $s, $available, $Needs[$k]) 'Buy what is short before the pre-copy.' }
    }
}
Close-TcRemediation

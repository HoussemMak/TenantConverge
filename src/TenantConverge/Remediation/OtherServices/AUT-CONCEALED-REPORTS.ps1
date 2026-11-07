# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Shows the real names in the usage reports of the sources during the migration, then restores the concealment (procedure AUT-CONCEALED-REPORTS).

.DESCRIPTION
    The change exposes personal data to anyone with access to the reports: it needs the agreement of the customer.
    decisions\AUT-CONCEALED-REPORTS.csv: one row per source. Unmask lifts the concealment, Restore puts it back at closure, Leave does
    nothing. The reference of the agreement goes in the Note column.
    After Unmask, run Invoke-TcAssessment again to get the detail by site and by account.
    A concealment forgotten at closure leaves personal data visible: the check reports it until it is restored.
#>
$c = Open-TcRemediation

$Uri = 'v1.0/admin/reportSettings'

$proposals = @(foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $concealed = ConvertTo-TcBoolean (Get-TcRemediationValue $t 'reportSettings' 'Names concealed in reports')
    Write-TcRemediationNote ("Read: {0} names in the reports" -f $(if ($concealed) { 'concealed' } else { 'shown' }))
    [ordered]@{ Tenant = $t; 'concealed names' = $(if ($concealed) { 'Yes' } else { 'No' }); Proposal = $(if ($concealed) { 'Unmask' } else { 'Leave' }) }
})

$decisions = @(Get-TcDecision -Name 'AUT-CONCEALED-REPORTS' -Proposal $proposals -Key 'Tenant' -Choice 'Unmask', 'Restore', 'Leave')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -ne 'Leave' }) {
    $target = (Get-TcMember $d 'Decision') -eq 'Restore'
    Add-TcGraphAction -Tenant (Get-TcMember $d 'Tenant') -Method PATCH -Uri $Uri -Body @{ displayConcealedNames = $target } -Object 'Usage reports' `
        -Description $(if ($target) { 'Restore the concealing of names in the reports' } else { 'Show names in the reports for the duration of the migration' }) `
        -Test { param($a) [bool](Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri $a.uri) 'displayConcealedNames') -eq [bool]$a.body.displayConcealedNames }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $d = $decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | Select-Object -First 1
    if (-not $d -or (Get-TcMember $d 'Decision') -eq 'Leave') { return }
    $concealed = [bool](Get-TcMember (Invoke-TcGraph -Tenant $t -Uri $Uri) 'displayConcealedNames')
    if ($concealed -eq ((Get-TcMember $d 'Decision') -eq 'Restore')) { New-TcRemediationResult OK $(if ($concealed) { 'concealed names' } else { 'names shown: run Invoke-TcAssessment again, and remember to restore the concealing at closing' }) }
    else { New-TcRemediationResult Blocking "displayConcealedNames is $concealed, contrary to the decision" }
}
Close-TcRemediation

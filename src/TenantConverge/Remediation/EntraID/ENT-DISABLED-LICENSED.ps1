# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the disabled accounts that keep a license decided, and removes these licenses in the target (procedure ENT-DISABLED-LICENSED).

.DESCRIPTION
    The preview creates decisions\ENT-DISABLED-LICENSED.csv: one row per account, with its licenses and the hold state of its
    mailbox, read from the mailboxes table of the snapshot.
      - Target: Remove takes the licenses off, Keep leaves them.
      - Sources: nothing is removed. Exclude or Keep feeds the matrix: the license is not carried over to the target.
    Guards: a mailbox on litigation hold, or under a hold, keeps its license; a protected account is never touched; Remove is
    refused in a source.
    Limits: a license assigned through a group is not removed account by account, the action then fails and says so. The snapshot
    does not show this mode of assignment. The Teams resource accounts of the sources belong to telephony.
#>
$c = Open-TcRemediation

function Get-UnderHold {
    param($Mailbox)
    return [bool]($Mailbox -and ((ConvertTo-TcBoolean $Mailbox['Litigation hold']) -or [int]('0' + $Mailbox['Holds']) -gt 0))
}

$proposals = @(foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Disabled accounts with license'
    $accounts = @(Get-TcRemediationTable $t 'users' | Where-Object { -not (ConvertTo-TcBoolean $_['Enabled']) -and [int]('0' + $_['License count']) -gt 0 })
    $totalCount = (Get-TcMember (@($accounts | ForEach-Object { [int]$_['License count'] }) | Measure-Object -Sum) 'Sum')
    Write-TcRemediationNote ("{0} disabled account(s) use {1} license(s)" -f $accounts.Count, [int]$totalCount)
    $resources = @(Get-TcRemediationTable $t 'resourceAccounts' | ForEach-Object { ([string]$_['UPN']).ToLowerInvariant() })
    foreach ($u in $accounts) {
        $b = Get-TcRemediationTable $t 'mailboxes' | Where-Object { $_['UPN'] -eq $u['UPN'] } | Select-Object -First 1
        $kept = Get-UnderHold $b
        [ordered]@{ Tenant = $t; Account = $u['UPN']; Name = $u['Name']; Licenses = $u['Licenses']; 'Mailbox type' = $(if ($b) { $b['Type'] })
                    'Retention' = $(if ($kept) { 'Yes' } else { 'No' }); 'Teams resource account' = $(if (([string]$u['UPN']).ToLowerInvariant() -in $resources) { 'Yes' } else { 'No' })
                    Proposal = $(if ($kept) { 'Keep' } elseif ($t -eq 'Target') { 'Remove' } else { 'Exclude' }) }
    }
})

$decisions = @(Get-TcDecision -Name 'ENT-DISABLED-LICENSED' -Proposal $proposals -Key 'Tenant', 'Account' -Choice 'Remove', 'Keep', 'Exclude')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -in 'Remove', 'Exclude' }) {
    if ((Get-TcMember $d 'Tenant') -ne 'Target') {
        if ((Get-TcMember $d 'Decision') -eq 'Remove') { Write-TcRemediationAlert ("{0}: nothing is removed in a source, decide Exclude or Keep ({1})" -f (Get-TcMember $d 'Tenant'), (Get-TcMember $d 'Account')) }
        continue
    }
    if ((Get-TcMember $d 'Decision') -eq 'Exclude') { Write-TcRemediationAlert ("In the target: Exclude makes no sense for {0}, decide Remove or Keep" -f (Get-TcMember $d 'Account')); continue }
    if (Test-TcProtectedAccount (Get-TcMember $d 'Account') (Get-TcRemediationTenant 'Target')) { Write-TcRemediationAlert ("{0} is a protected account: decision ignored" -f (Get-TcMember $d 'Account')); continue }
    if ((Get-TcMember $d 'Retention') -eq 'Yes') { Write-TcRemediationAlert ("{0}: mailbox under retention, the license stays despite the decision" -f (Get-TcMember $d 'Account')); continue }
    $u = Get-TcRemediationTable 'Target' 'users' | Where-Object { $_['UPN'] -eq (Get-TcMember $d 'Account') } | Select-Object -First 1
    if (-not $u) { Write-TcRemediationAlert ("{0}: account missing from the snapshot" -f (Get-TcMember $d 'Account')); continue }
    $names = @(([string]$u['Licenses']) -split ',\s*' | Where-Object { $_ })
    $skus = @(Get-TcRemediationTable 'Target' 'licenses' | Where-Object { $_['SKU'] -in $names } | ForEach-Object { $_['SkuId'] })
    if ($skus.Count -ne $names.Count) { Write-TcRemediationAlert ("{0}: {1} license(s) without an identifier in the snapshot" -f (Get-TcMember $d 'Account'), ($names.Count - $skus.Count)); continue }
    $uri = "v1.0/users/$($u['Id'])/assignLicense"
    Add-TcGraphAction -Tenant 'Target' -Method POST -Uri $uri -Body @{ addLicenses = @(); removeLicenses = $skus } -Object (Get-TcMember $d 'Account') -Description ("Remove {0} license(s) from the disabled account {1}" -f $skus.Count, (Get-TcMember $d 'Account')) `
        -Test { param($a) -not @((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri ('{0}?$select=assignedLicenses' -f ($a.uri -replace '/assignLicense$', ''))) 'assignedLicenses') | Where-Object { (Get-TcMember $_ 'skuId') -in $a.body.removeLicenses }).Count } `
        -Undo @{ type = 'Graph'; tenant = 'Target'; method = 'POST'; uri = $uri; body = @{ addLicenses = @($skus | ForEach-Object { @{ skuId = $_ } }); removeLicenses = @() } }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $remaining = @(Invoke-TcGraph -Tenant $t -Uri "v1.0/users?`$filter=accountEnabled eq false&`$select=userPrincipalName,assignedLicenses" -All | Where-Object { @((Get-TcMember $_ 'assignedLicenses')).Count })
    $known = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq 'Target' -and (Get-TcMember $_ 'Decision') -eq 'Keep' } | ForEach-Object { (Get-TcMember $_ 'Account') })
    $others = @($remaining | Where-Object { (Get-TcMember $_ 'userPrincipalName') -notin $known })
    if ($others.Count) { New-TcRemediationResult Warning ("{0} disabled account(s) keep a license without a Keep decision" -f $others.Count) } else { New-TcRemediationResult OK 'only documented cases remain' }
}
Close-TcRemediation

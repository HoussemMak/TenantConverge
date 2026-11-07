# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Creates the POC test set in a source: two accounts and a group, with the ObjectPrefix setting (procedure POC-TEST-SET).

.DESCRIPTION
    Accounts on the initial domain of the tenant, disabled, with a random password that nobody knows and that is written nowhere. For a
    test, open the account and give it access by hand. Undo-TcRemediation removes the members, the group and the accounts.

    The script creates only these three objects. License, mailbox, OneDrive, team, site and test devices stay to do: they depend on the
    free licenses of the source and the test domain (POC-01, POC-02).
#>
$c = Open-TcRemediation

$Prefix = (Get-TcObjectName '-POC')
$GroupName = "$Prefix-Group"

function Get-TestAccount {
    param([string]$Tenant, [string]$Upn)
    return @(Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/users?`$filter=userPrincipalName eq '{0}'&`$select=id" -f $Upn) -All) | Select-Object -First 1
}

function Get-TestGroup {
    param([string]$Tenant)
    return @(Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/groups?`$filter=displayName eq '{0}'&`$select=id" -f $GroupName) -All) | Select-Object -First 1
}

$country = [string](Get-TcRemediationOption 'UsageLocation')
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $existingRows = @(Get-TcRemediationTable $t 'users' | Where-Object { $_['UPN'] -like "$Prefix*" }).Count
    Write-TcRemediationNote ("{0} {1} account(s) already in the snapshot" -f $existingRows, $Prefix)
    $accounts = @(1, 2 | ForEach-Object { '{0}-Account{1}@{2}' -f $Prefix, $_, (Get-TcMember $i 'InitialDomain') })
    foreach ($upn in $accounts) {
        $alias = $upn -replace '@.*$', ''
        Add-TcGraphAction -Tenant $t -Method POST -Uri 'v1.0/users' -Object $upn -Description "Create the disabled test account $upn" `
            -Body ([ordered]@{ accountEnabled = $false; displayName = ($alias -replace '-', ' '); mailNickname = $alias; userPrincipalName = $upn; usageLocation = $country
                                passwordProfile = @{ forceChangePasswordNextSignIn = $true; password = (Get-TcRandomPassword) } }) `
            -Test { param($a) [bool](Get-TestAccount -Tenant $a.tenant -Upn $a.object) }
    }
    Add-TcGraphAction -Tenant $t -Method POST -Uri 'v1.0/groups' -Object $GroupName -Description "Create the test group $GroupName" `
        -Body ([ordered]@{ displayName = $GroupName; description = 'POC test set, to remove at the end of the POC'; mailEnabled = $false; mailNickname = $GroupName; securityEnabled = $true }) `
        -Test { param($a) [bool](Get-TestGroup -Tenant $a.tenant) }
    Add-TcBlockAction -Tenant $t -Service Graph -Object "$GroupName, members" -Description "Add the two test accounts to the group $GroupName" -Data @{ Accounts = $accounts } `
        -Test {
            param($a)
            $g = Get-TestGroup -Tenant $a.tenant
            if (-not $g) { return $false }
            $memberRows = @(Invoke-TcGraph -Tenant $a.tenant -Uri "v1.0/groups/$((Get-TcMember $g 'id'))/members?`$select=id" -All | ForEach-Object { (Get-TcMember $_ 'id') })
            return -not @($a.data.Accounts | Where-Object { (Get-TcMember (Get-TestAccount -Tenant $a.tenant -Upn $_) 'id') -notin $memberRows }).Count
        } `
        -Block {
            param($a)
            $g = Get-TestGroup -Tenant $a.tenant
            $memberRows = @(Invoke-TcGraph -Tenant $a.tenant -Uri "v1.0/groups/$((Get-TcMember $g 'id'))/members?`$select=id" -All | ForEach-Object { (Get-TcMember $_ 'id') })
            $undos = [System.Collections.Generic.List[object]]::new()
            foreach ($upn in $a.data.Accounts) {
                $u = Get-TestAccount -Tenant $a.tenant -Upn $upn
                if ((Get-TcMember $u 'id') -in $memberRows) { continue }
                Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri "v1.0/groups/$((Get-TcMember $g 'id'))/members/`$ref" -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$((Get-TcMember $u 'id'))" } | Out-Null
                $undos.Add(@{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "v1.0/groups/$((Get-TcMember $g 'id'))/members/$((Get-TcMember $u 'id'))/`$ref" })
            }
            $a.undo = $undos.ToArray()
        }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $i = Get-TcRemediationTenant $t
    foreach ($n in 1, 2) {
        $upn = '{0}-Account{1}@{2}' -f $Prefix, $n, (Get-TcMember $i 'InitialDomain')
        if (Get-TestAccount -Tenant $t -Upn $upn) { New-TcRemediationResult OK "$upn present" } else { New-TcRemediationResult Blocking "$upn missing" }
    }
    if (Get-TestGroup -Tenant $t) { New-TcRemediationResult OK "$GroupName present" } else { New-TcRemediationResult Blocking "$GroupName missing" }
}
Close-TcRemediation

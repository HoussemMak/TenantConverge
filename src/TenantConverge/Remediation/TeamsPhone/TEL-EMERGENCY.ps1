# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Recreates in the target the emergency addresses and locations confirmed by the customer (procedure TEL-EMERGENCY).

.DESCRIPTION
    A wrong address can send help to the wrong place: each address goes through a customer decision, in decisions\TEL-EMERGENCY.csv.
    The first preview creates the file from the snapshot.
    In an -Apply run, the script reads the source again to copy the exact fields of the address and its locations, then creates them in
    the target. The address keeps its description: TEL-NUMBERS finds the location of each number through this description.
    Limit: address validation belongs to Microsoft. The script checks it, it does not force it.
#>
$c = Open-TcRemediation

$Company = (Get-TcMember (Get-TcRemediationTenant 'Target') 'Name')

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $addresses = @(Get-TcRemediationTable $t 'emergencyAddresses')
    Write-TcRemediationNote ("{0} emergency address(es), {1} place(s)" -f $addresses.Count, ((Get-TcMember ($addresses | ForEach-Object { [int]$_['Locations'] } | Measure-Object -Sum) 'Sum')))
    foreach ($a in $addresses) {
        [ordered]@{ Tenant = $t; Description = $a['Description']; Address = $a['Address']; City = $a['City']; Province = $a['State or province']; 'Postal code' = ([string]$a['Postal code']).Trim(); Country = $a['Country']
                    Places = $a['Locations']; Validation = $a['Validation']; 'Floor or room to confirm' = ''; Proposal = 'Create' }
    }
}
$decisions = @(Get-TcDecision -Name 'TEL-EMERGENCY' -Proposal @($proposals) -Key 'Tenant', 'Description' -Choice 'Create', 'Ignore')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Create' -and (Get-TcMember $_ 'Tenant') -in $c.Tenants }) {
    Add-TcBlockAction -Tenant 'Target' -Service Teams -Object (Get-TcMember $d 'Description') -Description ("Create the emergency address {0} and its locations" -f (Get-TcMember $d 'Description')) -Data @{ Source = (Get-TcMember $d 'Tenant'); Description = (Get-TcMember $d 'Description'); Company = $Company } `
        -Test { param($a) [bool]@(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsOnlineLisCivicAddress' | Where-Object { (Get-TcMember $_ 'Description') -eq $a.data.Description }).Count } `
        -Block {
            param($a)
            $x = @(Invoke-TcServiceCommand -Tenant $a.data.Source -Service Teams -Command 'Get-CsOnlineLisCivicAddress' | Where-Object { (Get-TcMember $_ 'Description') -eq $a.data.Description }) | Select-Object -First 1
            if (-not $x) { throw "Address $($a.data.Description) not found in $($a.data.Source)" }
            $places = @(Invoke-TcServiceCommand -Tenant $a.data.Source -Service Teams -Command 'Get-CsOnlineLisLocation' -Parameters @{ CivicAddressId = [guid](Get-TcMember $x 'CivicAddressId') } | Where-Object { (Get-TcMember $_ 'Location') })
            $p = @{ CompanyName = $a.data.Company; CountryOrRegion = (Get-TcText $x 'CountryOrRegion'); Description = $a.data.Description }
            foreach ($k in 'HouseNumber', 'HouseNumberSuffix', 'PreDirectional', 'StreetName', 'StreetSuffix', 'PostDirectional', 'City', 'StateOrProvince', 'PostalCode') {
                $v = ([string](Get-TcProperty $x $k '')).Trim()
                if ($v) { $p[$k] = $v }
            }
            $n = Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'New-CsOnlineLisCivicAddress' -Parameters $p
            $undos = [System.Collections.Generic.List[object]]::new()
            $undos.Add(@{ command = 'Remove-CsOnlineLisCivicAddress'; parameters = @{ CivicAddressId = (Get-TcText $n 'CivicAddressId') } })
            $a.undo = @($undos)
            foreach ($l in $places) {
                $y = Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'New-CsOnlineLisLocation' -Parameters @{ CivicAddressId = [guid](Get-TcMember $n 'CivicAddressId'); Location = (Get-TcText $l 'Location') }
                $undos.Insert(0, @{ command = 'Remove-CsOnlineLisLocation'; parameters = @{ LocationId = (Get-TcText $y 'LocationId') } })
                $a.undo = @($undos)
            }
        }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $addresses = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command 'Get-CsOnlineLisCivicAddress')
    foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Create' -and (Get-TcMember $_ 'Tenant') -eq $t }) {
        $x = $addresses | Where-Object { (Get-TcMember $_ 'Description') -eq (Get-TcMember $d 'Description') } | Select-Object -First 1
        if (-not $x) { New-TcRemediationResult Blocking ("address {0} missing from the target" -f (Get-TcMember $d 'Description')); continue }
        $v = [string](Get-TcProperty $x 'ValidationStatus' '')
        if ($v -match 'Validated') { New-TcRemediationResult OK ("address {0} validated" -f (Get-TcMember $d 'Description')) } else { New-TcRemediationResult Warning ("address {0}: validation {1}, to check before numbers are assigned" -f (Get-TcMember $d 'Description'), $v) }
    }
}
Close-TcRemediation

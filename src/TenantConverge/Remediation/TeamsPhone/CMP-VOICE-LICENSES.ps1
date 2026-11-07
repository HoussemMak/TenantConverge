# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Works out the telephony license need of the target and waits for the order (procedure CMP-VOICE-LICENSES).

.DESCRIPTION
    Need computed on the snapshot:
      - one Teams Phone add-on (MCOEV) per voice user of the source, minus the accounts excluded in the matrix;
      - one Teams Phone Resource Account license (PHONESYSTEM_VIRTUALUSER) per resource account to recreate;
      - one calling plan per user number if the decision TEL-ROUTING-TARGET is CallingPlan.
    A resource account never enters the Teams Phone need. With no decision on the provider, calling plans stay unknown.
    Limit: a license order does not go through an API. The script declares the order to place, then checks what is available in the
    target through Graph: as soon as the need is covered, the action is seen done.
#>
$c = Open-TcRemediation

$TypeFile = 'TEL-ROUTING-TARGET'
$targetType = if (Test-TcDecisionFile $TypeFile) { @(Read-TcDecisionRow $TypeFile | ForEach-Object { (Get-TcMember $_ 'Decision') } | Where-Object { $_ }) | Select-Object -First 1 }

$Needs = [ordered]@{}
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $matrix = @{}
    foreach ($l in @((Get-TcMember (Get-TcRemediationIdentity $t) 'rows'))) { $matrix[((Get-TcText $l 'Source UPN')).ToLowerInvariant()] = $l }
    $people = @(Get-TcRemediationTable $t 'teamsUsers' | Where-Object { (ConvertTo-TcBoolean $_['Enterprise Voice']) -and $_['Features'] -notmatch 'VoiceApp' })
    $excludedItems = @($people | Where-Object { (Get-TcProperty $matrix[([string]$_['UPN']).ToLowerInvariant()] 'Decision') -eq 'Exclude' }).Count
    $resources = @(Get-TcRemediationTable $t 'resourceAccounts').Count
    Write-TcRemediationNote ("{0} voice user(s), {1} excluded by the matrix; {2} resource account(s)" -f $people.Count, $excludedItems, $resources)
    $Needs['MCOEV'] = [int]$Needs['MCOEV'] + $people.Count - $excludedItems
    $Needs['PHONESYSTEM_VIRTUALUSER'] = [int]$Needs['PHONESYSTEM_VIRTUALUSER'] + $resources
    if ($targetType -eq 'CallingPlan') { $Needs['Calling plan'] = [int]$Needs['Calling plan'] + $people.Count - $excludedItems }
}
if (-not $targetType) { Write-TcRemediationAlert 'Provider not decided (TEL-ROUTING-TARGET): the number of calling plans stays unknown.' }

function Get-AvailableUnit {
    <# Units available of a license. A calling plan covers several SKUs. #>
    param([object[]]$Rows, [string]$License)
    $l = if ($License -eq 'Calling plan') { @($Rows | Where-Object { (Get-TcMember $_ 'Sku') -match 'MCOPSTN|Calling_Plan' }) } else { @($Rows | Where-Object { (Get-TcMember $_ 'Sku') -eq $License }) }
    return [int]((Get-TcMember ($l | Measure-Object -Property Available -Sum) 'Sum'))
}

$extract = @(Get-TcRemediationTable 'Target' 'licenses' | ForEach-Object { [pscustomobject]@{ Sku = [string]$_['SKU']; Available = [int]$_['Available'] } })
$rows = @(foreach ($k in $Needs.Keys) {
    $d = Get-AvailableUnit -Rows $extract -License $k
    [ordered]@{ License = $k; Need = $Needs[$k]; 'Available in target' = $d; 'To order' = [math]::Max(0, $Needs[$k] - $d) }
})
Export-TcRemediationReport -Name 'voice-licenses' -Rows $rows | Out-Null
$short = @($rows | Where-Object { (Get-TcMember $_ 'To order') -gt 0 })

if ($short.Count) {
    $details = @($short | ForEach-Object { '{0}: {1} to order (need {2}, available {3})' -f (Get-TcMember $_ 'License'), (Get-TcMember $_ 'To order'), (Get-TcMember $_ 'Need'), (Get-TcMember $_ 'Available in target') })
    Add-TcManualAction -Tenant 'Target' -Object 'Telephony license order' -Description ("Order the missing licenses: {0}" -f (@($short | ForEach-Object { (Get-TcMember $_ 'License') }) -join ', ')) -Who 'Client' -Minutes 1 -IntervalSeconds 20 `
        -Instruction (@('Place the order before the telephony cutover date:') + $details + @('The resource account license costs nothing, but it must still be purchased.', 'Never assign a resource account license to a regular user.')) `
        -WaitUntil {
            param($a)
            $s = @((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri 'v1.0/subscribedSkus') 'value') | ForEach-Object { [pscustomobject]@{ Sku = (Get-TcText $_ 'skuPartNumber'); Available = [int](Get-TcMember (Get-TcMember $_ 'prepaidUnits') 'enabled') - [int](Get-TcMember $_ 'consumedUnits') } })
            foreach ($k in $Needs.Keys) { if ((Get-AvailableUnit -Rows $s -License $k) -lt $Needs[$k]) { return $false } }
            return $true
        }
}

Invoke-TcRemediationPlan -Verify {
    $s = @((Get-TcMember (Invoke-TcGraph -Tenant 'Target' -Uri 'v1.0/subscribedSkus') 'value') | ForEach-Object { [pscustomobject]@{ Sku = (Get-TcText $_ 'skuPartNumber'); Available = [int](Get-TcMember (Get-TcMember $_ 'prepaidUnits') 'enabled') - [int](Get-TcMember $_ 'consumedUnits') } })
    foreach ($k in $Needs.Keys) {
        $d = Get-AvailableUnit -Rows $s -License $k
        if ($d -ge $Needs[$k]) { New-TcRemediationResult OK ("{0}: {1} available for a need of {2}" -f $k, $d, $Needs[$k]) } else { New-TcRemediationResult Warning ("{0}: {1} available for a need of {2}" -f $k, $d, $Needs[$k]) }
    }
}
Close-TcRemediation

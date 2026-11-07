# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the generic names present in several tenants decided (procedure CON-SHARED-MAILBOXES).

.DESCRIPTION
    Data read: list of names in the plan (info@, hr@ and so on), mailboxes, access rights, size and matrices of the sources.
    The script connects to no tenant.

    Decision: decisions\CON-SHARED-MAILBOXES.csv, one row per name.
      Common  : one mailbox in the target, the addresses of the migrated domains as aliases;
      Separate: one mailbox per business unit, renamed with the prefix.

    Result: exports\generic-mailboxes.csv for the workshop, and exports\matrix-rows.csv with the rows to enter in the matrices. The
    cutover reads these matrices: the decision has an effect only once these rows are entered.

    Limits: the usage statistics of the sources are concealed, the size is known only for the target. The team that answers is in no
    data. The mapping plan of the copy tool stays to be done by a person.
#>
$c = Open-TcRemediation

function Get-MailboxRight {
    <# Rights of a mailbox: SendAs is read under the Exchange name (encoded accents, suffix), the others under the address. #>
    param([string]$Tenant, $Mailbox)
    $names = @($Mailbox['Primary address'], $Mailbox['UPN'], $Mailbox['Alias'], $Mailbox['ObjectId'], $Mailbox['Name'])
    return @(Get-TcRemediationTable $Tenant 'mailboxPermissions' | Where-Object { $_['Mailbox'] -in $names -or ([System.Net.WebUtility]::HtmlDecode([System.Net.WebUtility]::HtmlDecode([string]$_['Mailbox'])) -replace '_[0-9a-f]{10}$', '') -in $names })
}

$Names = @(foreach ($a in Get-TcRemediationPlanAction -Procedure 'CON-SHARED-MAILBOXES') {
    foreach ($e in @($a.items)) { if ($e -match '^(.+?)@: (.+)$') { [pscustomobject]@{ Name = $Matches[1]; Addresses = @($Matches[2] -split ',\s*') } } }
})

$Backup = [System.Collections.Generic.List[object]]::new()
foreach ($n in $Names) {
    foreach ($address in (Get-TcMember $n 'Addresses')) {
        foreach ($t in (Get-TcProjectRole)) {
            $b = Get-TcRemediationTable $t 'mailboxes' | Where-Object { $_['Primary address'] -eq $address -or $_['UPN'] -eq $address } | Select-Object -First 1
            if (-not $b) { continue }
            $rights = @(Get-MailboxRight $t $b).Count
            $u = Get-TcRemediationTable $t 'mailboxUsage' | Where-Object { $_['UPN'] -eq $b['UPN'] } | Select-Object -First 1
            $row = if ($t -eq 'Target') { $null } else { Find-TcMatrixRow $t $b['UPN'] }
            $Backup.Add([pscustomobject][ordered]@{ Name = (Get-TcMember $n 'Name'); Tenant = $t; Address = $address; Upn = $b['UPN']; 'Display name' = $b['Name']; Type = $b['Type']; "Access rights" = $rights
                                                     'Size GB' = $(if ($u) { $u['Size GB'] } else { 'Hidden' }); Matrix = $(if ($row) { $row['Decision'] } else { '' }) })
            break
        }
    }
}

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    Write-TcRemediationNote ("{0} mailbox(es) affected by {1} generic name(s)" -f @($Backup | Where-Object Tenant -eq $t).Count, $Names.Count)
}
Export-TcRemediationReport -Name 'generic-mailboxes' -Rows @($Backup) | Out-Null

$proposals = foreach ($n in $Names) {
    $g = @($Backup | Where-Object Name -eq (Get-TcMember $n 'Name'))
    [ordered]@{ Name = (Get-TcMember $n 'Name'); Addresses = (Get-TcMember $n 'Addresses') -join ', '; Tenants = (@((Get-TcMember $g 'Tenant') | Select-Object -Unique) -join ', '); "Access rights" = (Get-TcMember (@($g | ForEach-Object { (Get-TcMember $_ 'Access rights') }) | Measure-Object -Sum) 'Sum'); Proposal = '' }
}
$decisions = @(Get-TcDecision -Name 'CON-SHARED-MAILBOXES' -Proposal @($proposals) -Key 'Name' -Choice 'Common', 'Separate')

$initialValue = (Get-TcMember (Get-TcRemediationTenant 'Target') 'InitialDomain')
$rows = @(foreach ($d in $decisions) {
    $g = @($Backup | Where-Object Name -eq (Get-TcMember $d 'Name'))
    $target = $g | Where-Object Tenant -eq 'Target' | Select-Object -First 1
    foreach ($s in $g | Where-Object Tenant -ne 'Target') {
        $i = Get-TcRemediationTenant (Get-TcMember $s 'Tenant')
        if ((Get-TcMember $d 'Decision') -eq 'Common') {
            if (-not $target) { Write-TcRemediationAlert ("{0}: no mailbox in the target for the name {1}, the common mailbox is still to be designated" -f (Get-TcMember $s 'Address'), (Get-TcMember $d 'Name')); continue }
            [pscustomobject][ordered]@{ Tenant = (Get-TcMember $s 'Tenant'); 'Source UPN' = (Get-TcMember $s 'Upn'); Type = 'Shared'; Decision = 'Duplicate'; 'Target UPN' = (Get-TcMember $target 'Upn'); 'Temporary UPN' = ''; 'Display name' = (Get-TcMember $s 'Display name'); Before = (Get-TcMember $s 'Matrix') }
        }
        else {
            $temporaryValue = '{0}.{1}@{2}' -f (Get-TcMember $i 'Prefix').ToLowerInvariant(), (Get-TcAddressPrefix (Get-TcMember $s 'Address')).ToLowerInvariant(), $initialValue
            [pscustomobject][ordered]@{ Tenant = (Get-TcMember $s 'Tenant'); 'Source UPN' = (Get-TcMember $s 'Upn'); Type = 'Shared'; Decision = 'Create'; 'Target UPN' = (Get-TcMember $s 'Upn'); 'Temporary UPN' = $temporaryValue; 'Display name' = ('{0}-{1}' -f (Get-TcMember $i 'Prefix'), (Get-TcMember $s 'Display name')); Before = (Get-TcMember $s 'Matrix') }
        }
    }
})

if ($rows.Count) {
    Export-TcRemediationReport -Name 'matrix-rows' -Rows $rows | Out-Null
    foreach ($t in @($rows | ForEach-Object { (Get-TcMember $_ 'Tenant') } | Select-Object -Unique | Where-Object { $_ -in $c.Tenants })) {
        $n = @($rows | Where-Object Tenant -eq $t).Count
        Add-TcManualAction -Tenant $t -Object 'Matrix' -Description ("Register {0} row(s) in the matrix of {1}" -f $n, $t) `
            -Instruction @(("Copy exports\matrix-rows.csv into the matrix of {0}: Duplicate with UpnCible, or Create with NomAffiche and UpnTemporaire prefixed." -f $t),
                        "Point each source mailbox to its target mailbox in the mapping plan of the copy tool.",
                        ('Run the preview of the source again with the cutover tool of your choice, for {0}' -f $t))
    }
}

Invoke-TcRemediationPlan
Close-TcRemediation

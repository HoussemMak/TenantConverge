# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Gathers the identity decisions and produces the validated matrix of each source (procedure IDENTITY-MATRIX).

.DESCRIPTION
    Starts from the draft of each source, as the plan computes it. Each row is settled in one place only:
      - CON-IDENTITIES.csv (CON-IDENTITIES): duplicates, likely duplicates, external accounts;
      - ENT-INACTIVE.csv (ENT-INACTIVE, ID-01): inactive accounts;
      - IDENTITY-MATRIX.csv, created here: all the other rows. The Type, Target UPN and Temporary UPN columns can be edited there
        and stay from one preview to the next.
    CON-ALIASES.csv (CON-ALIASES) fixes Temporary UPN. CMP-CROSS-GUESTS.csv and ENT-RISK.csv feed Notes; a converted guest
    becomes a Duplicate row pointing to its new UPN.

    Suggested order: run this script, CON-IDENTITIES, CON-ALIASES and ENT-INACTIVE, have them decided, then run this script again.

    When all the rows of a source are decided and the checks of the identity matrix pass, the script writes the validated matrix to
    exports\identity-matrix-<source>.csv in the log folder. A person copies it to the decisions folder, as the instruction shows. No
    tenant is read or changed: a preview is enough, it produces the matrix.

    Protected accounts (emergency, rescue, migration team, kept accounts) keep their row in the decisions files, but do not go in
    the exported matrix: when sign-ins are blocked in the source they stay open, and any account of the matrix still active fails,
    even Exclude.

    Limits: the soft match looks at the snapshot of the target. On-premises AD is seen there only through its synced accounts: a
    person must do the search in on-premises AD. The matrix holds personal data: limit the log folder to the project team.
#>
$c = Open-TcRemediation

$ColumnNames = @('Source UPN', 'Display name', 'First name', 'Name', 'Type', 'Decision', 'Target UPN', 'Temporary UPN', 'License', 'Groups', 'Notes')
$ObjectTypes = @('User', 'Shared', 'Resource')
$MatrixChoices = @('Create', 'Duplicate', 'Exclude')
$DecisionName = 'IDENTITY-MATRIX'
$DecisionKey = @('Tenant', 'Source UPN')
$Threshold = [int](Get-TcRemediationOption 'InactiveDays')
$Sku = Get-TcRemediationLicense
$TargetDomain = (Get-TcMember (Get-TcRemediationTenant 'Target') 'InitialDomain').ToLowerInvariant()

function Read-KnownDecision {
    <# Rows of a decisions file of another procedure; an empty table if it has not run yet. #>
    param([string]$Name, [string[]]$Key)
    $h = @{}
    $f = $Name
    if (Test-TcDecisionFile $f) { foreach ($l in Read-TcDecisionRow $f) { $h[(Get-TcDecisionKey $l $Key)] = $l } }
    return $h
}

function Get-RowKey { param([string]$Tenant, [string]$Upn) return ('{0}|{1}' -f $Tenant.ToLowerInvariant(), $Upn.ToLowerInvariant()) }

function Get-RowFolder {
    <# Where this row is settled: one decision per account. #>
    param($Row, [string]$Tenant, $User, $Info)
    if ((Get-TcMember $Row 'Decision') -eq 'Duplicate' -or (Get-TcMember $Row 'Notes') -match 'likely duplicate of' -or (Get-TcMember $Row 'Source UPN') -match '#EXT#' -or $duplicates[(Get-RowKey $Tenant (Get-TcMember $Row 'Source UPN'))]) { return 'Duplicates' }
    if ($User -and $User['Type'] -eq 'Member' -and (ConvertTo-TcBoolean $User['Enabled']) -and ([int]$User['Days inactive'] -ge $Threshold -or [int]$User['Days inactive'] -eq -1) -and
        [int]('0' + $User['Days since creation']) -ge $Threshold -and -not (Test-TcProtectedAccount (Get-TcMember $Row 'Source UPN') $Info)) { return 'Inactive' }
    return 'Matrix'
}

function Get-TargetMark {
    <# All the addresses already held in the target, for the soft match risk. #>
    $h = @{}
    foreach ($u in Get-TcRemediationTable 'Target' 'users') {
        $nature = if ($u['Type'] -eq 'Guest') { 'Guest' } else { 'Member' }
        foreach ($a in @($u['UPN'], $u['Email']) + @(([string]$u['Addresses']) -split ';\s*')) { if ($a -and $a -notmatch '#EXT#') { $h[$a.ToLowerInvariant()] = @{ Nature = $nature; Object = $u['UPN'] } } }
    }
    foreach ($b in Get-TcRemediationTable 'Target' 'mailboxes') { foreach ($a in ([string]$b['Addresses']) -split ';\s*') { if ($a -and -not $h[$a.ToLowerInvariant()]) { $h[$a.ToLowerInvariant()] = @{ Nature = 'Mailbox'; Object = $b['UPN'] } } } }
    return $h
}

function Get-AddressToCreate {
    param([string]$Tenant, $Row, [string[]]$Domains)
    $b = Get-TcRemediationTable $Tenant 'mailboxes' | Where-Object { $_['UPN'] -eq $Row['Source UPN'] } | Select-Object -First 1
    $allItems = @($Row['Target UPN']) + $(if ($b) { @(([string]$b['Addresses']) -split ';\s*') } else { @() })
    return @($allItems | Where-Object { $_ -and (Get-TcAddressDomain $_) -in $Domains } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
}

function Test-MatrixValidated {
    <# The same checks as the identity matrix check, on the snapshot; returns the inconsistencies in plain words. #>
    param([object[]]$Rows, $Info, $Users)
    $e = [System.Collections.Generic.List[string]]::new()
    foreach ($l in $Rows) {
        $id = $l['Source UPN']
        if ($l['Type'] -notin $ObjectTypes) { $e.Add("${id}: unknown type '$($l['Type'])'") }
        if (-not $Users[$id.ToLowerInvariant()]) { $e.Add("${id}: account missing from the source tenant") }
        if ($l['Decision'] -eq 'Create') {
            if ((Get-TcAddressDomain $l['Temporary UPN']) -ne $TargetDomain -or $l['Temporary UPN'] -match '#') { $e.Add("${id}: UpnTemporaire must be a valid address in @$TargetDomain") }
            if ((Get-TcAddressDomain $l['Target UPN']) -notin (Get-TcMember $Info 'Domains')) { $e.Add("${id}: UpnCible must use a migrated domain ($((Get-TcMember $Info 'Domains') -join ', '))") }
        }
        if ($l['Decision'] -eq 'Duplicate' -and -not $targetAccounts[([string]$l['Target UPN']).ToLowerInvariant()]) { $e.Add("${id}: target account $($l['Target UPN']) not found in the target") }
    }
    foreach ($col in 'Source UPN', 'Temporary UPN', 'Target UPN') {
        $groups = @($Rows | Where-Object { $_['Decision'] -ne 'Exclude' -and $_[$col] } | Group-Object { ([string]$_[$col]).ToLowerInvariant() } | Where-Object { (Get-TcCount $_) -gt 1 })
        if ($col -eq 'Target UPN') { $groups = @($groups | Where-Object { @((Get-TcMember $_ 'Group') | Where-Object { $_['Decision'] -eq 'Create' }).Count -gt 1 }) }
        foreach ($g in $groups) { $e.Add("$col en double: $((Get-TcMember $g 'Name'))") }
    }
    $presentItems = @($Rows | ForEach-Object { ([string]$_['Source UPN']).ToLowerInvariant() })
    foreach ($u in $Users.Values | Where-Object { $_['Type'] -eq 'Member' -and (ConvertTo-TcBoolean $_['Enabled']) -and ([string]$_['UPN']).ToLowerInvariant() -notin $presentItems -and -not (Test-TcProtectedAccount $_['UPN'] $Info) }) {
        $e.Add("$($u['UPN']): active member account missing from the matrix")
    }
    return @($e)
}

$duplicates = Read-KnownDecision 'CON-IDENTITIES' $DecisionKey
$inactive = Read-KnownDecision 'ENT-INACTIVE' @('Tenant', 'Account')
$alias = @{}
foreach ($a in (Read-KnownDecision 'CON-ALIASES' @('Tenant', 'Alias', 'Object')).Values) { if ($a.'Decision' -eq 'Prefix' -and $a.'Target alias') { $alias[(Get-RowKey $a.Tenant $a.Object)] = $a.'Target alias' } }
$crossOnes = @{}
foreach ($x in (Read-KnownDecision 'CMP-CROSS-GUESTS' @('Tenant', 'Id')).Values) { if ((Get-TcMember $x 'Email')) { $crossOnes[(Get-RowKey (Get-TcMember $x 'Tenant') (Get-TcMember $x 'Email'))] = $x } }
$risks = Read-KnownDecision 'ENT-RISK' @('Account')
$atRisk = @{}
foreach ($r in Get-TcRemediationTable 'Target' 'riskyUsers') { $atRisk[([string]$r['UPN']).ToLowerInvariant()] = 1 }
$targetAccounts = @{}
foreach ($u in Get-TcRemediationTable 'Target' 'users') { if ($u['Type'] -eq 'Member') { $targetAccounts[([string]$u['UPN']).ToLowerInvariant()] = 1 } }
foreach ($x in $crossOnes.Values) { if ((Get-TcMember $x 'Decision') -eq 'Convert' -and (Get-TcMember $x 'UPN after conversion')) { $targetAccounts[$x.'UPN after conversion'.ToLowerInvariant()] = 1 } }
$marks = Get-TargetMark

$entries = Read-KnownDecision $DecisionName $DecisionKey
$drafts = @{}
$proposals = [System.Collections.Generic.List[object]]::new()
foreach ($t in $c.Tenants) {
    $i = Get-TcRemediationTenant $t
    $u = Get-TcRowIndex (Get-TcRemediationTable $t 'users') 'UPN'
    $drafts[$t] = @(Import-TcMatrixDraft $t)
    # resource accounts are recreated by TEL-VOICE-APPS: in the matrix, they would be created twice
    $resources = @{}
    foreach ($r in Get-TcRemediationTable $t 'resourceAccounts') { $resources[([string]$r['UPN']).ToLowerInvariant()] = 1 }
    foreach ($l in $drafts[$t]) {
        if ((Get-RowFolder $l $t $u[(Get-TcMember $l 'Source UPN').ToLowerInvariant()] $i) -ne 'Matrix') { continue }
        $s = $entries[(Get-RowKey $t (Get-TcMember $l 'Source UPN'))]
        $proposals.Add([ordered]@{ Tenant = $t; 'Source UPN' = (Get-TcMember $l 'Source UPN'); Name = (Get-TcMember $l 'Display name'); Type = $(if ($s -and (Get-TcMember $s 'Type')) { (Get-TcMember $s 'Type') } else { (Get-TcMember $l 'Type') })
                                      'Target UPN' = $(if ($s -and (Get-TcMember $s 'Target UPN')) { (Get-TcMember $s 'Target UPN') } else { (Get-TcMember $l 'Target UPN') }); 'Temporary UPN' = $(if ($s -and (Get-TcMember $s 'Temporary UPN')) { (Get-TcMember $s 'Temporary UPN') } else { (Get-TcMember $l 'Temporary UPN') })
                                      License = (Get-TcMember $l 'License'); Notes = (Get-TcMember $l 'Notes')
                                      Proposal = $(if ($resources[(Get-TcMember $l 'Source UPN').ToLowerInvariant()] -or (Test-TcProtectedAccount (Get-TcMember $l 'Source UPN') $i)) { 'Exclude' } elseif ((Get-TcMember $l 'Decision') -in $MatrixChoices) { (Get-TcMember $l 'Decision') } elseif ((Get-TcMember $l 'Notes') -match 'disabled account') { 'Exclude' } else { '' }) })
    }
}

$decisions = @{}
foreach ($d in Get-TcDecision -Name $DecisionName -Proposal @($proposals) -Key $DecisionKey -Choice $MatrixChoices) { $decisions[(Get-RowKey (Get-TcMember $d 'Tenant') (Get-TcMember $d 'Source UPN'))] = $d }

$Stores = @{}
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Identity matrix'
    $i = Get-TcRemediationTenant $t
    $users = Get-TcRowIndex (Get-TcRemediationTable $t 'users') 'UPN'
    $preview = (Get-TcMember (Get-TcRemediationIdentity $t) 'account')
    Write-TcRemediationNote ("Draft: {0} row(s), {1} to create, {2} duplicate(s), {3} to validate, including {4} Bookings page(s)" -f (Get-TcCount $drafts[$t]), (Get-TcMember $preview 'Create'), (Get-TcMember $preview 'Duplicate'), (Get-TcMember $preview 'To review'), (Get-TcMember $preview 'Bookings'))
    $pending = @{ Duplicates = 0; Inactive = 0; Matrix = 0 }
    $rows = [System.Collections.Generic.List[object]]::new()
    $toCreate = [System.Collections.Generic.List[object]]::new()
    foreach ($l in $drafts[$t]) {
        $k = Get-RowKey $t (Get-TcMember $l 'Source UPN')
        $folder = Get-RowFolder $l $t $users[(Get-TcMember $l 'Source UPN').ToLowerInvariant()] $i
        $d = switch ($folder) { 'Duplicates' { $duplicates[$k] } 'Inactive' { $inactive[$k] } default { $decisions[$k] } }
        $choice = if ($d) { (Get-TcText $d 'Decision') } else { '' }
        $x = [ordered]@{}
        foreach ($col in $ColumnNames) { $x[$col] = (Get-TcText $l $col) }
        $notes = @((Get-TcMember $l 'Notes'))

        if ($folder -eq 'Matrix' -and $d) { $x.Type = (Get-TcMember $d 'Type'); $x.'Target UPN' = (Get-TcMember $d 'Target UPN'); $x.'Temporary UPN' = (Get-TcMember $d 'Temporary UPN') }
        $cross = $crossOnes[(Get-RowKey $t (Get-TcMember $l 'Source UPN'))]
        if (-not $cross -and (Get-TcMember $l 'Target UPN')) { $cross = $crossOnes[(Get-RowKey $t (Get-TcMember $l 'Target UPN'))] }
        $convertedOne = $cross -and (Get-TcMember $cross 'Decision') -eq 'Convert' -and (Get-TcMember $cross 'UPN after conversion')
        if ($cross -and (Get-TcMember $cross 'Decision')) { $notes += "cross-tenant guest: $((Get-TcMember $cross 'Decision'))" }
        if ($convertedOne) { $choice = 'Duplicate'; $x.'Target UPN' = (Get-TcMember $cross 'UPN after conversion') }

        if ($choice -notin $MatrixChoices) {
            $pending[$folder]++
            if ((Get-TcMember $l 'Decision') -eq 'Create') { $toCreate.Add($x) }
            $x.Decision = 'To review'; $rows.Add($x); continue
        }
        $x.Decision = $choice
        switch ($choice) {
            'Duplicate' {
                if ($folder -eq 'Duplicates' -and (Get-TcMember $d 'Single account') -and -not $convertedOne) { $x.'Target UPN' = (Get-TcMember $d 'Single account') }
                $x.'Temporary UPN' = ''; $x.License = ''
                $target = (Get-TcMember $x 'Target UPN').ToLowerInvariant()
                if ($atRisk[$target]) {
                    $r = $risks[$target]
                    if ($r -and (Get-TcMember $r 'Decision')) { $notes += "target account at risk: $((Get-TcMember $r 'Decision'))" } else { Write-TcRemediationAlert ("{0}: the target account {1} is at risk, with no decision in ENT-RISK.csv" -f $t, (Get-TcMember $x 'Target UPN')) }
                }
            }
            'Exclude' { $x.'Target UPN' = ''; $x.'Temporary UPN' = ''; $x.License = '' }
            'Create' {
                if ((Get-TcAddressDomain (Get-TcMember $x 'Target UPN')) -notin (Get-TcMember $i 'Domains')) { $x.'Target UPN' = (Get-TcMember $l 'Source UPN') }
                if (-not (Get-TcMember $x 'Temporary UPN')) { $x.'Temporary UPN' = '{0}.{1}@{2}' -f (Get-TcMember $i 'Prefix').ToLowerInvariant(), (Get-TcAddressPrefix (Get-TcMember $l 'Source UPN')).ToLowerInvariant(), $TargetDomain }
                if ($alias[$k]) { $x.'Temporary UPN' = '{0}@{1}' -f $alias[$k], $TargetDomain }
                if ((Get-TcMember $x 'Type') -eq 'User' -and -not (Get-TcMember $x 'License')) { $x.License = $Sku }
            }
        }
        if ($d -and (Get-TcMember $d 'Note')) { $notes += (Get-TcMember $d 'Note') }
        $x.Notes = (@($notes | Where-Object { $_ }) -join ' ; ')
        if ($choice -eq 'Create') { $toCreate.Add($x) }
        $rows.Add($x)
    }

    $softRows = @(foreach ($l in $toCreate) {
        foreach ($a in Get-AddressToCreate $t $l (Get-TcMember $i 'Domains')) { if ($marks[$a]) { [ordered]@{ Tenant = $t; Account = $l['Source UPN']; Address = $a; Nature = (Get-TcMember $marks[$a] 'Nature'); 'Target object' = (Get-TcMember $marks[$a] 'Object') } } }
    })
    if ($softRows.Count) {
        Export-TcRemediationReport -Name "loose-match-$t" -Rows $softRows | Out-Null
        Write-TcRemediationNote ("{0} address(es) to create already exist in the target, including {1} on guests (CMP-CROSS-GUESTS)" -f $softRows.Count, @($softRows | Where-Object { $_['Nature'] -eq 'Guest' }).Count)
    }
    Add-TcManualAction -Tenant 'Target' -Object "Loose match ($t)" -Description ("Look up the UpnCible values and the addresses to create of {0} in the on-premises AD of the target" -f $t) `
        -Instruction @('A UPN or an address already present in on-premises AD can trigger a soft match with the cloud account. Settle each case object by object; do not block soft matching blindly, the hybrid joins of the target depend on it.')

    $remainingItems = (Get-TcMember $pending 'Duplicates') + (Get-TcMember $pending 'Inactive') + (Get-TcMember $pending 'Matrix')
    if ($remainingItems) {
        Write-TcRemediationNote ("{0} row(s) without a decision: {1} in CON-IDENTITIES.csv, {2} in ENT-INACTIVE.csv, {3} in {4}.csv; validated matrix not produced" -f $remainingItems, (Get-TcMember $pending 'Duplicates'), (Get-TcMember $pending 'Inactive'), (Get-TcMember $pending 'Matrix'), $DecisionName)
        $script:TcRemediationRun['Pending'] += (Get-TcMember $pending 'Duplicates') + (Get-TcMember $pending 'Inactive')
        continue
    }

    $exported = @($rows | Where-Object { -not (Test-TcProtectedAccount $_['Source UPN'] $i) })
    $errors = @(Test-MatrixValidated -Rows $exported -Info $i -Users $users)
    if ($errors.Count) {
        $f = Export-TcRemediationReport -Name "matrix-check-$t" -Rows @($errors | ForEach-Object { [ordered]@{ Tenant = $t; 'Inconsistency' = $_ } })
        Write-TcRemediationAlert ("{0}: {1} inconsistency(ies), validated matrix not produced; detail: {2}" -f $t, $errors.Count, $f)
        continue
    }

    $f = Export-TcRemediationReport -Name "identity-matrix-$t" -Rows $exported
    $n = @{}; foreach ($v in $MatrixChoices) { $n[$v] = @($exported | Where-Object { $_['Decision'] -eq $v }).Count }
    Write-TcRemediationNote ("Validated matrix: {0} row(s), {1} to create, {2} duplicate(s), {3} excluded, {4} protected account(s) removed" -f $exported.Count, (Get-TcMember $n 'Create'), (Get-TcMember $n 'Duplicate'), (Get-TcMember $n 'Exclude'), ($rows.Count - $exported.Count))
    $destination = Join-Path (Get-TcDecisionFolder) ("identity-matrix-{0}.csv" -f $t)
    if (Test-Path -LiteralPath $destination) { Write-TcRemediationNote 'A matrix already exists in the decisions folder: compare before replacing it' }
    $object = "identity-matrix-$t.csv"
    $Stores[$object] = @{ Export = $f; Target = $destination }
    Add-TcManualAction -Tenant $t -Object $object -Minutes 0 -Description ("Copy the validated matrix of {0} to the decisions folder" -f $t) `
        -Instruction @("Copy: $f", "To: $destination", "Then run New-TcPlan again, and fix what the identity matrix check and the name conflict check report.") `
        -WaitUntil { param($a) $x = $Stores[$a.object]; (Test-Path -LiteralPath (Get-TcMember $x 'Target')) -and (Get-TcMember (Get-FileHash -LiteralPath (Get-TcMember $x 'Target')) 'Hash') -eq (Get-TcMember (Get-FileHash -LiteralPath (Get-TcMember $x 'Export')) 'Hash') }
}

Invoke-TcRemediationPlan
Close-TcRemediation

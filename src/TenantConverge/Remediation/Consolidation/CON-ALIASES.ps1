# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Prepares the prefix of the aliases that collide with the target or another source (procedure CON-ALIASES).

.DESCRIPTION
    Starts from the colliding aliases in the plan and finds the objects in each source.
      - Security groups with no mail: set aside, their alias need not be unique.
      - Generic mailboxes (shared, rooms): set aside, their fate is decided in CON-SHARED-MAILBOXES.
      - Accounts marked Duplicate in the draft: set aside, no object is created in the target.
    decisions\CON-ALIASES.csv holds the rest: Prefix or Do not migrate. The Target alias column can be edited, and stays from one
    preview to the next. For an account, the alias comes from Temporary UPN; for a group, it gets the prefix of the source.

    The script changes neither the matrix nor any setting. IDENTITY-MATRIX takes the decided aliases of accounts into Temporary UPN;
    the decided aliases of groups go in the copy plan.

    The check asks Exchange Online of the target (Get-Recipient): each chosen alias must be free there. Do not rename an existing
    object of the target without a customer decision.
#>
$c = Open-TcRemediation

$DecisionName = 'CON-ALIASES'
$DecisionKey = @('Tenant', 'Alias', 'Object')
$GenericTypes = @('SharedMailbox', 'RoomMailbox', 'EquipmentMailbox', 'SchedulingMailbox')

$entries = Read-TcDecisionEntry $DecisionName $DecisionKey
$collisions = @((Get-TcMember (Get-TcRemediationPlanAction -Procedure 'CON-ALIASES') 'items') | ForEach-Object { (([string]$_ -split ': ')[0]).Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Unique)

$targetAlias = @{}
foreach ($table in 'mailboxes', 'groups', 'microsoft365Groups', 'distributionGroups') {
    foreach ($x in Get-TcRemediationTable 'Target' $table) { $a = ([string]$x['Alias']).ToLowerInvariant(); if ($a) { $targetAlias[$a] = 1 } }
}

$proposals = [System.Collections.Generic.List[object]]::new()
$chosenRows = @{}
foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Colliding aliases'
    if ($t -eq 'Target') { Write-TcRemediationNote ("{0} colliding aliases in the plan, {1} aliases already taken in the target" -f $collisions.Count, $targetAlias.Count); continue }
    $i = Get-TcRemediationTenant $t
    $prefix = ((Get-TcText $i 'Prefix')).ToLowerInvariant()
    $draft = @{}
    foreach ($l in Import-TcMatrixDraft $t) { $draft[$l.'Source UPN'.ToLowerInvariant()] = $l }
    $n = @{ NoMail = 0; GenericItems = 0; Duplicates = 0; Rows = 0 }

    foreach ($b in Get-TcRemediationTable $t 'mailboxes' | Where-Object { ([string]$_['Alias']).ToLowerInvariant() -in $collisions }) {
        if ($b['Type'] -in $GenericTypes) { $n.GenericItems++; continue }
        $l = $draft[([string]$b['UPN']).ToLowerInvariant()]
        if (-not $l -or -not (Get-TcMember $l 'Temporary UPN')) { $n.Duplicates++; continue }
        $proposals.Add([ordered]@{ Tenant = $t; Alias = $b['Alias']; Object = $b['UPN']; 'Object type' = 'Account'; 'Target alias' = (Get-TcAddressPrefix (Get-TcMember $l 'Temporary UPN')); Free = ''; Proposal = 'Prefix' })
        $n.Rows++
    }
    foreach ($g in Get-TcRemediationTable $t 'groups' | Where-Object { ([string]$_['Alias']).ToLowerInvariant() -in $collisions }) {
        if (-not $g['Email']) { $n.NoMail++; continue }
        $proposals.Add([ordered]@{ Tenant = $t; Alias = $g['Alias']; Object = $g['Email']; 'Object type' = "Group: $($g['Type'])"; 'Target alias' = ('{0}-{1}' -f $prefix, ([string]$g['Alias']).ToLowerInvariant()); Free = ''; Proposal = 'Prefix' })
        $n.Rows++
    }
    Write-TcRemediationNote ("{0} object(s) to settle; set aside: {1} generic mailbox(es) (CON-SHARED-MAILBOXES), {2} duplicate(s), {3} group(s) without mail" -f (Get-TcMember $n 'Rows'), (Get-TcMember $n 'GenericItems'), (Get-TcMember $n 'Duplicates'), (Get-TcMember $n 'NoMail'))

    foreach ($g in @(Get-TcSourceGroup -Tenant $t)) {
        $alias = ((Get-TcText $g 'name') -replace '[^A-Za-z0-9\-]', '').ToLowerInvariant()
        if (-not $alias.StartsWith("$prefix-")) { Write-TcRemediationAlert ("{0}: the group {1} of the configuration is not prefixed" -f $t, (Get-TcMember $g 'name')) }
        if ($targetAlias[$alias]) { Write-TcRemediationAlert ("{0}: the alias {1}, taken from the group {2}, already exists in the target" -f $t, $alias, (Get-TcMember $g 'name')) }
    }
}

foreach ($p in $proposals) {
    $s = $entries[(Get-TcDecisionKey ([pscustomobject]$p) $DecisionKey)]
    if ($s -and (Get-TcMember $s 'Target alias')) { $p['Target alias'] = (Get-TcMember $s 'Target alias') }
    $a = ([string]$p['Target alias']).ToLowerInvariant()
    $p.Free = $(if ($a -and -not $targetAlias[$a] -and -not $chosenRows[$a]) { 'Yes' } else { 'No' })
    if ($a) { $chosenRows[$a] = 1 }
    if ((Get-TcMember $p 'Free') -eq 'No') { Write-TcRemediationAlert ("{0}: the target alias {1} is not free" -f (Get-TcMember $p 'Tenant'), $p['Target alias']) }
}

$decisions = @(Get-TcDecision -Name $DecisionName -Proposal @($proposals) -Key $DecisionKey -Choice 'Prefix', 'Do not migrate')

foreach ($t in $c.Tenants | Where-Object { $_ -ne 'Target' }) {
    $groups = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'Decision') -eq 'Prefix' -and (Get-TcMember $_ 'Object type') -like 'Group*' })
    if (-not $groups.Count) { continue }
    $f = Export-TcRemediationReport -Name "group-aliases-$t" -Rows $groups
    Add-TcManualAction -Tenant 'Target' -Object "Group aliases ($t)" -Description ("Record {0} group alias(es) of {1} in the copy plan" -f $groups.Count, $t) `
        -Instruction @("List: $f", 'The alias of each copied group must be the one in the Target alias column.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $takenOnes = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Prefix' -and (Get-TcMember $_ 'Target alias') } | Where-Object {
        @(Invoke-TcServiceCommand -Tenant $t -Service Exo -Command 'Get-Recipient' -Parameters @{ Filter = ("Alias -eq '{0}'" -f (Get-TcMember $_ 'Target alias').Replace("'", "''")) }).Count })
    if ($takenOnes.Count) { New-TcRemediationResult Blocking ("{0} aliases already taken in the target: {1}" -f $takenOnes.Count, (@((Get-TcMember $takenOnes 'Target alias')) -join ', ')) } else { New-TcRemediationResult OK 'all chosen aliases are free in the target' }
}
Close-TcRemediation

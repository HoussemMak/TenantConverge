# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Recreates in the target the chosen lists and contacts, then gives them back their original addresses (procedure EXO-RECIPIENTS).

.DESCRIPTION
    RELEASE-DOMAIN releases dynamic lists, contacts and mail users in the source; this script recreates them and gives the addresses back.

    Data read: lists, dynamic lists and contacts of each source, matrices. Guests also show as mail users: they are set aside, they
    belong to the invitations.

    Decision: decisions\EXO-RECIPIENTS.csv, Recreate or Drop. The Note column completes the decision:
      list with no manager found: the address of an owner in the target;
      dynamic list              : the rewritten filter, required, because a filter of the source does not aim at the right objects.

    Three steps, the same script runs again:
      1. before the cutover: read the addresses of the source into decisions\EXO-RECIPIENTS-ORIGIN.csv. This read must come before
         RELEASE-DOMAIN: the aliases of lists and contacts are not in the snapshot;
      2. before the cutover: creation with the prefix of the tenant, contacts first, because a list can contain them;
      3. after the domains are verified: adding the original addresses. While the domain is not accepted in the target, the action is postponed.
    Without the read, step 3 only takes the primary address of the list, and an alert says so.

    Limits: members are read in the source at run time; a member with no target account is reported and not added. A chosen mail user
    is recreated as a contact: it has no mailbox and no account to carry over.
#>
$c = Open-TcRemediation

$AddressFile = 'EXO-RECIPIENTS-ORIGIN'
$TargetDomains = @(Get-TcRemediationTable 'Target' 'acceptedDomains' | ForEach-Object { ([string]$_['Domain']).ToLowerInvariant() })
$TargetNames = @(Get-TcRemediationTable 'Target' 'groups' | ForEach-Object { $_['Name'] })
$TargetContacts = @(Get-TcRemediationTable 'Target' 'contacts' | ForEach-Object { ([string]$_['External address'] -replace '^smtp:', '').ToLowerInvariant() })

function Get-TargetRecipient {
    <# Recipient of the target, or $null. #>
    param([string]$Identity)
    try { return (Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-Recipient' -Parameters @{ Identity = $Identity }) } catch { return $null }
}

function Get-TargetAlias {
    param([string]$Prefix, [string]$Alias)
    return ('{0}-{1}' -f $Prefix.ToLowerInvariant(), ($Alias -replace '[^A-Za-z0-9\.\-_]', '')).ToLowerInvariant()
}

function Find-TargetAccountList {
    <# Possible target identities of a source account: Target UPN, then Temporary UPN for an account not cut over yet. #>
    param([string]$Tenant, [string]$Address)
    $b = Get-TcRemediationTable $Tenant 'mailboxes' | Where-Object { $_['Primary address'] -eq $Address -or $_['UPN'] -eq $Address -or $_['ObjectId'] -eq $Address } | Select-Object -First 1
    $key = if ($b) { $b['UPN'] } else { $Address }
    $l = @((Get-TcMember (Get-TcRemediationIdentity $Tenant) 'rows')) | Where-Object { $_['Source UPN'] -eq $key } | Select-Object -First 1
    if (-not $l -or $l['Decision'] -notin 'Create', 'Duplicate') { return @() }
    return @(@($l['Target UPN'], $l['Temporary UPN']) | Where-Object { $_ })
}

function Resolve-TargetAccount {
    <# Live recipient of the target for a source account; $null if the account is not there yet. #>
    param([string]$Tenant, [string]$Address)
    foreach ($i in Find-TargetAccountList $Tenant $Address) {
        $r = Get-TargetRecipient $i
        if ($r) { return $r }
    }
    return $null
}

$Sources = @{}
$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $i = Get-TcRemediationTenant $t
    $lists = @(Get-TcRemediationTable $t 'distributionGroups')
    $dynamicLists = @(Get-TcRemediationTable $t 'dynamicGroups')
    $contacts = @(Get-TcRemediationTable $t 'contacts')
    if (-not ($lists.Count + $contacts.Count) -and -not (Test-TcCollectionComplete $t 'contacts')) { Write-TcRemediationAlert 'Recipient collection incomplete: run Invoke-TcAssessment again'; continue }
    $guests = @(Get-TcRemediationTable $t 'users' | Where-Object { $_['Type'] -eq 'Guest' } | ForEach-Object { ([string]$_['Email']).ToLowerInvariant() })
    $chosenRows = @($contacts | Where-Object { $_['Type'] -eq 'Contact' -or ([string]$_['External address'] -replace '^smtp:', '').ToLowerInvariant() -notin $guests })
    Write-TcRemediationNote ("{0} list(s), {1} dynamic list(s), {2} contact(s) and mail user(s), {3} guest(s) set aside" -f $lists.Count, $dynamicLists.Count, $contacts.Count, ($contacts.Count - $chosenRows.Count))
    $Sources[$t] = @{ Lists = $lists; DynamicLists = $dynamicLists; Contacts = $chosenRows }

    foreach ($l in $lists) {
        $already = ('{0}-{1}' -f (Get-TcMember $i 'Prefix'), $l['Name']) -in $TargetNames
        [ordered]@{ Tenant = $t; Kind = 'List'; Name = $l['Name']; Address = $l['Address']; 'Detail' = ("{0} member(s)" -f $l['Members']); Proposal = $(if ($l['Name'] -match '^checkpoint_' -or $already) { 'Drop' } else { 'Recreate' }) }
    }
    foreach ($l in $dynamicLists) {
        [ordered]@{ Tenant = $t; Kind = 'Dynamic list'; Name = $l['Name']; Address = $l['Address']; 'Detail' = $l['Filter']; Proposal = '' }
    }
    foreach ($l in $chosenRows) {
        $address = [string]$l['External address'] -replace '^smtp:', ''
        $internal = (Get-TcAddressDomain $address) -in $TargetDomains
        $knownOne = $address.ToLowerInvariant() -in $TargetContacts
        [ordered]@{ Tenant = $t; Kind = $l['Type']; Name = $l['Name']; Address = $address; 'Detail' = $(if ($internal) { 'Address already in target' } elseif ($knownOne) { 'Contact already in target' } else { '' })
                    Proposal = $(if ($internal -or $knownOne) { 'Drop' } elseif ($l['Type'] -eq 'Contact') { 'Recreate' } else { '' }) }
    }
}

$decisions = @(Get-TcDecision -Name 'EXO-RECIPIENTS' -Proposal @($proposals) -Key 'Tenant', 'Kind', 'Address' -Choice 'Recreate', 'Drop')
$chosenPolicies = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -in $c.Tenants -and (Get-TcMember $_ 'Decision') -eq 'Recreate' })

$Backup = @()
if (Test-TcDecisionFile $AddressFile) { $Backup = @(Read-TcDecisionRow $AddressFile) }

foreach ($t in @($chosenPolicies | ForEach-Object { (Get-TcMember $_ 'Tenant') } | Select-Object -Unique)) {
    if (-not @($Backup | Where-Object Tenant -eq $t).Count) { Write-TcRemediationNote ("{0}: addresses still to read; until then, only the primary address of the lists is planned" -f $t) }
    Add-TcBlockAction -Tenant $t -Service Exo -Object 'Addresses read' -Data @{ Domains = @((Get-TcMember (Get-TcRemediationTenant $t) 'Domains')) } -Description ("Read the addresses of the objects kept in {0}, before RELEASE-DOMAIN" -f $t) `
        -Reason "Read only in the source; the result stays in decisions\ for the third step." `
        -Test { param($a) @($Backup | Where-Object Tenant -eq $a.tenant).Count -gt 0 } `
        -Block {
            param($a)
            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($d in $chosenPolicies | Where-Object Tenant -eq $a.tenant) {
                $command = switch ((Get-TcMember $d 'Kind')) { 'List' { 'Get-DistributionGroup' } 'Dynamic list' { 'Get-DynamicDistributionGroup' } 'Contact' { 'Get-MailContact' } default { 'Get-MailUser' } }
                try { $o = Invoke-TcServiceCommand -Tenant $a.tenant -Service Exo -Command $command -Parameters @{ Identity = (Get-TcMember $d 'Address') } } catch { Write-TcRemediationAlert ("{0} not found in the source: addresses not read" -f (Get-TcMember $d 'Address')); continue }
                foreach ($x in @((Get-TcMember $o 'EmailAddresses') | Where-Object { $_ -match '^smtp:' } | ForEach-Object { $_ -replace '^smtp:', '' })) {
                    if ((Get-TcAddressDomain $x) -in $a.data.Domains) { $rows.Add([pscustomobject][ordered]@{ Tenant = $a.tenant; Kind = (Get-TcMember $d 'Kind'); Name = (Get-TcMember $d 'Name'); Address = $x.ToLowerInvariant() }) }
                }
            }
            @(@($script:TcRemediationRun['Backup']) + @($rows)) | Export-TcDecisionRow $AddressFile
            $script:TcRemediationRun['Backup'] = @(Read-TcDecisionRow $AddressFile)
        }
}

foreach ($d in $chosenPolicies | Where-Object { (Get-TcMember $_ 'Kind') -notin 'List', 'Dynamic list' }) {
    $i = Get-TcRemediationTenant (Get-TcMember $d 'Tenant')
    $name = '{0}-{1}' -f (Get-TcMember $i 'Prefix'), (Get-TcMember $d 'Name')
    $alias = Get-TargetAlias (Get-TcMember $i 'Prefix') (Get-TcAddressPrefix (Get-TcMember $d 'Address'))
    Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'New-MailContact' -Parameters @{ Name = $name; ExternalEmailAddress = (Get-TcMember $d 'Address'); Alias = $alias } -Object $name -Description ("Create the contact {0} to {1}" -f $name, (Get-TcMember $d 'Address')) `
        -Test { param($a) [bool]((Get-TargetRecipient $a.parameters.Name) -or (Get-TargetRecipient $a.parameters.ExternalEmailAddress)) } `
        -Undo @{ command = 'Remove-MailContact'; parameters = @{ Identity = $name } }
}

foreach ($d in $chosenPolicies | Where-Object Kind -eq 'List') {
    $t = (Get-TcMember $d 'Tenant')
    $i = Get-TcRemediationTenant $t
    $l = (Get-TcMember $Sources[$t] 'Lists') | Where-Object { $_['Address'] -eq (Get-TcMember $d 'Address') } | Select-Object -First 1
    if (-not $l) { Write-TcRemediationAlert ("{0}: list missing from the snapshot" -f (Get-TcMember $d 'Address')); continue }
    $name = '{0}-{1}' -f (Get-TcMember $i 'Prefix'), (Get-TcMember $d 'Name')
    $managers = @([string]$l['Managers'] -split ';\s*' | Where-Object { $_ })
    $note = ((Get-TcText $d 'Note')).Trim()
    if (-not $note -and -not @($managers | Where-Object { @(Find-TargetAccountList $t $_).Count }).Count) { Write-TcRemediationAlert ("{0}: no manager found in the matrix, enter an owner from the target in the Note column. List not created." -f (Get-TcMember $d 'Address')); continue }
    Add-TcBlockAction -Tenant 'Target' -Service Exo -Object $name `
        -Data @{ Source = $t; Name = $name; Alias = (Get-TargetAlias (Get-TcMember $i 'Prefix') $l['Alias']); Address = (Get-TcMember $d 'Address'); Managers = $managers; Note = $note; Prefix = (Get-TcMember $i 'Prefix'); ExternalUsers = (ConvertTo-TcBoolean $l['External senders allowed']); Concealed = (ConvertTo-TcBoolean $l['Hidden']) } `
        -Description ("Create the list {0} ({1} member(s) in the source)" -f $name, $l['Members']) `
        -Test { param($a) [bool](Get-TargetRecipient $a.data.Name) } `
        -Undo @{ command = 'Remove-DistributionGroup'; parameters = @{ Identity = $name; BypassSecurityGroupManagerCheck = $true } } `
        -Block {
            param($a)
            $x = $a.data
            $memberRows = [System.Collections.Generic.List[string]]::new()
            $missing = [System.Collections.Generic.List[string]]::new()
            $sources = @(Invoke-TcServiceCommand -Tenant (Get-TcMember $x 'Source') -Service Exo -Command 'Get-DistributionGroupMember' -Parameters @{ Identity = (Get-TcMember $x 'Address'); ResultSize = 'Unlimited' })
            foreach ($m in $sources) {
                $address = (Get-TcText $m 'PrimarySmtpAddress')
                $r = if ((Get-TcText $m 'RecipientTypeDetails') -match 'Contact') { Get-TargetRecipient ('{0}-{1}' -f (Get-TcMember $x 'Prefix'), (Get-TcMember $m 'Name')) } else { Resolve-TargetAccount (Get-TcMember $x 'Source') $address }
                if ($r) { $memberRows.Add((Get-TcText $r 'PrimarySmtpAddress')) } else { $missing.Add($address) }
            }
            $owners = @(if ((Get-TcMember $x 'Note')) { (Get-TcMember $x 'Note') } else { foreach ($g in (Get-TcMember $x 'Managers')) { $r = Resolve-TargetAccount (Get-TcMember $x 'Source') $g; if ($r) { (Get-TcText $r 'PrimarySmtpAddress') } } })
            if (-not $owners.Count) { throw ("No owner found in the target for {0}: enter their address in the Note column" -f (Get-TcMember $x 'Name')) }
            $p = @{ Name = (Get-TcMember $x 'Name'); Alias = (Get-TcMember $x 'Alias'); Type = 'Distribution'; ManagedBy = $owners; RequireSenderAuthenticationEnabled = (-not (Get-TcMember $x 'ExternalUsers')) }
            if ($memberRows.Count) { $p.Members = @($memberRows) }
            Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'New-DistributionGroup' -Parameters $p | Out-Null
            if ((Get-TcMember $x 'Concealed')) { Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Set-DistributionGroup' -Parameters @{ Identity = (Get-TcMember $x 'Name'); HiddenFromAddressListsEnabled = $true; BypassSecurityGroupManagerCheck = $true } | Out-Null }
            if ($missing.Count) { Write-TcRemediationAlert ("{0}: {1} member(s) with no account in the target, to add after their cutover: {2}" -f (Get-TcMember $x 'Name'), $missing.Count, ($missing -join ', ')) }
        }
}

foreach ($d in $chosenPolicies | Where-Object Kind -eq 'Dynamic list') {
    $i = Get-TcRemediationTenant (Get-TcMember $d 'Tenant')
    $name = '{0}-{1}' -f (Get-TcMember $i 'Prefix'), (Get-TcMember $d 'Name')
    $filterValue = ((Get-TcText $d 'Note')).Trim()
    if (-not $filterValue) { Write-TcRemediationAlert ("{0}: enter the rewritten filter in the Note column. A filter that is too broad would send to the whole organization. List not created." -f (Get-TcMember $d 'Address')); continue }
    Add-TcCommandAction -Tenant 'Target' -Service Exo -Command 'New-DynamicDistributionGroup' -Parameters @{ Name = $name; Alias = (Get-TargetAlias (Get-TcMember $i 'Prefix') (Get-TcAddressPrefix (Get-TcMember $d 'Address'))); RecipientFilter = $filterValue } -Object $name `
        -Description ("Create the dynamic list {0}" -f $name) `
        -Test { param($a) [bool](Get-TargetRecipient $a.parameters.Name) } `
        -Undo @{ command = 'Remove-DynamicDistributionGroup'; parameters = @{ Identity = $name } }
}

foreach ($d in $chosenPolicies) {
    $i = Get-TcRemediationTenant (Get-TcMember $d 'Tenant')
    $readItems = @($Backup | Where-Object { (Get-TcMember $_ 'Tenant') -eq (Get-TcMember $d 'Tenant') -and (Get-TcMember $_ 'Kind') -eq (Get-TcMember $d 'Kind') -and (Get-TcMember $_ 'Name') -eq (Get-TcMember $d 'Name') } | ForEach-Object { (Get-TcMember $_ 'Address') })
    if (-not @($Backup | Where-Object Tenant -eq (Get-TcMember $d 'Tenant')).Count -and (Get-TcMember $d 'Kind') -in 'List', 'Dynamic list' -and (Get-TcAddressDomain (Get-TcMember $d 'Address')) -in (Get-TcMember $i 'Domains')) { $readItems = @((Get-TcMember $d 'Address').ToLowerInvariant()) }
    $name = '{0}-{1}' -f (Get-TcMember $i 'Prefix'), (Get-TcMember $d 'Name')
    $command = switch ((Get-TcMember $d 'Kind')) { 'List' { 'Set-DistributionGroup' } 'Dynamic list' { 'Set-DynamicDistributionGroup' } default { 'Set-MailContact' } }
    foreach ($x in $readItems) {
        $addition = 'smtp:{0}' -f $x
        $addressAddition = @{ Identity = $name; EmailAddresses = @{ Add = $addition } }
        $returnValue = @{ Identity = $name; EmailAddresses = @{ Remove = $addition } }
        if ($command -eq 'Set-DistributionGroup') { $addressAddition.BypassSecurityGroupManagerCheck = $true; $returnValue.BypassSecurityGroupManagerCheck = $true }
        Add-TcCommandAction -Tenant 'Target' -Service Exo -Command $command -Parameters $addressAddition -Object $name -Description ("Give {0} back its original address {1}" -f $name, $x) `
            -Test {
                param($a)
                $address = [string]$a.parameters.EmailAddresses.Add -replace '^smtp:', ''
                $domain = Get-TcAddressDomain $address
                if (-not (Test-TcTargetDomain $domain)) { return Test-TcPostponed $a ("{0} is not accepted in the target: run again after the domains are verified in the target" -f $domain) }
                $o = Get-TargetRecipient $a.parameters.Identity
                if (-not $o) { return Test-TcPostponed $a ("{0} does not exist in the target yet" -f $a.parameters.Identity) }
                return @((Get-TcMember $o 'EmailAddresses') | Where-Object { ($_ -replace '^smtp:', '') -eq $address }).Count -gt 0
            } `
            -Undo @{ command = $command; parameters = $returnValue }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $i = Get-TcRemediationTenant $t
    foreach ($d in $chosenPolicies | Where-Object Tenant -eq $t) {
        $name = '{0}-{1}' -f (Get-TcMember $i 'Prefix'), (Get-TcMember $d 'Name')
        $o = Get-TargetRecipient $name
        if (-not $o -and (Get-TcMember $d 'Kind') -notin 'List', 'Dynamic list') { $o = Get-TargetRecipient (Get-TcMember $d 'Address') }
        if ($o) { New-TcRemediationResult OK ("{0} present: {1}" -f $name, (Get-TcMember $o 'PrimarySmtpAddress')) } else { New-TcRemediationResult Warning ("{0} missing from the target" -f $name) }
    }
}
Close-TcRemediation

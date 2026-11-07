# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Exports the auto attendants and queues of the source, then recreates resource accounts and queues in the target (procedure TEL-VOICE-APPS).

.DESCRIPTION
    Order: full export (configuration and audio files) to <output>\telephony\<tenant>, resource accounts with their license, call
    queues, then the link of each account to its queue or auto attendant.
      - Resource account: New-CsOnlineApplicationInstance does not go through Set-CsOnlineApplicationInstance, missing in application
        mode. The usage location and the license go through Graph, the number through Set-CsPhoneNumberAssignment (TEL-NUMBERS).
        The UPN comes from the matrix: the final UPN if its domain is in the target, otherwise the temporary UPN.
      - Call queue: created with its routing, language, thresholds and agents found through the matrix. The default music applies;
        greetings, overflow and lists are completed in the admin center.
      - Auto attendant: menus, greetings, hours and transfers aim at objects of the source. An auto attendant is not copied, it is entered
        in the admin center from the export. decisions\TEL-VOICE-APPS.csv says which exist, which triggers their link.
    Entra role needed on top of the Teams role: User Administrator, required to create a resource account.
#>
$c = Open-TcRemediation

$AppStandard = 'ce933385-9390-45d1-9512-c8d228074e07'
$AppFile = '11cd3e2e-fccb-42ad-ad00-878b93575e07'
$Country = (Get-TcRemediationOption 'UsageLocation')
$ResourceLicense = Get-TcRemediationTable 'Target' 'licenses' | Where-Object { $_['SKU'] -eq 'PHONESYSTEM_VIRTUALUSER' } | Select-Object -First 1
$ResourceSku = [string](Get-TcProperty $ResourceLicense 'SkuId' '')
$TargetDomains = @(Get-TcRemediationTable 'Target' 'domains' | ForEach-Object { ([string]$_['Domain']).ToLowerInvariant() })

function Get-SourceQueue {
    <# Queues of the source, read once: each change of tenant opens a Teams session again. #>
    param([string]$Source)
    if (-not $script:TcRemediationRun['SourceQueues']) { $script:TcRemediationRun['SourceQueues'] = @{} }
    if (-not $script:TcRemediationRun['SourceQueues'][$Source]) { $script:TcRemediationRun['SourceQueues'][$Source] = @(Invoke-TcServiceCommand -Tenant $Source -Service Teams -Command 'Get-CsCallQueue' -Parameters @{ First = 100 }) }
    return $script:TcRemediationRun['SourceQueues'][$Source]
}

function Get-AudioId {
    <# Identifiers of the audio files found in an exported configuration. #>
    param($Object)
    if ($null -eq $Object -or $Object -is [string] -or (Get-TcMember ($Object.GetType()) 'IsValueType')) { return }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($k in $Object.Keys) {
            $v = $Object[$k]
            if ($k -match 'AudioFile(Id|Prompt)$' -and $v -is [string] -and $v) { $v }
            elseif ($k -eq 'AudioFilePrompt' -and $v -is [System.Collections.IDictionary] -and $v['Id']) { [string]$v['Id'] }
            else { Get-AudioId $v }
        }
        return
    }
    foreach ($x in $Object) { Get-AudioId $x }
}

function Get-TargetAccount {
    <# UPN of the resource account in the target, from the matrix. #>
    param([string]$Upn, [hashtable]$Matrix)
    $l = $Matrix[$Upn.ToLowerInvariant()]
    if (-not $l) { return '' }
    if ((Get-TcMember $l 'Target UPN') -and (((Get-TcText $l 'Target UPN') -split '@')[-1]).ToLowerInvariant() -in $TargetDomains) { return (Get-TcText $l 'Target UPN') }
    return (Get-TcText $l 'Temporary UPN')
}

function Add-QueueLink {
    <# Links a resource account to its queue or auto attendant, found by name in the target. #>
    param([string]$Upn, [string]$Name, [ValidateSet('CallQueue', 'AutoAttendant')][string]$Type)
    if (-not $Upn) { return }
    Add-TcBlockAction -Tenant 'Target' -Service Teams -Object $Upn -Description ("Link {0} to {1}" -f $Upn, $Name) -Data @{ Upn = $Upn; Name = $Name; Type = $Type } `
        -Test {
            param($a)
            $r = Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsOnlineApplicationInstance' -Parameters @{ Identity = $a.data.Upn }
            $a.data.Account = (Get-TcText $r 'ObjectId')
            try { return [bool](Get-TcMember (Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsOnlineApplicationInstanceAssociation' -Parameters @{ Identity = $a.data.Account }) 'ConfigurationId') } catch { return $false }
        } `
        -Block {
            param($a)
            $command = if ($a.data.Type -eq 'CallQueue') { 'Get-CsCallQueue' } else { 'Get-CsAutoAttendant' }
            $cfg = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command $command -Parameters @{ NameFilter = $a.data.Name } | Where-Object { (Get-TcMember $_ 'Name') -eq $a.data.Name }) | Select-Object -First 1
            if (-not $cfg) { throw "$($a.data.Name) not found in the target" }
            Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'New-CsOnlineApplicationInstanceAssociation' -Parameters @{ Identities = @($a.data.Account); ConfigurationId = (Get-TcText $cfg 'Identity'); ConfigurationType = $a.data.Type } | Out-Null
            $a.undo = @{ command = 'Remove-CsOnlineApplicationInstanceAssociation'; parameters = @{ Identities = @($a.data.Account) } }
        }
}

$Links = @{}
$proposals = foreach ($t in $c.Tenants) {
    Get-TcRemediationTable $t 'autoAttendants' | ForEach-Object { [ordered]@{ Tenant = $t; AutoAttendant = $_['Name']; Language = $_['Language']; TimeZone = $_['Time zone']; 'Resource accounts' = $_['Resource accounts']; Proposal = '' } }
}
$created = @(Get-TcDecision -Name 'TEL-VOICE-APPS' -Proposal @($proposals) -Key 'Tenant', 'Auto attendant' -Choice 'Created', 'Postpone')

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $accounts = @(Get-TcRemediationTable $t 'resourceAccounts')
    $autoAttendants = @(Get-TcRemediationTable $t 'autoAttendants')
    $files = @(Get-TcRemediationTable $t 'callQueues')
    Write-TcRemediationNote ("{0} auto attendant(s), {1} queue(s), {2} resource account(s)" -f $autoAttendants.Count, $files.Count, $accounts.Count)
    if (-not ($accounts.Count + $autoAttendants.Count + $files.Count)) { continue }

    $available = [int](Get-TcProperty $ResourceLicense 'Available' 0)
    if ($available -lt $accounts.Count) { Write-TcRemediationAlert ("{0} resource account license(s) available for {1} account(s): order the rest (CMP-VOICE-LICENSES)" -f $available, $accounts.Count) }

    $matrix = @{}
    foreach ($l in @((Get-TcMember (Get-TcRemediationIdentity $t) 'rows'))) { $matrix[((Get-TcText $l 'Source UPN')).ToLowerInvariant()] = $l }
    $toCreate = @($accounts | Where-Object { (Get-TcProperty $matrix[([string]$_['UPN']).ToLowerInvariant()] 'Decision') -in 'Create', 'To review' })
    if ($toCreate.Count) { Write-TcRemediationAlert ("{0} resource account(s) in the matrix: exclude them from user creation, this script creates them" -f $toCreate.Count) }

    # Source to target links: the object of the source gives the account or agent in the target
    $byName = @{}; foreach ($r in $accounts) { $byName[[string]$r['Name']] = $r }
    $objectToUpn = @{}; foreach ($u in Get-TcRemediationTable $t 'teamsUsers') { $objectToUpn[[string]$u['ObjectId']] = [string]$u['UPN'] }
    $upnToObject = @{}; foreach ($u in Get-TcRemediationTable 'Target' 'teamsUsers') { $upnToObject[([string]$u['UPN']).ToLowerInvariant()] = [string]$u['ObjectId'] }
    $Links[$t] = @{ Matrix = $matrix; ObjectToUpn = $objectToUpn; UpnToObject = $upnToObject }
    $exportFolder = Join-Path (Get-TcRemediationOutput) "telephony\$t"

    Add-TcBlockAction -Tenant $t -Service Teams -Object 'Export of the voice applications' -Description "Export auto attendants, queues, resource accounts and audio files of $t" -Critical -Data @{ Folder = $exportFolder } `
        -Reason 'Reads the source: nothing to undo, the files stay for closure.' `
        -Block {
            param($a)
            New-Item -ItemType Directory -Force -Path (Join-Path $a.data.Folder 'audio') | Out-Null
            $aa = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsAutoAttendant' -Parameters @{ First = 100 })
            $cq = @(Get-SourceQueue -Source $a.tenant)
            $ra = @(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsOnlineApplicationInstance')
            $aaText = $aa | ConvertTo-Json -Depth 15 -WarningAction SilentlyContinue
            $cqText = $cq | ConvertTo-Json -Depth 15 -WarningAction SilentlyContinue
            Set-Content -LiteralPath (Join-Path $a.data.Folder 'standards.json') -Value $aaText -Encoding utf8
            Set-Content -LiteralPath (Join-Path $a.data.Folder 'files.json') -Value $cqText -Encoding utf8
            $ra | ConvertTo-Json -Depth 6 -WarningAction SilentlyContinue | Set-Content -LiteralPath (Join-Path $a.data.Folder 'resource-accounts.json') -Encoding utf8
            foreach ($e in @(@{ App = 'OrgAutoAttendant'; Text = $aaText }, @{ App = 'HuntGroup'; Text = $cqText })) {
                if (-not (Get-TcMember $e 'Text')) { continue }
                foreach ($id in @(Get-AudioId ((Get-TcMember $e 'Text') | ConvertFrom-Json -AsHashtable -Depth 30) | Select-Object -Unique)) {
                    try {
                        $bytes = Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Export-CsOnlineAudioFile' -Parameters @{ ApplicationId = (Get-TcMember $e 'App'); Identity = $id }
                        [System.IO.File]::WriteAllBytes((Join-Path $a.data.Folder ("audio\{0}-{1}.wav" -f (Get-TcMember $e 'App'), $id)), [byte[]]$bytes)
                    }
                    catch { Write-TcRemediationAlert ("Audio file {0} not exported: {1}" -f $id, (Get-TcErrorText $_)) }
                }
            }
        }

    foreach ($r in $accounts) {
        $upn = Get-TargetAccount -Upn ([string]$r['UPN']) -Matrix $matrix
        if (-not $upn) { Write-TcRemediationAlert ("{0} missing from the matrix: account not planned" -f $r['UPN']); continue }
        $app = if ($r['Usage'] -eq "Call queue") { $AppFile } else { $AppStandard }
        Add-TcBlockAction -Tenant 'Target' -Service Teams -Object $upn -Description ("Create the resource account {0} and assign its license" -f $upn) `
            -Data @{ Upn = $upn; Name = [string]$r['Name']; Application = $app; Sku = $ResourceSku; Country = $Country } `
            -Test {
                param($a)
                $o = @((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users?`$filter=userPrincipalName eq '{0}'&`$select=id,assignedLicenses" -f $a.data.Upn)) 'value')) | Select-Object -First 1
                return [bool]($o -and @((Get-TcMember $o 'assignedLicenses') | Where-Object { (Get-TcMember $_ 'skuId') -eq $a.data.Sku }).Count)
            } `
            -Block {
                param($a)
                $d = $a.data
                $filterValue = "v1.0/users?`$filter=userPrincipalName eq '{0}'&`$select=id,usageLocation" -f (Get-TcMember $d 'Upn')
                $o = @((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri $filterValue) 'value')) | Select-Object -First 1
                if (-not $o) {
                    Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'New-CsOnlineApplicationInstance' -Parameters @{ UserPrincipalName = (Get-TcMember $d 'Upn'); ApplicationId = [guid](Get-TcMember $d 'Application'); DisplayName = (Get-TcMember $d 'Name') } | Out-Null
                    $end = (Get-TcRemediationNow).AddMinutes(3)
                    while (-not $o -and (Get-TcRemediationNow) -lt $end) {
                        Wait-TcRemediation -Seconds 10
                        $o = @((Get-TcMember (Invoke-TcGraph -Tenant $a.tenant -Uri $filterValue) 'value')) | Select-Object -First 1
                    }
                    if (-not $o) { throw "Account $((Get-TcMember $d 'Upn')) created, but not visible in Entra ID yet: run again." }
                    $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "v1.0/users/$((Get-TcMember $o 'id'))" }
                }
                if (-not (Get-TcMember $o 'usageLocation')) { Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri "v1.0/users/$((Get-TcMember $o 'id'))" -Body @{ usageLocation = (Get-TcMember $d 'Country') } | Out-Null }
                Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri "v1.0/users/$((Get-TcMember $o 'id'))/assignLicense" -Body @{ addLicenses = @(@{ skuId = (Get-TcMember $d 'Sku'); disabledPlans = @() }); removeLicenses = @() } | Out-Null
            }
    }

    foreach ($q in $files) {
        Add-TcBlockAction -Tenant 'Target' -Service Teams -Object $q['Name'] -Description ("Create the call queue {0}" -f $q['Name']) -Data @{ Source = $t; Name = [string]$q['Name'] } `
            -Test { param($a) [bool]@(Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'Get-CsCallQueue' -Parameters @{ NameFilter = $a.data.Name } | Where-Object { (Get-TcMember $_ 'Name') -eq $a.data.Name }).Count } `
            -Block {
                param($a)
                $s = @(Get-SourceQueue -Source $a.data.Source | Where-Object { (Get-TcMember $_ 'Name') -eq $a.data.Name }) | Select-Object -First 1
                if (-not $s) { throw "Queue $($a.data.Name) not found in $($a.data.Source)" }
                $link = $Links[$a.data.Source]
                $agents = [System.Collections.Generic.List[guid]]::new()
                foreach ($x in @((Get-TcMember $s 'Agents'))) {
                    $upn = [string](Get-TcMember $link 'ObjectToUpn')[(Get-TcText $x 'ObjectId')]
                    $l = if ($upn) { (Get-TcMember $link 'Matrix')[$upn.ToLowerInvariant()] }
                    $id = if ($l) { @((Get-TcMember $l 'Target UPN'), (Get-TcMember $l 'Temporary UPN') | Where-Object { $_ } | ForEach-Object { (Get-TcMember $link 'UpnToObject')[([string]$_).ToLowerInvariant()] } | Where-Object { $_ }) | Select-Object -First 1 }
                    if ($id) { $agents.Add([guid]$id) } else { Write-TcRemediationAlert ("Queue {0}: agent {1} missing from the target, to add in the admin center" -f $a.data.Name, (Get-TcMember $x 'ObjectId')) }
                }
                $p = @{ Name = (Get-TcMember $s 'Name'); LanguageId = (Get-TcText $s 'LanguageId'); UseDefaultMusicOnHold = $true; RoutingMethod = (Get-TcText $s 'RoutingMethod'); PresenceBasedRouting = [bool](Get-TcMember $s 'PresenceBasedRouting')
                        AllowOptOut = [bool](Get-TcMember $s 'AllowOptOut'); ConferenceMode = [bool](Get-TcMember $s 'ConferenceMode'); AgentAlertTime = [int16](Get-TcMember $s 'AgentAlertTime'); OverflowThreshold = [int16](Get-TcMember $s 'OverflowThreshold'); TimeoutThreshold = [int16](Get-TcMember $s 'TimeoutThreshold') }
                if ($agents.Count) { $p.Users = @($agents) }
                $n = Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command 'New-CsCallQueue' -Parameters $p
                $a.undo = @{ command = 'Remove-CsCallQueue'; parameters = @{ Identity = (Get-TcText $n 'Identity') } }
            }
        foreach ($name in @(([string]$q['Resource accounts']) -split ',\s*' | Where-Object { $_ })) {
            $r = $byName[$name]
            if ($r) { Add-QueueLink -Upn (Get-TargetAccount -Upn ([string]$r['UPN']) -Matrix $matrix) -Name ([string]$q['Name']) -Type CallQueue }
        }
    }
    if ($files.Count) {
        Add-TcManualAction -Tenant 'Target' -Object "Call queue options" -Description "Complete the call queues in the Teams admin center" `
            -Instruction @("Complete each queue from $exportFolder\files.json: greetings, music, distribution lists, overflow and timeout.", 'The overflow targets are objects of the source: replace them with those of the target.')
    }

    foreach ($s in $autoAttendants) {
        $standardName = [string]$s['Name']
        if (@($created | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t -and (Get-TcMember $_ 'AutoAttendant') -eq $standardName -and (Get-TcMember $_ 'Decision') -eq 'Created' }).Count) {
            foreach ($name in @(([string]$s['Resource accounts']) -split ',\s*' | Where-Object { $_ })) {
                $r = $byName[$name]
                if ($r) { Add-QueueLink -Upn (Get-TargetAccount -Upn ([string]$r['UPN']) -Matrix $matrix) -Name $standardName -Type AutoAttendant }
            }
            continue
        }
        Add-TcManualAction -Tenant 'Target' -Object $standardName -Description ("Create the auto attendant {0} in the Teams admin center" -f $standardName) `
            -Instruction @(("Create {0} with the same name: language {1}, time zone {2} to review, {3} call flow(s), {4} schedule(s)." -f $standardName, $s['Language'], $s['Time zone'], $s["Call flows"], $s['Schedules']), "Specification: $exportFolder\standards.json, audio files in the audio subfolder.", 'Enter Created in decisions\TEL-VOICE-APPS.csv, then run again: the script links the resource account.')
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $aa = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command 'Get-CsAutoAttendant' -Parameters @{ First = 100 })
    $cq = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command 'Get-CsCallQueue' -Parameters @{ First = 100 })
    $ra = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command 'Get-CsOnlineApplicationInstance' | Where-Object { (Get-TcText $_ 'ApplicationId') -in $AppStandard, $AppFile })
    New-TcRemediationResult Info ("Target: {0} auto attendant(s), {1} queue(s), {2} voice application resource account(s)" -f $aa.Count, $cq.Count, $ra.Count)
    foreach ($q in Get-TcRemediationTable $t 'callQueues') { if (@($cq | Where-Object { (Get-TcMember $_ 'Name') -eq $q['Name'] }).Count) { New-TcRemediationResult OK ("queue {0} present" -f $q['Name']) } else { New-TcRemediationResult Blocking ("queue {0} missing from the target" -f $q['Name']) } }
    $lacking = @(Get-TcRemediationTable $t 'autoAttendants' | Where-Object { $n = $_['Name']; -not @($aa | Where-Object { (Get-TcMember $_ 'Name') -eq $n }).Count })
    if ($lacking.Count) { New-TcRemediationResult Warning ("{0} auto attendant(s) still to create" -f $lacking.Count) } else { New-TcRemediationResult OK 'all the auto attendants exist in the target' }
}
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Has the single rule of the target chosen for each setting set differently from one source to the other (procedure CON-SETTINGS).

.DESCRIPTION
    Data read: the gaps of the plan, with the value of the target and of each source.
    decisions\CON-SETTINGS.csv: one row per setting. The proposal keeps the value of the target.
      - Keep target: nothing changes in the target;
      - Change target: enter the value in the Chosen value column. A rule looser than the target design weakens the whole target: it
        needs a written decision of the customer.

    This script does not touch SharePoint or Teams: one process cannot load both their modules. The writes are in CON-SETTINGS-SPO and
    CON-SETTINGS-TEAMS, which read this file. The other settings are declared as work for a person, because their own procedure holds
    them (methods: EMERGENCY-ACCESS and ENT-MFA-REGISTRATION; invitations: ENT-AUTHORIZATION). The report says which source loses a
    capability, for the communication.
#>
[void](Open-TcRemediation)

$DecisionFile = 'CON-SETTINGS'
$Keys = @('Service', 'Setting')
$SourceNames = @{}; foreach ($role in (Get-TcSourceRole)) { $SourceNames[(Get-TcRemediationTenant $role)['Name']] = $role }

function Get-ItemValue {
    <# A value list in the form role value, role value becomes a dictionary; a value can be empty. #>
    param([string]$Text)
    $v = @{}; $target = (Get-TcRemediationTenant 'Target')['Name']
    foreach ($p in ($Text -split ' - ')) {
        foreach ($n in @($target) + @($SourceNames.Keys)) { if ($p -eq $n -or $p.StartsWith("$n ") -or $p.StartsWith("$n`:")) { $v[$(if ($n -eq $target) { 'Target' } else { $SourceNames[$n] })] = ($p.Substring((Get-TcMember $n 'Length')) -replace '^:', '').Trim() } }
    }
    return $v
}

$existingItems = Read-TcDecisionEntry -Name $DecisionFile -Key $Keys
Write-TcRemediationTenant 'Target' 'Settings set differently'
$items = @(Get-TcRemediationPlanAction -Procedure 'CON-SETTINGS' | ForEach-Object { (Get-TcMember $_ 'items') } | Where-Object { $_ })
Write-TcRemediationNote ("{0} setting(s) differ from one source to the other" -f $items.Count)

$proposals = foreach ($e in $items) {
    if ([string]$e -notmatch '^(?<s>.+?) - (?<p>.+?): (?<v>.*)$') { Write-TcRemediationAlert "Unreadable plan item: $e"; continue }
    $service = $Matches['s']; $setting = $Matches['p']
    $v = Get-ItemValue $Matches['v']
    $l = [ordered]@{ Service = $service; Setting = $setting; Target = $v['Target'] }; foreach ($role in (Get-TcSourceRole)) { $l[$role] = $v[$role] }; $l['Chosen value'] = ''; $l['Proposal'] = 'Keep target'
    $before = $existingItems[(Get-TcDecisionKey ([pscustomobject]$l) $Keys)]
    if ($before) { $l.'Chosen value' = (Get-TcMember $before 'Chosen value') }
    $l
}

$decisions = @(Get-TcDecision -Name $DecisionFile -Proposal @($proposals | Where-Object { $_ }) -Key $Keys -Choice 'Keep target', 'Change target')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Change target' -and -not (Get-TcMember $_ 'Chosen value') }) { Write-TcRemediationAlert ("{0}: decision Change target with no chosen value" -f (Get-TcMember $d 'Setting')) }
foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Change target' -and (Get-TcMember $_ 'Chosen value') -and (Get-TcMember $_ 'Service') -notmatch '^(SharePoint|Teams)' }) {
    Add-TcManualAction -Tenant 'Target' -Object (Get-TcMember $d 'Setting') -Description ("Apply the chosen rule for {0}: {1}" -f (Get-TcMember $d 'Setting'), (Get-TcMember $d 'Chosen value')) -Who 'Team' `
        -Instruction @(("{0}, {1}: chosen value {2}." -f (Get-TcMember $d 'Service'), (Get-TcMember $d 'Setting'), (Get-TcMember $d 'Chosen value')), 'This setting belongs to another procedure or portal: apply it there, then check at the next assessment.')
}

$losing = foreach ($d in $decisions) {
    $rule = if ((Get-TcMember $d 'Decision') -eq 'Change target') { (Get-TcMember $d 'Chosen value') } else { (Get-TcMember $d 'Target') }
    foreach ($n in $SourceNames.Keys) {
        if ((Get-TcText $d $n) -ne [string]$rule) { [ordered]@{ Source = $n; Service = (Get-TcMember $d 'Service'); Setting = (Get-TcMember $d 'Setting'); 'Today' = (Get-TcMember $d $n); 'Chosen rule' = $rule } }
    }
}
if (@($losing | Where-Object { $_ }).Count) { Export-TcRemediationReport -Name 'communication-by-unit' -Rows @($losing | Where-Object { $_ }) | Out-Null }

Invoke-TcRemediationPlan
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Compares the sensitive settings of each source with the target and has each gap decided (procedure CMP-SETTINGS).

.DESCRIPTION
    Data read: the gaps of the plan, source by source. Each gap is classed by its effect on users.

    decisions\CMP-SETTINGS.csv: one row per source and per setting.
      - Keep target: the value of the target stays. This is the proposal: the target does not lower itself to a less strict source without
        a written decision. The users of the source lose or gain a capability, to announce;
      - Exception: the customer wants to change the target. The setting goes to CON-SETTINGS, which holds the single value;
      - Not applicable: technical gap, with no effect for users.

    The script writes to no tenant: a global value of the target also touches its current users, and one decision must hold it. It
    produces the list of capabilities that change, for the communication plan.
    Limit: the target design is not in the snapshot, it is read during the meeting with the customer.
#>
$c = Open-TcRemediation

$TechnicalOnes = 'StorageQuota|OrganizationFederatedMailbox|ConfigMetadata|OrphanedPersonalSitesRetentionPeriod'

function Get-SettingEffect {
    param([string]$Setting)
    switch -Regex ($Setting) {
        'AutoAdmitted|Lobby|PSTN' { return 'Lobby' }
        'Recording|Transcription' { return 'Record' }
        'Invit|Guest|ExternalUser' { return 'Guests' }
        'Sharing|Link|Anonymous|Reshar|External access|Bots?' { return 'Sharing' }
        'Method|permissionGrant|User permissions' { return 'Authentication and applications' }
        $TechnicalOnes { return 'Technical' }
        default { return 'Other' }
    }
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Gaps read against the target'
    $items = @(Get-TcRemediationPlanAction -Procedure 'CMP-SETTINGS' -Tenant $t | ForEach-Object { (Get-TcMember $_ 'items') } | Where-Object { $_ })
    Write-TcRemediationNote ("{0} setting(s) differ from the target" -f $items.Count)
    foreach ($e in $items) {
        if ([string]$e -notmatch '^(?<s>.+?) - (?<p>.+?): (?<v>.*?) to (?<d>.*)$') { Write-TcRemediationAlert "Unreadable plan item: $e"; continue }
        $setting = $Matches['p']
        $effect = Get-SettingEffect $setting
        [ordered]@{ Tenant = $t; Service = $Matches['s']; Setting = $setting; Effect = $effect; 'Source value' = $Matches['v']; 'Target value' = $Matches['d']
                    Proposal = $(if ($effect -eq 'Technical') { 'Not applicable' } else { 'Keep target' }) }
    }
}

$decisions = @(Get-TcDecision -Name 'CMP-SETTINGS' -Proposal @($proposals | Where-Object { $_ }) -Key 'Tenant', 'Service', 'Setting' -Choice 'Keep target', 'Exception', 'Not applicable')

$announcements = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Keep target' })
if ($announcements.Count) {
    Export-TcRemediationReport -Name 'capabilities-that-change' -Rows @($announcements | Sort-Object Tenant, Effect | ForEach-Object {
        [ordered]@{ Tenant = (Get-TcMember $_ 'Tenant'); Effect = (Get-TcMember $_ 'Effect'); Service = (Get-TcMember $_ 'Service'); Setting = (Get-TcMember $_ 'Setting'); 'Today' = (Get-TcMember $_ 'Source value'); 'In target' = (Get-TcMember $_ 'Target value') } }) | Out-Null
}
$exceptions = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Exception' })
if ($exceptions.Count) { Write-TcRemediationNote ("{0} exception(s): to carry into CON-SETTINGS, the only decision that changes the target" -f $exceptions.Count) }

Invoke-TcRemediationPlan
Close-TcRemediation

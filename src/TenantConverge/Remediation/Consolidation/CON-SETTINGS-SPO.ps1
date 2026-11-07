# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Applies to SharePoint in the target the decided single rules (procedure CON-SETTINGS, SharePoint part).

.DESCRIPTION
    Reads decisions\CON-SETTINGS.csv, written by CON-SETTINGS. Only the rows Change target with a chosen value become actions. A tenant
    setting touches all the users of the target.
    Only the settings known to Set-PnPTenant are applied; the others are reported. The earlier value is read on the tenant just before
    the write: it serves the undo.
#>
[void](Open-TcRemediation)

$RuleFile = 'CON-SETTINGS'
$KnownParameters = @('SharingCapability', 'DefaultSharingLinkType', 'DefaultLinkPermission', 'RequireAnonymousLinksExpireInDays', 'PreventExternalUsersFromResharing', 'FileAnonymousLinkType', 'FolderAnonymousLinkType',
                      'ExternalUserExpirationRequired', 'ExternalUserExpireInDays', 'CoreSharingCapability', 'CoreLoopSharingCapability', 'OneDriveSharingCapability', 'OneDriveLoopSharingCapability',
                      'CoreRequestFilesLinkExpirationInDays', 'OneDriveRequestFilesLinkExpirationInDays', 'AllowEveryoneExceptExternalUsersClaimInPrivateSite', 'OrphanedPersonalSitesRetentionPeriod')

function ConvertTo-TypedValue {
    <# The file only holds text; PnP expects a boolean or an integer for some parameters. #>
    param([string]$Text)
    $v = 0
    if ($Text -in 'True', 'False') { return ($Text -eq 'True') }
    if ([int]::TryParse($Text, [ref]$v)) { return $v }
    return $Text
}

Write-TcRemediationTenant 'Target' 'Decided SharePoint rules'
if (-not (Test-TcDecisionFile $RuleFile)) { Write-TcRemediationAlert 'The rules are not decided yet: run CON-SETTINGS first.' }
$rules = if (Test-TcDecisionFile $RuleFile) { @(Read-TcDecisionRow $RuleFile | Where-Object { (Get-TcMember $_ 'Service') -like 'SharePoint*' -and (Get-TcMember $_ 'Decision') -eq 'Change target' -and (Get-TcMember $_ 'Chosen value') }) } else { @() }
Write-TcRemediationNote ("{0} SharePoint setting(s) to change in the target" -f (Get-TcCount $rules))

foreach ($r in $rules) {
    if ((Get-TcMember $r 'Setting') -notin $KnownParameters) { Write-TcRemediationAlert ("{0}: setting with no known write through Set-PnPTenant, to apply in the portal" -f (Get-TcMember $r 'Setting')); continue }
    Add-TcCommandAction -Tenant 'Target' -Service Pnp -Command 'Set-PnPTenant' -Parameters @{ (Get-TcMember $r 'Setting') = (ConvertTo-TypedValue (Get-TcMember $r 'Chosen value')) } -Object (Get-TcMember $r 'Setting') `
        -Description ("Set {0} to {1}" -f (Get-TcMember $r 'Setting'), (Get-TcMember $r 'Chosen value')) `
        -Test {
            param($a)
            $name = (@($a.parameters.Keys) | Select-Object -First 1)
            $before = (Get-TcMember (Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Get-PnPTenant') $name)
            $a.undo = @{ command = 'Set-PnPTenant'; parameters = @{ $name = $(if ($before -is [enum]) { [string]$before } else { $before }) } }
            return [string]$before -eq [string]$a.parameters[$name]
        }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $p = Invoke-TcServiceCommand -Tenant $t -Service Pnp -Command 'Get-PnPTenant'
    foreach ($r in $rules | Where-Object { (Get-TcMember $_ 'Setting') -in $KnownParameters }) {
        if ([string]$p.((Get-TcMember $r 'Setting')) -eq (Get-TcText $r 'Chosen value')) { New-TcRemediationResult OK ("{0}: {1}" -f (Get-TcMember $r 'Setting'), (Get-TcMember $r 'Chosen value')) } else { New-TcRemediationResult Warning ("{0}: {1} instead of {2}" -f (Get-TcMember $r 'Setting'), $p.((Get-TcMember $r 'Setting')), (Get-TcMember $r 'Chosen value')) }
    }
}
Close-TcRemediation

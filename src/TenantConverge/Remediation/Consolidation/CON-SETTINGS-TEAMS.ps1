# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Applies to the global Teams policies in the target the decided single rules (procedure CON-SETTINGS, Teams part).

.DESCRIPTION
    Reads decisions\CON-SETTINGS.csv, written by CON-SETTINGS. Only the rows Change target with a chosen value become actions. A global
    policy touches all the users of the target.
    Only meeting and calling policies are supported; the other settings are reported. The earlier value is read on the tenant just before
    the write: it serves the undo.
#>
[void](Open-TcRemediation)

$RuleFile = 'CON-SETTINGS'
$Policies = @{ TeamsMeetingPolicy = 'CsTeamsMeetingPolicy'; TeamsCallingPolicy = 'CsTeamsCallingPolicy' }

function ConvertTo-TypedValue {
    <# The file only holds text; Teams expects a boolean or an integer for some parameters. #>
    param([string]$Text)
    $v = 0
    if ($Text -in 'True', 'False') { return ($Text -eq 'True') }
    if ([int]::TryParse($Text, [ref]$v)) { return $v }
    return $Text
}

Write-TcRemediationTenant 'Target' 'Decided Teams rules'
if (-not (Test-TcDecisionFile $RuleFile)) { Write-TcRemediationAlert 'The rules are not decided yet: run CON-SETTINGS first.' }
$rules = if (Test-TcDecisionFile $RuleFile) { @(Read-TcDecisionRow $RuleFile | Where-Object { (Get-TcMember $_ 'Service') -like 'Teams*' -and (Get-TcMember $_ 'Decision') -eq 'Change target' -and (Get-TcMember $_ 'Chosen value') }) } else { @() }
Write-TcRemediationNote ("{0} Teams setting(s) to change in the target" -f (Get-TcCount $rules))

$chosenPolicies = foreach ($r in $rules) {
    if ((Get-TcMember $r 'Setting') -notmatch '(?<p>Teams\w+Policy)\.(?<n>\w+)$' -or -not $Policies[$Matches['p']]) { Write-TcRemediationAlert ("{0}: setting with no planned write, to apply in the Teams admin center" -f (Get-TcMember $r 'Setting')); continue }
    $name = $Matches['n']; $suffix = $Policies[$Matches['p']]
    Add-TcCommandAction -Tenant 'Target' -Service Teams -Command "Set-$suffix" -Parameters @{ Identity = 'Global'; $name = (ConvertTo-TypedValue (Get-TcMember $r 'Chosen value')) } -Object (Get-TcMember $r 'Setting') `
        -Description ("Set {0} to {1} in the global policy" -f (Get-TcMember $r 'Setting'), (Get-TcMember $r 'Chosen value')) `
        -Test {
            param($a)
            $name = (@($a.parameters.Keys | Where-Object { $_ -ne 'Identity' }) | Select-Object -First 1)
            $before = (Get-TcMember (Invoke-TcServiceCommand -Tenant $a.tenant -Service Teams -Command ($a.command -replace '^Set-', 'Get-') -Parameters @{ Identity = 'Global' }) $name)
            $a.undo = @{ command = $a.command; parameters = @{ Identity = 'Global'; $name = $(if ($before -is [enum]) { [string]$before } else { $before }) } }
            return [string]$before -eq [string]$a.parameters[$name]
        }
    @{ Suffix = $suffix; Name = $name; Value = (Get-TcMember $r 'Chosen value') }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    foreach ($r in @($chosenPolicies | Where-Object { $_ })) {
        $v = Get-TcMember (Invoke-TcServiceCommand -Tenant $t -Service Teams -Command ("Get-{0}" -f (Get-TcMember $r 'Suffix')) -Parameters @{ Identity = 'Global' }) (Get-TcMember $r 'Name')
        if ([string]$v -eq (Get-TcText $r 'Value')) { New-TcRemediationResult OK ("{0}: {1}" -f (Get-TcMember $r 'Name'), $v) } else { New-TcRemediationResult Warning ("{0}: {1} instead of {2}" -f (Get-TcMember $r 'Name'), $v, (Get-TcMember $r 'Value')) }
    }
}
Close-TcRemediation

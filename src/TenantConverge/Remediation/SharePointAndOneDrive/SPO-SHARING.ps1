# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Compares the external sharing of the source with the target and has the level chosen (procedure SPO-SHARING).

.DESCRIPTION
    Reads sharePointSettings and the sites table. Gives a comparison CSV and the list of sites that allow Anyone links.
    decisions\SPO-SHARING.csv holds one row, for the target: Keep, or the chosen SharingCapability level.
    Set-PnPTenant runs only if the decision changes the current value.
    Limits: warning the owners stays a human action. No email goes out without customer validation.
    Restricting a sensitive site below the tenant level is done when needed with Set-PnPTenantSite, after the copy.
#>
$c = Open-TcRemediation

$SharingSettings = 'SharingCapability', 'DefaultSharingLinkType', 'DefaultLinkPermission', 'PreventExternalUsersFromResharing', 'ExternalUserExpirationRequired', 'ExternalUserExpireInDays', 'OneDriveSharingCapability'
$Levels = 'ExternalUserAndGuestSharing', 'ExternalUserSharingOnly', 'ExistingExternalUserSharingOnly', 'Disabled'
$current = [string](Get-TcRemediationValue 'Target' 'sharePointSettings' 'SharingCapability')

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $gaps = foreach ($p in $SharingSettings) {
        $s = Get-TcRemediationValue $t 'sharePointSettings' $p
        $d = Get-TcRemediationValue 'Target' 'sharePointSettings' $p
        [pscustomobject]@{ 'Setting' = $p; Source = $s; Target = $d; 'Gap' = $(if ([string]$s -ne [string]$d) { 'Yes' } else { 'No' }) }
    }
    Write-TcRemediationNote ("Sharing in the source: {0}; target: {1}; {2} setting(s) out of {3} differ" -f (Get-TcRemediationValue $t 'sharePointSettings' 'SharingCapability'), $current, @($gaps | Where-Object { (Get-TcMember $_ 'Gap') -eq 'Yes' }).Count, (Get-TcCount $SharingSettings))
    Export-TcRemediationReport -Name "sharing-comparison-$t" -Rows @($gaps) | Out-Null

    $openItems = @(Get-TcRemediationTable $t 'sites' | Where-Object { $_['Sharing'] -eq 'ExternalUserAndGuestSharing' } | ForEach-Object { [pscustomobject]@{ Site = $_['Url']; Title = $_['Title']; 'Owner' = $_['Owner']; Sharing = $_['Sharing'] } })
    Write-TcRemediationNote ("{0} site(s) allow Anyone links" -f $openItems.Count)
    if ($openItems.Count) {
        $f = Export-TcRemediationReport -Name "anonymous-link-sites-$t" -Rows $openItems
        Add-TcManualAction -Tenant $t -Object 'Site owners' -Description ("Notify the owners of {0} site(s): their anonymous links do not survive the copy" -f $openItems.Count) `
            -Instruction @("List: $f", 'Announce that Anyone links will stop working and that the useful shares will be redone after the copy (SPO-EXTERNAL).')
    }
}

$row = [ordered]@{ 'Setting' = 'SharingCapability'; 'Current target value' = $current; Proposal = 'Keep' }
$decision = @(Get-TcDecision -Name 'SPO-SHARING' -Proposal @($row) -Key 'Setting' -Choice (@('Keep') + $Levels)) | Select-Object -First 1
$chosenItem = (Get-TcText $decision 'Decision')

if ($chosenItem -in $Levels -and $chosenItem -ne $current) {
    Add-TcCommandAction -Tenant 'Target' -Service Pnp -Command 'Set-PnPTenant' -Parameters @{ SharingCapability = $chosenItem } -Object 'SharingCapability' `
        -Description ("Change the external sharing of the target from {0} to {1}" -f $current, $chosenItem) `
        -Test {
            param($a)
            $p = Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Get-PnPTenant'
            $a.undo = @{ command = 'Set-PnPTenant'; parameters = @{ SharingCapability = (Get-TcText $p 'SharingCapability') } }
            return (Get-TcText $p 'SharingCapability') -eq $a.parameters.SharingCapability
        }
}

Invoke-TcRemediationPlan -Verify {
    $p = Invoke-TcServiceCommand -Tenant 'Target' -Service Pnp -Command 'Get-PnPTenant'
    $expectedOne = if ($chosenItem -in $Levels) { $chosenItem } else { $current }
    if ((Get-TcText $p 'SharingCapability') -eq $expectedOne) { New-TcRemediationResult OK "Target at level $expectedOne" } else { New-TcRemediationResult Blocking "Target at $((Get-TcMember $p 'SharingCapability')), expected $expectedOne" }
}
Close-TcRemediation

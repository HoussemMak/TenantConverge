# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Prepares how private and shared channels are handled and B2B direct connect (procedure TMS-CHANNELS).

.DESCRIPTION
    Reads channels and teamMembership, and gives the list of private and shared channels of the source.
    decisions\TMS-CHANNELS.csv has one row per shared channel: Internal, or External organization with its tenant identifier in Note.
    For an external organization, the script allows B2B direct connect in the target, inbound and outbound, for all users.
    In an -Apply run, the script reads the teams that share each channel and the channel policy of the target.
    Limits: the copy of a channel is validated at the POC with the chosen tool. The same configuration must be done at the other organization.
    The channel policy is not changed: the script only says if it blocks sharing.
#>
$c = Open-TcRemediation

$PartnerUri = 'v1.0/policies/crossTenantAccessPolicy/partners'

function Get-DirectAccessBody {
    return @{ usersAndGroups = @{ accessType = 'allowed'; targets = @(@{ target = 'AllUsers'; targetType = 'user' }) }
              applications = @{ accessType = 'allowed'; targets = @(@{ target = 'AllApplications'; targetType = 'application' }) } }
}

function Get-Partner {
    param([string]$Target, [string]$Id)
    return (@(Invoke-TcGraph -Tenant $Target -Uri $PartnerUri -All) | Where-Object { (Get-TcMember $_ 'tenantId') -eq $Id } | Select-Object -First 1)
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $list = @(Get-TcRemediationTable $t 'channels' | Where-Object { $_['Type'] -in 'Private', 'Shared' })
    Write-TcRemediationNote ("{0} private channel(s), {1} shared" -f @($list | Where-Object { $_['Type'] -eq 'Private' }).Count, @($list | Where-Object { $_['Type'] -eq 'Shared' }).Count)
    Export-TcRemediationReport -Name "channels-$t" -Rows @($list | ForEach-Object { [pscustomobject]@{ 'Team' = $_['Team']; Channel = $_['Channel']; Type = $_['Type'] } }) | Out-Null
    Add-TcManualAction -Tenant $t -Object 'Channel POC' -Description "Try the copy of a shared channel and a private channel during the POC" `
        -Instruction @('Structure, members, files and messages. Record what the tool does not carry over and plan to recreate it by hand.', 'Microsoft Entra guests cannot be added to a shared channel.')
    foreach ($l in $list | Where-Object { $_['Type'] -eq 'Shared' }) { [ordered]@{ Tenant = $t; 'Team' = $l['Team']; Channel = $l['Channel']; Proposal = '' } }
}
$decisions = @(Get-TcDecision -Name 'TMS-CHANNELS' -Proposal @($proposals) -Key 'Tenant', 'Team', 'Channel' -Choice 'Internal', 'External organization')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'External organization' }) {
    $id = ((Get-TcText $d 'Note')).Trim()
    if ($id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { Write-TcRemediationAlert ("{0}: the Note column must give the tenant identifier of the external organization" -f (Get-TcMember $d 'Channel')); continue }
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object $id -Description ("Allow B2B direct connect with the tenant {0} (channel {1})" -f $id, (Get-TcMember $d 'Channel')) -Data @{ Partner = $id } `
        -Test {
            param($a)
            $p = Get-Partner $a.tenant $a.data.Partner
            return $p -and (Get-TcMember (Get-TcMember (Get-TcMember $p 'b2bDirectConnectInbound') 'usersAndGroups') 'accessType') -eq 'allowed' -and (Get-TcMember (Get-TcMember (Get-TcMember $p 'b2bDirectConnectOutbound') 'usersAndGroups') 'accessType') -eq 'allowed'
        } `
        -Block {
            param($a)
            $id = $a.data.Partner
            $p = Get-Partner $a.tenant $id
            $access = @{ b2bDirectConnectInbound = (Get-DirectAccessBody); b2bDirectConnectOutbound = (Get-DirectAccessBody) }
            if ($p) {
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'PATCH'; uri = "$PartnerUri/$id"; body = @{ b2bDirectConnectInbound = (Get-TcMember $p 'b2bDirectConnectInbound'); b2bDirectConnectOutbound = (Get-TcMember $p 'b2bDirectConnectOutbound') } }
                Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri "$PartnerUri/$id" -Body $access | Out-Null
            }
            else {
                $access.tenantId = $id
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "$PartnerUri/$id" }
                Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri $PartnerUri -Body $access | Out-Null
            }
        }
    Add-TcManualAction -Tenant 'Target' -Object $id -Description ("Do the same configuration at the organization {0}" -f $id) -Instruction @('Both sides are required: the administrator of the external organization must allow B2B direct connect, inbound and outbound.') -Who 'External administrator'
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $teams = @(Get-TcRemediationTable $t 'teams')
    foreach ($name in @(Get-TcRemediationTable $t 'channels' | Where-Object { $_['Type'] -eq 'Shared' } | ForEach-Object { $_['Team'] } | Select-Object -Unique)) {
        $e = $teams | Where-Object { $_['Name'] -ceq $name } | Select-Object -First 1
        if (-not $e) { continue }
        foreach ($channel in @(Invoke-TcGraph -Tenant $t -Uri ("v1.0/teams/{0}/allChannels?`$filter=membershipType eq 'shared'&`$select=id,displayName" -f $e['Id']) -All)) {
            $others = @(Invoke-TcGraph -Tenant $t -Uri ("v1.0/teams/{0}/channels/{1}/sharedWithTeams" -f $e['Id'], (Get-TcMember $channel 'id')) -All | Where-Object { (Get-TcMember $_ 'tenantId') -and (Get-TcMember $_ 'tenantId') -ne (Get-TcMember (Get-TcRemediationTenant $t) 'TenantId') })
            New-TcRemediationResult Info ("{0} / {1}: {2} team(s) of another organization {3}" -f $name, (Get-TcMember $channel 'displayName'), $others.Count, (($others | ForEach-Object { (Get-TcMember $_ 'tenantId') } | Select-Object -Unique) -join ', '))
        }
    }
    $p = Invoke-TcServiceCommand -Tenant 'Target' -Service Teams -Command 'Get-CsTeamsChannelsPolicy' -Parameters @{ Identity = 'Global' }
    if ((Get-TcMember $p 'AllowChannelSharingToExternalUser') -and (Get-TcMember $p 'AllowUserToParticipateInExternalSharedChannel')) { New-TcRemediationResult OK 'the channel policy of the target allows external sharing' } else { New-TcRemediationResult Warning 'the channel policy of the target blocks external sharing' }
}
Close-TcRemediation

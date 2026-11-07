# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Reserves the creation of groups and teams in the target to a named security group (procedure ENT-GROUP-CREATION).

.DESCRIPTION
    Reads from the snapshot the assistant groups and accounts and the Global Administrators of the target: these are candidates.
    decisions\ENT-GROUP-CREATION.csv says who joins the group (Add or Exclude). A security group can join: Microsoft accepts nesting.
    While nobody is chosen, nothing is planned: the setting would block everyone.
    decisions\ENT-GROUP-CREATION-NAMING.csv says whether a global naming rule applies. The rule holds one pattern only: the source
    prefixes therefore live in the mapping plan (CON-SITES). With Apply, the pattern goes in Note.

    The update of Group.Unified sends the whole collection of values: a partial update would overwrite the others.
    Limits: the test with a regular account and the rights of the copy tool account stay to be done by a person.
    A Global Administrator cannot create a team from Teams without being a member of the group, which is why they are in the list.
#>
$c = Open-TcRemediation

$GroupName = 'Group and team creators'
$GroupUnifiedTemplate = '62375ab9-6b52-47ed-826b-58e47e0e304b'

function Get-CreatorGroup {
    param([string]$Target)
    $f = $GroupName -replace "'", "''"
    return (@(Invoke-TcGraph -Tenant $Target -Uri ("v1.0/groups?`$filter=displayName eq '{0}'&`$select=id,displayName" -f $f) -All) | Select-Object -First 1)
}

function Get-GroupSetting {
    param([string]$Target)
    return (@(Invoke-TcGraph -Tenant $Target -Uri 'v1.0/groupSettings' -All) | Where-Object { (Get-TcMember $_ 'templateId') -eq $GroupUnifiedTemplate } | Select-Object -First 1)
}

function Get-SettingValue {
    param($SettingRow, [string]$Name)
    return (Get-TcText (@($SettingRow.values) | Where-Object { (Get-TcMember $_ 'name') -eq $Name } | Select-Object -First 1) 'value')
}

foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    $openOne = ConvertTo-TcBoolean (Get-TcRemediationValue $t 'groupSettings' 'Group.Unified.EnableGroupCreation' 'true')
    Write-TcRemediationNote ("Read: group creation {0}, allowed group {1}" -f $(if ($openOne) { 'open to all' } else { 'restricted' }), (Get-TcRemediationValue $t 'groupSettings' 'Group.Unified.GroupCreationAllowedGroupId' ''))

    $candidates = @(
        Get-TcRemediationTable $t 'groups' | Where-Object { $_['Type'] -eq 'Security' -and $_['Name'] -match 'deputy' } | ForEach-Object {
            [ordered]@{ Type = 'Security group'; Name = $_['Name']; Id = $_['Id']; 'Detail' = ('{0} member(s)' -f $_['Members']); Proposal = $(if ([int]$_['Members'] -gt 0) { 'Add' } else { '' }) }
        }
        Get-TcRemediationTable $t 'users' | Where-Object { $_['Type'] -eq 'Member' -and $_['Job title'] -match 'deputy' } | ForEach-Object {
            [ordered]@{ Type = 'Account'; Name = $_['UPN']; Id = $_['Id']; 'Detail' = [string]$_['Job title']; Proposal = '' }
        }
        $admins = @(Get-TcRemediationTable $t 'adminRoles' | Where-Object { $_['Role'] -eq 'Global Administrator' -and $_['Principal type'] -eq 'user' -and -not (Test-TcProtectedAccount -Account ([string]$_['Principal'])) } | ForEach-Object { $_['Principal'] })
        Get-TcRemediationTable $t 'users' | Where-Object { $_['UPN'] -in $admins } | ForEach-Object {
            [ordered]@{ Type = 'Account'; Name = $_['UPN']; Id = $_['Id']; 'Detail' = 'Global Administrator'; Proposal = '' }
        }
    )
    Write-TcRemediationNote ("{0} candidate(s) to validate for the creators group" -f $candidates.Count)
    $decisions = @(Get-TcDecision -Name 'ENT-GROUP-CREATION' -Proposal $candidates -Key 'Type', 'Id' -Choice 'Add', 'Exclude')
    $additions = @($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Add' })

    $namingValue = [string](Get-TcRemediationValue $t 'groupSettings' 'Group.Unified.PrefixSuffixNamingRequirement' '')
    $naming = @(Get-TcDecision -Name 'ENT-GROUP-CREATION-NAMING' -Proposal @([ordered]@{ Subject = 'PrefixSuffixNamingRequirement'; 'Current value' = $namingValue; Proposal = 'No global rule' }) -Key 'Subject' -Choice 'Apply', 'No global rule') | Select-Object -First 1
    $reason = if ((Get-TcMember $naming 'Decision') -eq 'Apply') { (Get-TcText $naming 'Note') } else { '' }
    if ((Get-TcMember $naming 'Decision') -eq 'Apply' -and $reason -notmatch '\[GroupName\]') { Write-TcRemediationAlert 'Naming rule ignored: the Note column must carry the pattern, with [GroupName]'; $reason = '' }

    if (-not $additions.Count) { Write-TcRemediationAlert 'No creator kept: the restriction is not planned, it would block everyone'; continue }

    Add-TcGraphAction -Tenant $t -Method POST -Uri 'v1.0/groups' -Body @{ displayName = $GroupName; description = 'Accounts allowed to create Microsoft 365 groups and teams'; mailEnabled = $false; mailNickname = (Get-TcObjectName '-Group-Creators'); securityEnabled = $true } `
        -Object $GroupName -Description "Create the security group of allowed creators" `
        -Test { param($a) [bool](Get-CreatorGroup $a.tenant) }

    foreach ($d in $additions) {
        Add-TcBlockAction -Tenant $t -Service Graph -Object (Get-TcMember $d 'Name') -Description ("Add {0} to the creators group" -f (Get-TcMember $d 'Name')) -Data @{ Member = (Get-TcMember $d 'Id') } `
            -Test {
                param($a)
                $g = Get-CreatorGroup $a.tenant
                if (-not $g) { return $false }
                return $a.data.Member -in @(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/groups/{0}/members?`$select=id" -f (Get-TcMember $g 'id')) -All | ForEach-Object { (Get-TcMember $_ 'id') })
            } `
            -Block {
                param($a)
                # a group just created can answer 400 while it replicates
                for ($test = 1; $test -le 6; $test++) {
                    $g = Get-CreatorGroup $a.tenant
                    try {
                        if (-not $g) { throw 'Creators group not yet visible' }
                        Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri ("v1.0/groups/{0}/members/`$ref" -f (Get-TcMember $g 'id')) -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($a.data.Member)" } | Out-Null
                        break
                    }
                    catch { if ($test -eq 6) { throw }; Wait-TcRemediation -Seconds (5 * $test) }
                }
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = ("v1.0/groups/{0}/members/{1}/`$ref" -f (Get-TcMember $g 'id'), $a.data.Member) }
            }
    }

    Add-TcBlockAction -Tenant $t -Service Graph -Object 'Group.Unified' -Description "Reserve the creation of groups and teams to the designated group" -Data @{ Reason = $reason } -Critical `
        -Test {
            param($a)
            $g = Get-CreatorGroup $a.tenant
            $r = Get-GroupSetting $a.tenant
            if (-not $g -or -not $r) { return $false }
            $reasonOk = -not $a.data.Reason -or (Get-SettingValue $r 'PrefixSuffixNamingRequirement') -ceq $a.data.Reason
            return (Get-SettingValue $r 'EnableGroupCreation') -eq 'false' -and (Get-SettingValue $r 'GroupCreationAllowedGroupId') -eq (Get-TcMember $g 'id') -and $reasonOk
        } `
        -Block {
            param($a)
            $g = Get-CreatorGroup $a.tenant
            if (-not $g) { throw 'Creators group not found' }
            $wantedOne = [ordered]@{ EnableGroupCreation = 'false'; GroupCreationAllowedGroupId = (Get-TcMember $g 'id') }
            if ($a.data.Reason) { $wantedOne.PrefixSuffixNamingRequirement = $a.data.Reason }
            $r = Get-GroupSetting $a.tenant
            if (-not $r) {
                $n = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri 'v1.0/groupSettings' -Body @{ templateId = $GroupUnifiedTemplate; values = @($wantedOne.Keys | ForEach-Object { @{ name = $_; value = $wantedOne[$_] } }) }
                $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = "v1.0/groupSettings/$((Get-TcMember $n 'id'))" }
                return
            }
            $before = @($r.values | ForEach-Object { @{ name = (Get-TcMember $_ 'name'); value = (Get-TcMember $_ 'value') } })
            $after = @($before | ForEach-Object { @{ name = (Get-TcMember $_ 'name'); value = $(if ($wantedOne.Contains((Get-TcMember $_ 'name'))) { $wantedOne[(Get-TcMember $_ 'name')] } else { (Get-TcMember $_ 'value') }) } })
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'PATCH'; uri = "v1.0/groupSettings/$((Get-TcMember $r 'id'))"; body = @{ values = $before } }
            Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri "v1.0/groupSettings/$((Get-TcMember $r 'id'))" -Body @{ values = $after } | Out-Null
        }

    Add-TcManualAction -Tenant $t -Object 'Copy tool account' -Description "Confirm that the copy tool account can create teams" `
        -Instruction @("In the settings of the chosen tool, check the account that creates the teams.", "If it does not have a sufficient admin role, add it to the group $GroupName before the copy.")
    Add-TcManualAction -Tenant $t -Object 'Creation test' -Description "Try creating a team with an ordinary account and with a member of the group" `
        -Instruction @('The change can take 30 minutes or more.', 'An ordinary account must no longer be able to create a team; a member of the group must be able to.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $g = Get-CreatorGroup $t
    $r = Get-GroupSetting $t
    if (-not $g -or -not $r) { New-TcRemediationResult Warning 'creators group or Group.Unified setting missing'; return }
    $n = @(Invoke-TcGraph -Tenant $t -Uri ("v1.0/groups/{0}/members?`$select=id" -f (Get-TcMember $g 'id')) -All).Count
    New-TcRemediationResult OK "$n member(s) in the creators group"
    if ((Get-SettingValue $r 'EnableGroupCreation') -eq 'false' -and (Get-SettingValue $r 'GroupCreationAllowedGroupId') -eq (Get-TcMember $g 'id')) { New-TcRemediationResult OK 'creation reserved to the designated group' } else { New-TcRemediationResult Blocking 'Group.Unified does not have the expected values' }
    New-TcRemediationResult Info ("{0} value(s) kept in Group.Unified" -f @($r.values).Count)
}
Close-TcRemediation

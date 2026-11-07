# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Creates the two emergency accounts of the target: cloud only, permanent Global Administrators, protected by a FIDO2 key (procedure EMERGENCY-ACCESS).

.DESCRIPTION
    Names and domain: the emergency account settings.

    Decisions: decisions\EMERGENCY-ACCESS.csv, one row per account, Create or Skip, and decisions\EMERGENCY-ACCESS-POLICIES.csv, one row
    per conditional access policy that is not disabled in the snapshot, Exclude or Keep. With no account decided, nothing is planned.

    The script goes through, in this order:
      1. creates the security group of the emergency accounts, protected by isAssignableToRole, and turns on the Passkey (FIDO2)
         method for this group only;
      2. creates the accounts, never synced, with a long password generated here and stored only with DPAPI in secrets\ in the log
         folder; it shows neither on screen nor in a log;
      3. assigns the Global Administrator role, active and permanent, and puts the accounts in the group;
      4. excludes the group from each policy decided, read on the tenant at that moment, with rollback. A policy that refuses the
         exclusion stops the plan: the others are handled first. A live policy nobody decided is reported, and not changed;
      5. creates a one-time Temporary Access Pass per account, also with DPAPI, then waits for a person to register the key:
         the check reads the fido2 method through Graph, up to 60 minutes per account;
      6. creates a Microsoft Defender detection rule on the sign-ins of the two accounts.

    Left to a person: physically registering and storing the key, the sign-in test, and the delivery of the alerts.

    Limits:
      - the detection rule needs Microsoft Defender XDR and Entra ID P2; if the tenant refuses it, the script says so and the alert
        rule is done in Azure Monitor on SigninLogs, which needs a Log Analytics workspace (nothing is written here);
      - a disabled policy is not changed: when it is enabled, decide it and run this script again;
      - the secret stays readable by this Windows account, on this computer: keep the log folder until the keys are tested.
#>
$c = Open-TcRemediation

$GroupName = (Get-TcObjectName '-Emergency-Accounts')
$GlobalAdminId = '62e90394-69f5-4237-9190-012177145e10'
$Fido2Uri = 'v1.0/policies/authenticationMethodsPolicy/authenticationMethodConfigurations/fido2'
$Fido2Type = '#microsoft.graph.fido2AuthenticationMethodConfiguration'
$PoliciesUri = 'v1.0/identity/conditionalAccess/policies'
$RuleUri = 'v1.0/security/rules/detectionRules'
$RuleId = (Get-TcObjectName '-emergency-sign-in').ToLowerInvariant()
$PasswordLength = 64
$PassMinutes = 60
$Accounts = @(Get-TcEmergencyAccount)
$UsageLocation = [string](Get-TcRemediationOption 'UsageLocation')
$SecretFolder = Join-Path $c.Folder 'secrets'

function Find-AccountRow {
    param([string]$Upn)
    return (@(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/users?`$filter=userPrincipalName eq '{0}'&`$select=id,userPrincipalName,accountEnabled,onPremisesSyncEnabled" -f $Upn) -All) | Select-Object -First 1)
}

function Get-AccountId {
    param([string]$Upn)
    $u = Find-AccountRow $Upn
    if (-not $u) { throw "Emergency account not found: $Upn" }
    return (Get-TcMember $u 'id')
}

function Find-GroupRow {
    <# The group of the emergency accounts: two groups with this name would make the exclusion ambiguous. #>
    $l = @(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/groups?`$filter=displayName eq '{0}'&`$select=id,isAssignableToRole" -f $GroupName) -All)
    if ($l.Count -gt 1) { throw "$($l.Count) groups have the name ${GroupName}: keep only one, the protected one." }
    return ($l | Select-Object -First 1)
}

function Get-GroupId { return (Get-TcMember (Find-GroupRow) 'id') }

function Get-AccountProtection {
    <# Identifiers of the emergency accounts and real members of the group, read once per check. #>
    $g = Get-GroupId
    $memberRows = if ($g) { @(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/groups/{0}/members?`$select=id" -f $g) -All | ForEach-Object { (Get-TcMember $_ 'id') }) } else { @() }
    return @{ Group = $g; Members = @($memberRows); Ids = @($Accounts | ForEach-Object { Get-AccountId $_ }) }
}

function Test-Excluded {
    <# An account is excluded by its identifier, as the policies of SEC-03 do, or through the excluded group if it truly is a member. #>
    param($Policy, $Protection)
    if (-not @((Get-TcMember $Protection 'Ids')).Count) { return $false }
    $u = (Get-TcMember (Get-TcMember $Policy 'conditions') 'users')
    $byGroup = (Get-TcMember $Protection 'Group') -and (Get-TcMember $Protection 'Group') -in @((Get-TcMember $u 'excludeGroups'))
    return -not @((Get-TcMember $Protection 'Ids') | Where-Object { $_ -notin @((Get-TcMember $u 'excludeUsers')) -and -not ($byGroup -and $_ -in @((Get-TcMember $Protection 'Members'))) }).Count
}

function Get-PolicyWithoutExclusion {
    <# Read on the tenant at that moment: the snapshot can be old, and a recent policy must protect the emergency accounts too. #>
    $protection = Get-AccountProtection
    return @(Invoke-TcGraph -Tenant 'Target' -Uri $PoliciesUri -All | Where-Object { (Get-TcMember $_ 'state') -ne 'disabled' -and -not (Test-Excluded $_ $protection) })
}

function Get-PolicyToExclude {
    <# The policies a person decided, among those that still lack the exclusion. #>
    return @(Get-PolicyWithoutExclusion | Where-Object { (Get-TcMember $_ 'displayName') -in $ExcludedPolicies })
}

function Get-ActiveRole {
    return @(Invoke-TcGraph -Tenant 'Target' -Uri ("v1.0/roleManagement/directory/roleAssignments?`$filter=roleDefinitionId eq '{0}'" -f $GlobalAdminId) -All)
}

Write-TcRemediationTenant 'Target' "Emergency accounts"
$users = @(Get-TcRemediationTable 'Target' 'users' | ForEach-Object { ([string]$_['UPN']).ToLowerInvariant() })
$lacking = @($Accounts | Where-Object { $_.ToLowerInvariant() -notin $users })
$policies = @(Get-TcRemediationTable 'Target' 'conditionalAccess')
$toExclude = @($policies | Where-Object { $_['State'] -ne 'disabled' })
Write-TcRemediationNote ("{0} account(s) to create on {1}; FIDO2 method: {2}; {3} conditional access policy(ies) not disabled on {4}" -f $lacking.Count, $Accounts.Count, (Get-TcRemediationValue 'Target' 'securitySettings' 'Fido2 method' 'unknown'), $toExclude.Count, $policies.Count)
if ((Get-TcRemediationValue 'Target' 'securitySettings' 'TemporaryAccessPass method') -ne 'enabled') { Write-TcRemediationAlert 'The Temporary Access Pass method is not active: enable it before registering the keys' }

$accountRows = @($Accounts | ForEach-Object { [ordered]@{ Account = $_; 'In the snapshot' = $(if ($_.ToLowerInvariant() -in $users) { 'Yes' } else { 'No' }); Proposal = 'Create' } })
$Accounts = @(Get-TcDecision -Name 'EMERGENCY-ACCESS' -Proposal $accountRows -Key 'Account' -Choice 'Create', 'Skip' | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Create' } | ForEach-Object { (Get-TcMember $_ 'Account') })
$policyRows = @($toExclude | ForEach-Object { [ordered]@{ Policy = $_['Name']; State = $_['State']; Proposal = 'Exclude' } })
$ExcludedPolicies = @(Get-TcDecision -Name 'EMERGENCY-ACCESS-POLICIES' -Proposal $policyRows -Key 'Policy' -Choice 'Exclude', 'Keep' | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Exclude' } | ForEach-Object { (Get-TcMember $_ 'Policy') })
if (-not $Accounts.Count) {
    Write-TcRemediationNote 'No emergency account decided: nothing is planned.'
    Invoke-TcRemediationPlan
    Close-TcRemediation
    return
}

Add-TcGraphAction -Tenant 'Target' -Method POST -Uri 'v1.0/groups' -Object $GroupName -Description "Create the security group of emergency accounts" -Critical `
    -Body @{ displayName = $GroupName; description = "Emergency accounts, excluded from conditional access policies"; mailEnabled = $false; mailNickname = $GroupName.ToLowerInvariant(); securityEnabled = $true; isAssignableToRole = $true } `
    -Test { [bool](Get-GroupId) }

Add-TcBlockAction -Tenant 'Target' -Service Graph -Object 'Passkey (FIDO2)' -Description "Enable the Passkey (FIDO2) method for the emergency accounts group" -Critical `
    -Test { param($a) $m = Invoke-TcGraph -Tenant $a.tenant -Uri $Fido2Uri; (Get-TcMember $m 'state') -eq 'enabled' -and @((Get-TcMember $m 'includeTargets') | Where-Object { (Get-TcMember $_ 'id') -in @('all_users', (Get-GroupId)) }).Count -gt 0 } `
    -Block {
        param($a)
        $m = Invoke-TcGraph -Tenant $a.tenant -Uri $Fido2Uri
        $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'PATCH'; uri = $Fido2Uri; body = @{ '@odata.type' = $Fido2Type; state = (Get-TcMember $m 'state'); isSelfServiceRegistrationAllowed = (Get-TcMember $m 'isSelfServiceRegistrationAllowed'); includeTargets = @((Get-TcMember $m 'includeTargets')) } }
        $target = @{ targetType = 'group'; id = (Get-GroupId); isRegistrationRequired = $false }
        $passkeyProfile = @(@((Get-TcMember $m 'defaultPasskeyProfile')) + @((Get-TcMember $m 'passkeyProfiles') | ForEach-Object { (Get-TcMember $_ 'id') }) | Where-Object { $_ } | Select-Object -First 1)
        if ($passkeyProfile.Count) { $target.allowedPasskeyProfiles = $passkeyProfile }
        # method disabled: its inherited targets (often all users) must not open with it
        $targets = if ((Get-TcMember $m 'state') -eq 'enabled') { @((Get-TcMember $m 'includeTargets')) + $target } else { @($target) }
        Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri $Fido2Uri -Body @{ '@odata.type' = $Fido2Type; state = 'enabled'; isSelfServiceRegistrationAllowed = $true; includeTargets = $targets }
    }

foreach ($u in $Accounts) {
    $alias = Get-TcAddressPrefix $u
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object $u -Description ("Create the emergency account {0}, cloud-only" -f $u) -Data @{ Upn = $u; Alias = $alias } -Critical `
        -Test { param($a) [bool](Find-AccountRow $a.data.Upn) } `
        -Block {
            param($a)
            $passwordValue = Get-TcRandomPassword -Length $PasswordLength
            Save-TcRemediationSecret -Name ("password-{0}" -f $a.data.Alias) -Value $passwordValue
            $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri 'v1.0/users' -Body ([ordered]@{
                accountEnabled = $true; displayName = ("Emergency account {0}" -f $a.data.Alias); mailNickname = $a.data.Alias; userPrincipalName = $a.data.Upn; usageLocation = $UsageLocation
                passwordPolicies = 'DisablePasswordExpiration'; passwordProfile = @{ forceChangePasswordNextSignIn = $false; password = $passwordValue } })
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = ("v1.0/users/{0}" -f (Get-TcMember $r 'id')) }
        }

    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object $u -Description ("Assign the Global Administrator role to {0}, active and permanent" -f $u) -Data @{ Upn = $u } -Critical `
        -Test { param($a) $id = Get-AccountId $a.data.Upn; [bool]@(Get-ActiveRole | Where-Object { (Get-TcMember $_ 'principalId') -eq $id }).Count } `
        -Block {
            param($a)
            $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri 'v1.0/roleManagement/directory/roleAssignments' -Body @{ principalId = (Get-AccountId $a.data.Upn); roleDefinitionId = $GlobalAdminId; directoryScopeId = '/' }
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = ("v1.0/roleManagement/directory/roleAssignments/{0}" -f (Get-TcMember $r 'id')) }
        }

    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object $u -Description ("Add {0} to the group {1}" -f $u, $GroupName) -Data @{ Upn = $u } -Critical `
        -Test { param($a) (Get-AccountId $a.data.Upn) -in @(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/groups/{0}/members?`$select=id" -f (Get-GroupId)) -All | ForEach-Object { (Get-TcMember $_ 'id') }) } `
        -Block {
            param($a)
            $g = Get-GroupId; $id = Get-AccountId $a.data.Upn
            Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri ("v1.0/groups/{0}/members/`$ref" -f $g) -Body @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$id" }
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = ("v1.0/groups/{0}/members/{1}/`$ref" -f $g, $id) }
        }
}

if (-not $ExcludedPolicies.Count) { Write-TcRemediationAlert 'No conditional access policy decided: the emergency accounts stay subject to every active policy' }
else {
Add-TcBlockAction -Tenant 'Target' -Service Graph -Object 'Conditional access' -Description ("Exclude the emergency accounts group from the {0} policy(ies) decided, read at the time of acting" -f $ExcludedPolicies.Count) -Critical `
    -Test { -not @(Get-PolicyToExclude).Count } `
    -Block {
        param($a)
        $g = Get-GroupId
        $undos = [System.Collections.Generic.List[object]]::new()
        $refusal = [System.Collections.Generic.List[string]]::new()
        # one refused policy does not stop the others from being protected: the refusal comes at the end
        foreach ($x in @(Get-PolicyToExclude)) {
            $uri = "$PoliciesUri/$((Get-TcMember $x 'id'))"
            $after = Copy-TcObject (Get-TcMember (Get-TcMember $x 'conditions') 'users')
            $after.excludeGroups = @(@((Get-TcMember $after 'excludeGroups')) + $g | Where-Object { $_ } | Select-Object -Unique)
            $undos.Add(@{ type = 'Graph'; tenant = $a.tenant; method = 'PATCH'; uri = $uri; body = @{ conditions = @{ users = (Copy-TcObject (Get-TcMember (Get-TcMember $x 'conditions') 'users')) } } })
            $a.undo = @($undos)
            try { Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri $uri -Body @{ conditions = @{ users = $after } } | Out-Null }
            catch { $refusal.Add(("{0}: {1}" -f (Get-TcMember $x 'displayName'), (Get-TcErrorText $_))) }
        }
        # read again: the group and its members can take a moment to propagate
        $rest = @()
        for ($i = 1; $i -le 3; $i++) {
            $rest = @(Get-PolicyToExclude)
            if (-not $rest.Count) { break }
            if ($i -lt 3) { Wait-TcRemediation -Seconds 20 }
        }
        if ($rest.Count) { throw ("{0} policy(ies) do not protect the emergency accounts: {1}. Refusal: {2}" -f $rest.Count, (@($rest | ForEach-Object { (Get-TcMember $_ 'displayName') }) -join ', '), $(if ($refusal.Count) { $refusal -join ' ; ' } else { 'none' })) }
    }
}

foreach ($u in $Accounts) {
    $alias = Get-TcAddressPrefix $u
    $passFile = Join-Path $SecretFolder "temporary-access-pass-$alias.xml"
    Add-TcBlockAction -Tenant 'Target' -Service Graph -Object $u -Description ("Create a one-time temporary access pass for {0}" -f $u) -Data @{ Upn = $u; Alias = $alias } `
        -Test { param($a) [bool]@(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users/{0}/authentication/fido2Methods" -f (Get-AccountId $a.data.Upn)) -All).Count } `
        -Block {
            param($a)
            $id = Get-AccountId $a.data.Upn
            $uri = "v1.0/users/$id/authentication/temporaryAccessPassMethods"
            # one pass per account, and the one of an earlier run can no longer be read: it is replaced
            foreach ($p in Invoke-TcGraph -Tenant $a.tenant -Uri $uri -All) { Invoke-TcGraph -Tenant $a.tenant -Method DELETE -Uri ("{0}/{1}" -f $uri, (Get-TcMember $p 'id')) }
            $r = Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri $uri -Body @{ lifetimeInMinutes = $PassMinutes; isUsableOnce = $true }
            Save-TcRemediationSecret -Name ("temporary-access-pass-{0}" -f $a.data.Alias) -Value (Get-TcMember $r 'temporaryAccessPass')
            $a.undo = @{ type = 'Graph'; tenant = $a.tenant; method = 'DELETE'; uri = ("{0}/{1}" -f $uri, (Get-TcMember $r 'id')) }
        }

    Add-TcManualAction -Tenant 'Target' -Object $u -Who 'Named person' -Description ("Register the FIDO2 key of {0}" -f $u) -Minutes $PassMinutes `
        -Instruction @(("Read the pass, on this Windows account: Import-Clixml '{0}' | ConvertFrom-SecureString -AsPlainText" -f $passFile),
                    ("On https://aka.ms/mysecurityinfo, sign in with {0} and this pass, then register the security key." -f $u),
                    'The script watches the fido2 method and continues on its own as soon as the key is registered. Pass expired: run the script again.') `
        -WaitUntil { param($a) [bool]@(Invoke-TcGraph -Tenant $a.tenant -Uri ("v1.0/users/{0}/authentication/fido2Methods" -f (Get-AccountId $a.object)) -All).Count }
}

Add-TcBlockAction -Tenant 'Target' -Service Graph -Object 'Sign-in alert' -Description "Create the detection rule on emergency account sign-ins" -Undo @{ type = 'Graph'; tenant = 'Target'; method = 'DELETE'; uri = "$RuleUri/$RuleId" } `
    -Test {
        param($a)
        # a tenant with no Defender XDR refuses the list: this is not a migration failure, the alert then goes through Azure Monitor
        try { Invoke-TcGraph -Tenant $a.tenant -Uri $RuleUri | Out-Null }
        catch { return (Test-TcPostponed $a ("detection rule unavailable ({0}): create the alert in Azure Monitor, see the next action" -f (Get-TcErrorText $_))) }
        return (-not (Test-TcGraphAbsent -Tenant $a.tenant -Uri "$RuleUri/$RuleId"))
    } `
    -Block {
        param($a)
        $ids = @($Accounts | ForEach-Object { "'$(Get-AccountId $_)'" }) -join ', '
        $query = "EntraIdSignInEvents | where AccountObjectId in ($ids) | project Timestamp, ReportId, AccountObjectId, AccountUpn"
        $body = [ordered]@{
            '@odata.type' = '#microsoft.graph.security.detectionRule'; id = $RuleId; displayName = "Emergency account sign-in"; status = 'enabled'
            description = "Every sign-in of a target emergency account must be explained."
            queryCondition = @{ queryText = $query }; schedule = @{ frequency = 'PT1H' }
            detectionAction = @{ alertTemplate = @{ title = "Emergency account sign-in"; description = "A target emergency account has just signed in."; severity = 'high'
                                                    recommendedActions = "Confirm who used the account and why. Without an explanation, treat it as an incident."
                                                    entityMappings = @{ accounts = @(@{ aadUserIdColumn = 'AccountObjectId'; upnColumn = 'AccountUpn' }) } } }
        }
        Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri $RuleUri -Body $body | Out-Null
    }

Add-TcManualAction -Tenant 'Target' -Object 'Alert delivery' -Description "Have sign-in alerts delivered to the administrators and the security lead" `
    -Instruction @('If the detection rule exists: Microsoft Defender portal > Settings > Microsoft Defender XDR > Email notifications > Alerts.',
                'Otherwise: Azure portal > Monitor > Alerts > Create, on the SigninLogs table of the Log Analytics workspace, filtered on the object identifiers of the two accounts.',
                'No API writes these notifications, and the application used for the run has no Azure role.')


Add-TcManualAction -Tenant 'Target' -Object 'Account test' -Who 'Named person' -Description "Test the sign-in of each account with its key, then store the keys" `
    -Instruction @('Sign in with each key from the designated administration device: the alert must reach the recipients.', 'Then store the keys in two separate places, designated with the customer. Repeat this test every quarter.')

Invoke-TcRemediationPlan -Verify {
    param($t)
    if ($t -ne 'Target') { return }
    $roles = @(Get-ActiveRole | ForEach-Object { (Get-TcMember $_ 'principalId') })
    foreach ($upn in $Accounts) {
        $u = Find-AccountRow $upn
        if (-not $u) { New-TcRemediationResult Blocking "${upn}: account missing"; continue }
        $shortages = @()
        if (-not (Get-TcMember $u 'accountEnabled')) { $shortages += 'disabled' }
        if ((Get-TcMember $u 'onPremisesSyncEnabled')) { $shortages += 'Synced' }
        if ((Get-TcMember $u 'id') -notin $roles) { $shortages += 'not Global Administrator' }
        if (-not @(Invoke-TcGraph -Tenant $t -Uri ("v1.0/users/{0}/authentication/fido2Methods" -f (Get-TcMember $u 'id')) -All).Count) { $shortages += 'no FIDO2 key' }
        if ($shortages) { New-TcRemediationResult Blocking ("{0}: {1}" -f $upn, ($shortages -join ', ')) } else { New-TcRemediationResult OK "${upn}: active, permanent Global Administrator, FIDO2 key registered" }
    }
    $g = Find-GroupRow
    if (-not $g) { New-TcRemediationResult Blocking "group $GroupName missing" }
    elseif (-not (Get-TcMember $g 'isAssignableToRole')) { New-TcRemediationResult Blocking "group $GroupName without isAssignableToRole: a group administrator could add themselves to it and escape the policies. This setting can only be set at creation." }
    $without = @(Get-PolicyWithoutExclusion)
    $decided = @($without | Where-Object { (Get-TcMember $_ 'displayName') -in $ExcludedPolicies })
    $others = @($without | Where-Object { (Get-TcMember $_ 'displayName') -notin $ExcludedPolicies })
    if ($decided.Count) { New-TcRemediationResult Blocking ("{0} policy(ies) with no effective exclusion: {1}" -f $decided.Count, (@($decided | ForEach-Object { (Get-TcMember $_ 'displayName') }) -join ', ')) }
    if ($others.Count) { New-TcRemediationResult Warning ("{0} active policy(ies) not decided, which still apply to the emergency accounts: {1}" -f $others.Count, (@($others | ForEach-Object { (Get-TcMember $_ 'displayName') }) -join ', ')) }
    if (-not $without.Count) { New-TcRemediationResult OK 'emergency accounts excluded from all active policies, by their identifier or as members of the group' }
}
Close-TcRemediation

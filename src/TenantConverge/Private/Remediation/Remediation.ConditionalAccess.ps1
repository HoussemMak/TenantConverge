function Resolve-TcAccountId {
    <#
    .SYNOPSIS
    On the tenant, when it acts: the identifiers of the accounts present and enabled, and the list of the others.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant,
        [Parameter(Position = 1)][AllowEmptyCollection()][string[]]$Account
    )

    $ids = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($Account | Where-Object { $_ })) {
        $found = @(Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/users?`$filter=userPrincipalName eq '{0}'&`$select=id,accountEnabled" -f [uri]::EscapeDataString($name)) -All)
        if ($found.Count -and (Get-TcProperty $found[0] 'accountEnabled')) { $ids.Add($found[0]['id']) } else { $missing.Add($name) }
    }
    @{ Ids = @($ids); Missing = @($missing) }
}

function Get-TcConditionalAccessPolicy {
    <#
    .SYNOPSIS
    A conditional access policy of a tenant, by name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant,
        [Parameter(Mandatory, Position = 1)][string]$Name
    )

    @(Invoke-TcGraph -Tenant $Tenant -Uri $script:TcPolicyUri -All | Where-Object { (Get-TcProperty $_ 'displayName') -eq $Name }) | Select-Object -First 1
}

function Get-TcPolicyObservationDay {
    <#
    .SYNOPSIS
    The days since a policy was created or changed: going back to report-only restarts the observation.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param(
        [Parameter(Mandatory)]$Policy
    )

    $dates = @(@((Get-TcProperty $Policy 'createdDateTime'), (Get-TcProperty $Policy 'modifiedDateTime')) | Where-Object { $_ } | ForEach-Object { ([datetime]$_).ToUniversalTime() } | Sort-Object)
    if (-not $dates.Count) { throw 'Activation refused: the policy has no date, so the observation time cannot be proved.' }
    ((Get-TcRemediationNow).ToUniversalTime() - $dates[-1]).TotalDays
}

function Assert-TcActivationGuard {
    <#
    .SYNOPSIS
    Replayed on the tenant just before the write. A refusal is an error, never a way through.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)]$Policy
    )

    $state = Get-TcProperty $Policy 'state'
    if ($state -ne $script:TcReportOnlyState) { throw ('Activation refused: the policy is in state {0} on the tenant, not report-only.' -f $state) }
    if (Get-TcProperty (Invoke-TcGraph -Tenant $Tenant -Uri 'v1.0/policies/identitySecurityDefaultsEnforcementPolicy') 'isEnabled') { throw 'Activation refused: security defaults are on.' }
    $age = Get-TcPolicyObservationDay -Policy $Policy
    if ($age -lt $script:TcPolicyObservationDays) { throw ('Activation refused: the policy has been report-only, unchanged, for {0:N1} day(s), minimum {1}.' -f $age, $script:TcPolicyObservationDays) }
    $protected = @(Get-TcProtectedAccount $Tenant)
    $accounts = Resolve-TcAccountId -Tenant $Tenant -Account $protected
    if (-not $protected.Count -or $accounts['Missing'].Count) { throw ('Activation refused: emergency accounts missing or disabled: {0}.' -f $(if ($accounts['Missing'].Count) { $accounts['Missing'] -join ', ' } else { 'no account known' })) }
    # The target gets the permission of EMERGENCY-ACCESS. The sources do not have this check.
    if ($Tenant -eq 'Target') {
        $noKey = @($accounts['Ids'] | Where-Object { -not @(Invoke-TcGraph -Tenant $Tenant -Uri ('v1.0/users/{0}/authentication/fido2Methods' -f $_) -All).Count })
        if ($noKey.Count) { throw ('Activation refused: {0} emergency account(s) with no FIDO2 key: {1}.' -f $noKey.Count, ($noKey -join ', ')) }
    }
    $accounts
}

function Assert-TcExclusionKept {
    <#
    .SYNOPSIS
    After the write: reads the policy back. With no proof that each identifier stays excluded, it goes back to report-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Id
    )

    $missing = @($Id)
    for ($attempt = 1; $attempt -le 3 -and $missing.Count; $attempt++) {
        if ($attempt -gt 1) { Wait-TcRemediation -Seconds 5 }
        try {
            $read = Invoke-TcGraph -Tenant $Tenant -Uri $Uri
            $excluded = @(Get-TcProperty (Get-TcProperty (Get-TcProperty $read 'conditions') 'users') 'excludeUsers' @())
            $missing = @($Id | Where-Object { $_ -notin $excluded })
        }
        catch { $missing = @($Id) }
    }
    if (-not $missing.Count) { return }
    try { [void](Invoke-TcGraph -Tenant $Tenant -Method PATCH -Uri $Uri -Body @{ state = $script:TcReportOnlyState }) }
    catch { throw ('URGENT: {0} emergency account(s) not excluded from an active policy, and the return to report-only failed. Set {1} back to report-only by hand ({2}).' -f $missing.Count, $Uri, (Get-TcErrorText -ErrorInput $_)) }
    throw ('Activation undone: {0} emergency account(s) not excluded after the write, the policy went back to report-only: {1}.' -f $missing.Count, ($missing -join ', '))
}

function Get-TcExclusionResult {
    <#
    .SYNOPSIS
    The final check: each protected account exists and stays excluded. On an active policy, no proof is a block.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)]$Policy
    )

    $protected = @(Get-TcProtectedAccount $Tenant)
    $accounts = Resolve-TcAccountId -Tenant $Tenant -Account $protected
    $excluded = @(Get-TcProperty (Get-TcProperty (Get-TcProperty $Policy 'conditions') 'users') 'excludeUsers' @())
    $notExcluded = @($accounts['Ids'] | Where-Object { $_ -notin $excluded })
    if ($protected.Count -and -not $accounts['Missing'].Count -and -not $notExcluded.Count) { return (New-TcRemediationResult OK 'emergency accounts excluded') }
    $text = if ($protected.Count) { '{0} emergency account(s) missing, {1} not excluded' -f $accounts['Missing'].Count, $notExcluded.Count } else { 'no emergency account known for this tenant' }
    New-TcRemediationResult $(if ((Get-TcProperty $Policy 'state') -eq 'enabled') { 'Blocking' } else { 'Warning' }) $text
}

function Add-TcPolicyActivation {
    <#
    .SYNOPSIS
    Plans the activation of a policy already observed. -Critical stops the plan if it is refused.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$Name,
        [AllowEmptyCollection()][string[]]$Temporary = @(),
        [switch]$Critical
    )

    Add-TcBlockAction -Tenant $Tenant -Service Graph -Object $Name -Description ('Enable the policy {0}' -f $Name) -Data @{ Name = $Name; Temporary = @($Temporary) } -Critical:$Critical `
        -Test { param($a) $p = Get-TcConditionalAccessPolicy $a.tenant $a.data.Name; [bool]($p -and (Get-TcProperty $p 'state') -eq 'enabled') } `
        -Block {
        param($a)
        $p = Get-TcConditionalAccessPolicy $a.tenant $a.data.Name
        if (-not $p) { throw "Policy missing from the tenant: $($a.data.Name)." }
        $accounts = Assert-TcActivationGuard -Tenant $a.tenant -Policy $p
        $others = Resolve-TcAccountId -Tenant $a.tenant -Account @($a.data.Temporary)
        foreach ($name in $others['Missing']) { Write-TcRemediationAlert ('Temporary exclusion not found, or account disabled: {0}' -f $name) }
        # A full copy: the PATCH replaces what it receives, so the guest settings must go with the rest.
        $users = Copy-TcObject (Get-TcProperty (Get-TcProperty $p 'conditions') 'users')
        $users['excludeUsers'] = @(@($users['excludeUsers']) + @($accounts['Ids']) + @($others['Ids']) | Where-Object { $_ } | Select-Object -Unique)
        $users['excludeRoles'] = @(@($users['excludeRoles']) + @($script:TcSyncRoleId) | Where-Object { $_ } | Select-Object -Unique)
        $uri = "$($script:TcPolicyUri)/$($p['id'])"
        $a['undo'] = @{ type = 'Graph'; tenant = $a.tenant; method = 'PATCH'; uri = $uri; body = @{ state = $script:TcReportOnlyState } }
        [void](Invoke-TcGraph -Tenant $a.tenant -Method PATCH -Uri $uri -Body @{ state = 'enabled'; conditions = @{ users = $users } })
        Assert-TcExclusionKept -Tenant $a.tenant -Uri $uri -Id @($accounts['Ids'])
    }
}

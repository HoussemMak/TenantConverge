function Get-TcPlanAction {
    <#
    .SYNOPSIS
    Builds the actions of the plan: one per finding, plus the identity matrix and the go/no-go of each source.

    .DESCRIPTION
    A critical finding blocks the cutover. The draft matrix of a source blocks it too, until the customer
    validates it, and so do duplicates that point to a synced target account, because Exchange Online
    refuses to write addresses on those. A source whose accounts could not be read has no draft: its
    matrix action stays, blocking, and says why. The go/no-go sums up the blockers of its source without
    being one, and says what could not be read. It never says that nothing blocks a source it cannot see.
    Actions read in order of moment, blockers first, then by severity.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Context,
        [AllowEmptyCollection()][string[]]$IgnoreNameSuffix = @()
    )

    $procedures = Get-TcProcedureCatalog
    $actions = [ordered]@{}

    $newAction = {
        param([string]$Id, [string]$Role, [string]$Title, [string]$Moment, [string]$Severity, [string]$Procedure, [string]$Origin)
        [ordered]@{
            id = $Id; ruleId = ''; role = $Role; tenant = $Context['Names'][$Role]; wave = $Context['WaveOf'][$Role]; title = $Title; moment = $Moment; severity = $Severity
            blocking = $false; procedure = $(if ($procedures.Contains($Procedure)) { $Procedure } else { '' }); owner = 'Migration team and Customer'; effort = ''; workload = ''; category = ''
            relation = ''; finding = ''; action = ''; why = ''; question = ''; items = @(); itemCount = 0; origin = @($Origin)
        }
    }

    foreach ($finding in @(Get-TcProperty $Context['RuleSet'] 'findings' @())) {
        $role = if ($finding['code'] -eq 'Consolidation') { 'All' } else { $finding['code'] }
        $id = '{0}-{1}' -f $role, $finding['id']
        $number = 2
        while ($actions.Contains($id)) { $id = '{0}-{1}-{2}' -f $role, $finding['id'], $number; $number++ }

        $action = & $newAction $id $role $finding['title'] $finding['moment'] $finding['severity'] $finding['id'] 'Assessment'
        $action['ruleId'] = $finding['id']
        foreach ($key in 'owner', 'effort', 'workload', 'category', 'finding', 'action', 'why', 'question') { $action[$key] = [string]$finding[$key] }
        if ($finding['role'] -eq 'Both') { $action['relation'] = [string]$finding['tenant'] }
        $action['items'] = @($finding['items'])
        $action['itemCount'] = [int]$finding['itemCount']
        $action['blocking'] = $finding['severity'] -eq 'Critical'
        $actions[$id] = $action
    }

    $targetUsers = @(Get-TcProperty (Get-TcProperty (Get-TcProperty $Context['Snapshot']['tenants'] 'Target') 'tables') 'users' @())
    $synced = @{}
    foreach ($user in $targetUsers) { if (Get-TcProperty $user 'Synced') { $synced[([string](Get-TcProperty $user 'UPN')).ToLowerInvariant()] = $true } }

    $targetAccounts = Get-TcTableState -Snapshot $Context['Snapshot'] -Role 'Target' -Table 'users'

    foreach ($source in @($Context['Sources'])) {
        $sourceAccounts = Get-TcTableState -Snapshot $Context['Snapshot'] -Role $source -Table 'users'
        $sourceRead = $sourceAccounts.State -notin 'NotCollected', 'NotFullyRead'
        $notRead = if (-not $sourceRead) { $sourceAccounts } elseif (-not $Context['Snapshot']['tenants'].Contains('Target')) { $targetAccounts }

        if ($notRead) {
            $whose = if (-not $sourceRead) { 'this source' } else { 'the target' }
            $missing = & $newAction "$source-IDENTITY-MATRIX" $source 'Read the accounts, then have the identity matrix validated' 'Now' 'High' 'IDENTITY-MATRIX' 'Matrix'
            $missing['workload'] = 'Entra ID'
            $missing['blocking'] = $true
            $missing['drafted'] = $false
            $missing['finding'] = ('No draft: the accounts of {0} could not be read ({1}). {2}' -f $whose, $notRead.Status, $notRead.Message).Trim()
            $missing['action'] = ('{0} Then review the draft with the customer and get a decision for each row.' -f $notRead.Remedy).Trim()
            $actions[$missing['id']] = $missing
            continue
        }

        $rows = @(ConvertTo-TcIdentityMatrix -Snapshot $Context['Snapshot'] -SourceRole $source -IgnoreNameSuffix $IgnoreNameSuffix)

        if ($rows.Count) {
            $count = { param($Decision) @($rows | Where-Object { $_['Decision'] -eq $Decision }).Count }
            $review = @($rows | Where-Object { $_['Decision'] -eq 'To review' })
            $bookings = @($rows | Where-Object { $_['Notes'] -match 'Bookings' }).Count
            $matrix = & $newAction "$source-IDENTITY-MATRIX" $source 'Have the identity matrix validated' 'Now' 'High' 'IDENTITY-MATRIX' 'Matrix'
            $matrix['workload'] = 'Entra ID'
            $matrix['blocking'] = $true
            $matrix['finding'] = 'Draft: {0} row(s), {1} to create, {2} likely duplicate(s) in the target, {3} to review (including {4} Bookings page(s)).' -f $rows.Count, (& $count 'Create'), (& $count 'Duplicate'), $review.Count, $bookings
            if ($targetAccounts.State -in 'NotCollected', 'NotFullyRead') { $matrix['finding'] += ' The accounts of the target could not be read ({0}), so no duplicate was looked for.' -f $targetAccounts.Status }
            $matrix['action'] = 'Review the draft with the customer and get a decision for each row.'
            $matrix['items'] = @($review | ForEach-Object { '{0} ({1}){2}' -f $_['Display name'], $_['Source UPN'], $(if ($_['Notes']) { ": $($_['Notes'])" } else { '' }) })
            $matrix['itemCount'] = $review.Count
            $actions[$matrix['id']] = $matrix

            $duplicates = @($rows | Where-Object { $_['Decision'] -eq 'Duplicate' -and $synced.ContainsKey(([string]$_['Target UPN']).ToLowerInvariant()) })
            if ($duplicates.Count) {
                $action = & $newAction "$source-SYNCED-DUPLICATES" $source ('{0} synced account(s) of the target: addresses to add in on-premises Active Directory' -f $duplicates.Count) 'Before cutover' 'High' 'SYNCED-DUPLICATES' 'Matrix'
                $action['workload'] = 'Entra ID'
                $action['blocking'] = $true
                $action['finding'] = 'These duplicates point to a target account synced from on-premises Active Directory. Exchange Online refuses to write addresses on such an account.'
                $action['action'] = 'Add the source addresses in on-premises Active Directory, once the domain is verified in the target.'
                $action['items'] = @($duplicates | ForEach-Object { '{0} ({1}): {2}' -f $_['Display name'], $_['Source UPN'], $_['Target UPN'] })
                $action['itemCount'] = $duplicates.Count
                $actions[$action['id']] = $action
            }
        }
    }

    foreach ($action in @($actions.Values)) {
        if ($action['blocking'] -and $action['severity'] -notin 'Critical', 'High') { $action['severity'] = 'High' }
    }

    foreach ($source in @($Context['Sources'])) {
        $blockers = @($actions.Values | Where-Object { $_['role'] -eq $source -and $_['blocking'] })
        $go = & $newAction "$source-GO-NOGO" $source "Go/no-go decision for the cutover of $($Context['Names'][$source])" 'Cutover' 'High' 'GO-NOGO' 'Plan'
        $gaps = @(Get-TcPlanGap -Context $Context -Role $source)
        $go['finding'] = if ($blockers.Count) { '{0} blocking action(s) to close for this source.' -f $blockers.Count } elseif ($gaps.Count) { 'No blocking action found in what was read.' } else { 'No blocking action for this source.' }
        if ($gaps.Count) { $go['finding'] += ' Could not be read: {0}.' -f ($gaps -join ', ') }
        $go['action'] = 'Review the prerequisites with the customer, then record the decision and the decision maker.'
        $go['items'] = @($blockers | ForEach-Object { $_['title'] })
        $go['itemCount'] = $blockers.Count
        $actions[$go['id']] = $go
    }

    $moments = $Context['Moments']
    $ranks = @{ Critical = 0; High = 1; Medium = 2; Low = 3; Info = 4 }
    @($actions.Values | Sort-Object -Stable -Culture 'en-US' { [array]::IndexOf($moments, $_['moment']) }, { -not $_['blocking'] }, { $ranks[$_['severity']] }, { $_['title'] }, { $_['id'] })
}

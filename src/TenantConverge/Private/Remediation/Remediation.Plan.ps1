function New-TcRemediationAction {
    <#
    .SYNOPSIS
    The base of every action of a plan.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a value in memory.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [string]$Tenant,
        [string]$Type,
        [string]$Service,
        [string]$Object,
        [string]$Description,
        [scriptblock]$Test,
        $Undo,
        [string]$Reason,
        [switch]$Critical,
        [string[]]$AlsoWrites = @()
    )

    $run = $script:TcRemediationRun
    foreach ($role in @($Tenant) + $AlsoWrites) { if ($role -notin $run['Known']) { throw "Action on an unknown tenant: $role." } }
    [ordered]@{
        id = 'A-{0:D4}' -f ($run['Actions'].Count + 1); tenant = $Tenant; alsoWrites = @($AlsoWrites); written = @(); type = $Type; service = $Service; object = $Object; description = $Description; test = $Test; undo = $Undo; reason = $Reason
        critical = [bool]$Critical; status = 'Planned'; error = ''; timestamp = ''; postponed = $false; method = ''; uri = ''; body = $null; command = ''; parameters = @{}; url = ''; dns = $null
        instruction = @(); waitUntil = $null; minutes = 0; interval = 0; who = ''; data = $null; block = $null
    }
}

function Add-TcGraphAction {
    <#
    .SYNOPSIS
    Plans a write to Microsoft Graph. PATCH restores the values read before it, POST deletes what it created.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][ValidateSet('POST', 'PATCH', 'PUT', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [Parameter(Mandatory)][string]$Object,
        [Parameter(Mandatory)][string]$Description,
        [scriptblock]$Test,
        $Undo = 'auto',
        [string]$Reason,
        [switch]$Critical
    )

    $action = New-TcRemediationAction -Tenant $Tenant -Type Graph -Service Graph -Object $Object -Description $Description -Test $Test -Undo $Undo -Reason $Reason -Critical:$Critical
    $action['method'] = $Method; $action['uri'] = $Uri; $action['body'] = $Body
    $script:TcRemediationRun['Actions'].Add($action)
}

function Add-TcCommandAction {
    <#
    .SYNOPSIS
    Plans a cmdlet of Exchange (Exo), Purview (Scc), Teams or SharePoint (Pnp).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][ValidateSet('Exo', 'Scc', 'Teams', 'Pnp')][string]$Service,
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Parameters = @{},
        [string]$Url,
        [Parameter(Mandatory)][string]$Object,
        [Parameter(Mandatory)][string]$Description,
        [scriptblock]$Test,
        $Undo = $null,
        [string]$Reason,
        [switch]$Critical
    )

    $action = New-TcRemediationAction -Tenant $Tenant -Type Command -Service $Service -Object $Object -Description $Description -Test $Test -Undo $Undo -Reason $Reason -Critical:$Critical
    $action['command'] = $Command; $action['parameters'] = $Parameters; $action['url'] = $Url
    $script:TcRemediationRun['Actions'].Add($action)
}

function Add-TcDnsAction {
    <#
    .SYNOPSIS
    Plans a DNS record of a zone. It waits for the public DNS, and the undo restores the values read before.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$Zone,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('MX', 'TXT', 'CNAME')][string]$Type,
        [string]$Value,
        [int]$Ttl = 300,
        [int]$Priority = 0,
        [ValidateSet('Set', 'Add', 'Remove', 'TTL')][string]$Action = 'Set',
        [switch]$NoWait,
        [Parameter(Mandatory)][string]$Description,
        [scriptblock]$Test,
        [switch]$Critical
    )

    $entry = New-TcRemediationAction -Tenant $Tenant -Type Dns -Service Dns -Object "$Type $Name" -Description $Description -Test $Test -Undo 'auto' -Critical:$Critical
    $entry['dns'] = [ordered]@{ zone = $Zone; name = $Name; type = $Type; value = $Value; ttl = $Ttl; priority = $Priority; action = $Action; wait = (-not $NoWait) }
    $script:TcRemediationRun['Actions'].Add($entry)
}

function Add-TcManualAction {
    <#
    .SYNOPSIS
    Plans what no API allows. With -WaitUntil the engine polls until the block returns true.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$Object,
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][string[]]$Instruction,
        [scriptblock]$WaitUntil,
        [int]$Minutes = 60,
        [int]$IntervalSeconds = 60,
        [string]$Who = 'Migration team',
        $Data
    )

    $action = New-TcRemediationAction -Tenant $Tenant -Type Manual -Service None -Object $Object -Description $Description -Undo $null -Reason 'Done by a person, outside the script.'
    $action['instruction'] = @($Instruction); $action['waitUntil'] = $WaitUntil; $action['minutes'] = $Minutes; $action['interval'] = $IntervalSeconds; $action['who'] = $Who; $action['data'] = $Data
    $script:TcRemediationRun['Actions'].Add($action)
}

function Add-TcBlockAction {
    <#
    .SYNOPSIS
    Plans a series of calls that form one operation. The block receives the action and runs only with -Apply.

    .PARAMETER AlsoWrites
    The other tenants the block writes to. Their primary domain is asked before the first write of the
    run, and the block reaches them through $a.alsoWrites. A write to any other tenant is refused.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][ValidateSet('Graph', 'Exo', 'Scc', 'Teams', 'Pnp')][string]$Service,
        [Parameter(Mandatory)][scriptblock]$Block,
        $Data,
        [Parameter(Mandatory)][string]$Object,
        [Parameter(Mandatory)][string]$Description,
        [scriptblock]$Test,
        $Undo = $null,
        [string]$Reason,
        [switch]$Critical,
        [string[]]$AlsoWrites = @()
    )

    $action = New-TcRemediationAction -Tenant $Tenant -Type Block -Service $Service -Object $Object -Description $Description -Test $Test -Undo $Undo -Reason $Reason -Critical:$Critical -AlsoWrites $AlsoWrites
    $action['block'] = $Block; $action['data'] = $Data
    $script:TcRemediationRun['Actions'].Add($action)
}

function Protect-TcRemediationAction {
    <#
    .SYNOPSIS
    A copy of an action that can go in a log: secrets masked, blocks removed.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $copy = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) {
            if ($key -in 'test', 'block', 'waitUntil' -and $InputObject[$key] -is [scriptblock]) { continue }
            $copy[$key] = if ($key -in 'password', 'temporaryAccessPass', 'secretText', 'client_assertion', 'newPassword') { '********' } else { Protect-TcRemediationAction -InputObject $InputObject[$key] }
        }
        return $copy
    }
    if ($InputObject -is [string] -or $InputObject.GetType().IsValueType) { return $InputObject }
    if ($InputObject -is [scriptblock]) { return '{block}' }
    if ($InputObject -is [System.Collections.IEnumerable]) { return , @($InputObject | ForEach-Object { Protect-TcRemediationAction -InputObject $_ }) }
    [string]$InputObject
}

function Write-TcOperation {
    <#
    .SYNOPSIS
    Adds the state of an action to operations.jsonl. Undo-TcRemediation reads this file.

    .PARAMETER Path
    The journal to add to. Without it, the one of the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Action,
        [string]$Path = $script:TcRemediationRun['OperationsFile']
    )

    $line = (Protect-TcRemediationAction -InputObject $Action) | ConvertTo-Json -Depth 30 -Compress
    [System.IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Read-TcOperation {
    <#
    .SYNOPSIS
    The final state of each action of a journal: the last line of each identifier.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $byId = [ordered]@{}
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line.Trim()) {
            $operation = $line | ConvertFrom-Json -AsHashtable -Depth 40
            $byId[$operation['id']] = $operation
        }
    }
    @($byId.Values)
}

function Get-TcAutomaticUndo {
    <#
    .SYNOPSIS
    Reads the current values just before a change, so the change can be undone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Action
    )

    if ($Action['type'] -eq 'Graph' -and $Action['method'] -eq 'PATCH' -and $Action['body']) {
        # $select is required: a plain GET on a user leaves out accountEnabled, and the undo would be wrong.
        $separator = if ($Action['uri'] -match '\?') { '&' } else { '?' }
        try { $current = Invoke-TcGraph -Tenant $Action['tenant'] -Uri ("{0}{1}`$select={2}" -f $Action['uri'], $separator, (@($Action['body'].Keys) -join ',')) }
        catch { $current = Invoke-TcGraph -Tenant $Action['tenant'] -Uri $Action['uri'] }
        $before = [ordered]@{}
        foreach ($key in @($Action['body'].Keys)) { $before[$key] = Get-TcProperty $current $key }
        return @{ type = 'Graph'; tenant = $Action['tenant']; method = 'PATCH'; uri = $Action['uri']; body = $before }
    }
    if ($Action['type'] -eq 'Dns') { return @{ type = 'Dns'; tenant = $Action['tenant']; dns = $Action['dns']; before = @(Resolve-TcDnsEntry -Name $Action['dns']['name'] -Type $Action['dns']['type']) } }
    $null
}

function Invoke-TcManualAction {
    <#
    .SYNOPSIS
    Shows the instruction. Returns true when the action is seen done, false when it is left to a person.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Action
    )

    Write-TcRemediationInstruction -Line @($Action['instruction'])
    Write-TcLog -Message ('{0}: {1} ({2})' -f $Action['who'], $Action['description'], ($Action['instruction'] -join ' ')) -Step $Action['id']
    if (-not $Action['waitUntil']) { return $false }
    $end = (Get-TcRemediationNow).AddMinutes($Action['minutes'])
    while ($true) {
        if (& $Action['waitUntil'] $Action) { return $true }
        if ((Get-TcRemediationNow) -ge $end) { return $false }
        Write-TcMessage -Message ('        {0}: next check in {1} s (limit {2:HH:mm})' -f $Action['object'], $Action['interval'], $end)
        Wait-TcRemediation -Seconds $Action['interval']
    }
}

function Invoke-TcRemediationAction {
    <#
    .SYNOPSIS
    Runs one action and returns the answer of the service.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Action
    )

    switch ($Action['type']) {
        'Graph' { return (Invoke-TcGraph -Tenant $Action['tenant'] -Method $Action['method'] -Uri $Action['uri'] -Body $Action['body']) }
        'Command' { return (Invoke-TcServiceCommand -Tenant $Action['tenant'] -Service $Action['service'] -Command $Action['command'] -Parameters $Action['parameters'] -Url $Action['url']) }
        'Dns' { Invoke-TcDnsAction -Action $Action; return $null }
        'Block' { return (& $Action['block'] $Action) }
        default { throw "Unknown action type: $($Action['type'])." }
    }
}

function Get-TcActionTenant {
    <#
    .SYNOPSIS
    Every tenant an action declares: its own, and those its block also writes to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Action
    )

    @(@($Action['tenant']) + @($Action['alsoWrites']) | Where-Object { $_ })
}

function Show-TcRemediationPreview {
    <#
    .SYNOPSIS
    Shows what the plan would do, tenant by tenant.
    #>
    [CmdletBinding()]
    param()

    $run = $script:TcRemediationRun
    foreach ($tenant in @($run['Actions'] | ForEach-Object { Get-TcActionTenant -Action $_ } | Select-Object -Unique)) {
        $own = @($run['Actions'] | Where-Object { $tenant -in @(Get-TcActionTenant -Action $_) })
        $manual = @($own | Where-Object { $_['type'] -eq 'Manual' }).Count
        Write-TcRemediationLine -Status Planned -Text ('{0}: {1} action(s) planned{2}' -f $tenant, $own.Count, $(if ($manual) { ", $manual by a person" } else { '' })) -Step $run['Id']
        foreach ($action in @($own | Select-Object -First 8)) { Write-TcMessage -Message "          $($action['description'])" }
        if ($own.Count -gt 8) { Write-TcMessage -Message ('          ... and {0} more, see plan.csv' -f ($own.Count - 8)) }
    }
}

function Test-TcRemovingAction {
    <#
    .SYNOPSIS
    True when an action of the plan deletes or removes an object.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Action
    )

    $Action['method'] -eq 'DELETE' -or $Action['command'] -match '^(Remove|Disable|Clear)-' -or ($Action['dns'] -and $Action['dns']['action'] -eq 'Remove')
}

function Confirm-TcRemediationUntested {
    <#
    .SYNOPSIS
    Asks for the word UNTESTED, once in a run. -AcknowledgeUntested replaces it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $run = $script:TcRemediationRun
    if ($run['Acknowledged']) { return $true }
    $answer = Read-TcAnswer -Prompt "$($run['Id']) has never run on a real tenant. Type UNTESTED to go on"
    $run['Acknowledged'] = [string]$answer -ceq 'UNTESTED'
    $run['Acknowledged']
}

function Confirm-TcRemediationApply {
    <#
    .SYNOPSIS
    Asks a person to confirm before the first write. Any answer but the expected one stops the run.

    .DESCRIPTION
    First the word UNTESTED, unless the run already has it. Then the primary domain of each tenant the
    plan touches, which nothing replaces. Then, when the script removes objects, the word REMOVE, which
    nothing replaces either. The run keeps the tenants confirmed: a write to any other is refused.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Tenant,
        [bool]$Removal
    )

    $run = $script:TcRemediationRun
    if (-not (Confirm-TcRemediationUntested)) { return $false }
    foreach ($role in $Tenant) {
        $info = Get-TcRemediationTenant -Tenant $role
        $answer = Read-TcAnswer -Prompt ("Type the primary domain of {0} ({1}) to write to this tenant" -f $info['Name'], $role)
        if (([string]$answer).Trim() -ine $info['PrimaryDomain'] -or -not $info['PrimaryDomain']) { return $false }
    }
    if ($Removal) {
        $answer = Read-TcAnswer -Prompt "$($run['Id']) removes objects from the tenant. Type REMOVE to confirm"
        if ([string]$answer -cne 'REMOVE') { return $false }
    }
    $run['ConfirmedTenants'] = @($Tenant)
    $true
}

function Invoke-TcRemediationPlan {
    <#
    .SYNOPSIS
    Shows the plan, and with -Apply confirms, then runs each action: test, log, run, log.

    .PARAMETER Verify
    Runs for each tenant after the actions. It returns results from New-TcRemediationResult.
    #>
    [CmdletBinding()]
    param(
        [scriptblock]$Verify
    )

    Close-TcRemediationBlock
    $tcRun = $script:TcRemediationRun
    $tcRun['Rank']++
    Write-TcStepStart -Rank $tcRun['Rank'] -Total $tcRun['Total'] -Id 'Plan' -Title $(if ($tcRun['Apply']) { 'Actions to apply' } else { 'Actions planned' })
    $tcClock = [System.Diagnostics.Stopwatch]::StartNew()
    $tcCopy = @($tcRun['Actions'] | ForEach-Object { Protect-TcRemediationAction -InputObject $_ })
    Write-TcJsonFile -Path (Join-Path $tcRun['Folder'] 'plan.json') -InputObject $tcCopy
    if ($tcCopy.Count) {
        $tcCopy | ForEach-Object {
            [pscustomobject]@{
                Id = $_['id']; Tenant = $_['tenant']; 'Also writes' = @($_['alsoWrites']) -join ', '; Service = $_['service']; Object = ConvertTo-TcCsvCell $_['object']; Description = ConvertTo-TcCsvCell $_['description']
                Undo = $(if ($_['undo']) { 'Yes' } else { 'No' }); Reason = ConvertTo-TcCsvCell $_['reason']
            }
        } | Export-Csv -LiteralPath (Join-Path $tcRun['Folder'] 'plan.csv') -NoTypeInformation -Encoding utf8BOM
    }
    if (-not $tcRun['Actions'].Count) { Write-TcRemediationLine -Status Info -Text 'Nothing to do, from the snapshot and the decisions.' -Step $tcRun['Id'] }

    if (-not $tcRun['Apply']) {
        Show-TcRemediationPreview
        Write-TcStepEnd -Status Done -Seconds $tcClock.Elapsed.TotalSeconds -Detail ('{0} action(s), none applied' -f $tcRun['Actions'].Count)
        return
    }
    if (-not $tcRun['Actions'].Count) { return }

    Show-TcRemediationPreview
    $tcWriting = @($tcRun['Actions'] | Where-Object { $_['type'] -ne 'Manual' })
    $tcRemoval = [bool]$tcRun['Entry']['removesObjects'] -or @($tcWriting | Where-Object { Test-TcRemovingAction -Action $_ }).Count -gt 0
    $tcTouched = @($tcRun['Actions'] | ForEach-Object { Get-TcActionTenant -Action $_ } | Select-Object -Unique)
    if (-not (Confirm-TcRemediationApply -Tenant $tcTouched -Removal $tcRemoval)) {
        $tcRun['Stopped'] = $true
        Write-TcRemediationLine -Status Warning -Text 'Not confirmed. Stopped: nothing was changed.' -Step $tcRun['Id']
        return
    }

    $tcIndex = 0
    foreach ($tcAction in $tcRun['Actions']) {
        $tcIndex++
        $tcRun['CurrentAction'] = $tcAction
        Write-Progress -Activity $tcRun['Entry']['title'] -Status $tcAction['description'] -PercentComplete (100 * $tcIndex / $tcRun['Actions'].Count)
        try {
            if ($tcAction['type'] -eq 'Manual') {
                $tcDone = Invoke-TcManualAction -Action $tcAction
                $tcAction['status'] = if ($tcDone) { 'Already in place' } else { 'For a person' }
                Write-TcRemediationLine -Status $(if ($tcDone) { 'OK' } else { 'Manual' }) -Text $tcAction['description'] -Step $tcAction['id']
                Write-TcOperation -Action $tcAction
                continue
            }
            if ($tcAction['test'] -and (& $tcAction['test'] $tcAction)) {
                # A test can postpone the action: it is not in place, and a rerun picks it up.
                $tcAction['status'] = if ($tcAction['postponed']) { 'Postponed' } else { 'Already in place' }
                Write-TcRemediationLine -Status Skipped -Text $(if ($tcAction['postponed']) { $tcAction['description'] } else { "Already in place: $($tcAction['description'])" }) -Step $tcAction['id']
                Write-TcOperation -Action $tcAction
                continue
            }
            if ($tcAction['undo'] -eq 'auto') { $tcAction['undo'] = Get-TcAutomaticUndo -Action $tcAction }
            $tcAction['status'] = 'Running'
            $tcAction['timestamp'] = (Get-Date).ToString('o')
            Write-TcOperation -Action $tcAction
            $tcAnswer = Invoke-TcRemediationAction -Action $tcAction
            # Deleting what was created only makes sense on a real collection, not on an invitation or a link.
            if ($tcAction['type'] -eq 'Graph' -and $tcAction['method'] -eq 'POST' -and -not $tcAction['undo'] -and -not $tcAction['reason'] -and $tcAnswer -is [System.Collections.IDictionary] -and (Get-TcProperty $tcAnswer 'id') -and $tcAction['uri'] -notmatch $script:TcNoUndoPost) {
                $tcAction['undo'] = @{ type = 'Graph'; tenant = $tcAction['tenant']; method = 'DELETE'; uri = ('{0}/{1}' -f ($tcAction['uri'] -replace '\?.*$', ''), $tcAnswer['id']) }
            }
            $tcAction['status'] = 'Applied'
            Write-TcOperation -Action $tcAction
            Write-TcRemediationLine -Status Applied -Text $tcAction['description'] -Step $tcAction['id']
        }
        catch {
            $tcText = Get-TcErrorText -ErrorInput $_
            $tcAction['status'] = 'Failed'
            $tcAction['error'] = $tcText
            Write-TcOperation -Action $tcAction
            Write-TcRemediationLine -Status Failed -Text ('{0}: {1}' -f $tcAction['description'], $tcText) -Step $tcAction['id']
            Write-TcLog -Message ('Detail: {0}' -f (($_.ScriptStackTrace -split "`n") | Select-Object -First 1)) -Level ERROR -Step $tcAction['id']
            if ($tcAction['critical']) {
                Write-TcRemediationLine -Status Blocking -Text 'Critical action failed: the rest of the plan does not run. Run it again after the fix: what is in place is skipped.' -Step $tcAction['id']
                break
            }
        }
    }
    $tcRun['CurrentAction'] = $null
    Write-Progress -Activity $tcRun['Entry']['title'] -Completed
    $tcTally = Get-TcRemediationTally
    Write-TcStepEnd -Status $(if ($tcTally['Failed']) { 'Warning' } else { 'Done' }) -Seconds $tcClock.Elapsed.TotalSeconds -Detail ('{0} applied, {1} already in place, {2} failed' -f $tcTally['Applied'], $tcTally['AlreadyInPlace'], $tcTally['Failed'])

    if ($Verify) {
        Write-TcPhase -Title 'Checking the tenants' -StepCount $tcRun['Tenants'].Count
        foreach ($tcRole in $tcRun['Tenants']) {
            try {
                foreach ($tcResult in @(& $Verify $tcRole)) {
                    if ($null -eq $tcResult) { continue }
                    Write-TcRemediationLine -Status $tcResult['status'] -Text ('{0}: {1}' -f $tcRole, $tcResult['message']) -Step 'Check'
                    $tcRun['Results'].Add($tcResult)
                    if ($tcResult['status'] -in 'Warning', 'Blocking') { $tcRun['Alerts']++ }
                    if ($tcResult['status'] -eq 'Blocking') { $tcRun['Blocking']++ }
                }
            }
            catch {
                $tcRun['Blocking']++
                Write-TcLog -Message ('{0}: check stopped. {1}' -f $tcRole, (($_.ScriptStackTrace -split "`n") | Select-Object -First 1)) -Level WARN
                Write-TcRemediationAlert ('{0}: check impossible ({1})' -f $tcRole, (Get-TcErrorText -ErrorInput $_))
            }
        }
    }
}

function New-TcRemediationResult {
    <#
    .SYNOPSIS
    The result of a check: OK, Warning, Blocking or Info.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds a value in memory.')]
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('OK', 'Warning', 'Blocking', 'Info')][string]$Status,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Message
    )

    [ordered]@{ status = $Status; message = $Message }
}

function Get-TcRemediationTally {
    <#
    .SYNOPSIS
    Counts the actions of the run by status.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $actions = @($script:TcRemediationRun['Actions'])
    $count = { param([string[]]$Status) @($actions | Where-Object { $_['status'] -in $Status }).Count }
    @{
        Total = $actions.Count; Applied = & $count 'Applied'; AlreadyInPlace = & $count 'Already in place'; Failed = & $count 'Failed'
        ForAPerson = @($actions | Where-Object { $_['status'] -eq 'For a person' -or ($_['type'] -eq 'Manual' -and $_['status'] -eq 'Planned') }).Count
        Waiting = & $count 'Running', 'Postponed'
    }
}

function Get-TcWrittenTenant {
    <#
    .SYNOPSIS
    The tenant an operation of the journal changed: the only one written to, otherwise its own.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Operation
    )

    $written = @(Get-TcProperty $Operation 'written' @())
    if ($written.Count -eq 1) { return [string]$written[0] }
    [string]$Operation['tenant']
}

function Get-TcUndoTenant {
    <#
    .SYNOPSIS
    The tenants the undo of an operation writes to: those it names, otherwise the one the journal gives.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Operation
    )

    $written = Get-TcWrittenTenant -Operation $Operation
    @(@($Operation['undo']) | ForEach-Object { Get-TcProperty $_ 'tenant' $written } | Select-Object -Unique)
}

function Test-TcRemovingUndo {
    <#
    .SYNOPSIS
    True when replaying the undo of an operation deletes or removes an object.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Operation
    )

    @(@($Operation['undo']) | Where-Object { (Get-TcProperty $_ 'method') -eq 'DELETE' -or (Get-TcProperty $_ 'command') -match '^(Remove|Disable|Clear)-' -or ((Get-TcProperty $_ 'type') -eq 'Dns' -and (Get-TcDnsAddedValue -Undo $_)) }).Count -gt 0
}

function Invoke-TcUndoOperation {
    <#
    .SYNOPSIS
    Replays one undo: Graph, a command or DNS. A block can carry several.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Undo,
        [string]$Tenant,
        [string]$Service
    )

    if ($Undo -is [System.Collections.IList]) {
        foreach ($item in @($Undo)) { Invoke-TcUndoOperation -Undo $item -Tenant $Tenant -Service $Service }
        return
    }
    $role = Get-TcProperty $Undo 'tenant' $Tenant
    $kind = Get-TcProperty $Undo 'type' ''
    if ($kind -eq 'Graph') {
        [void](Invoke-TcGraph -Tenant $role -Method $Undo['method'] -Uri $Undo['uri'] -Body (Get-TcProperty $Undo 'body'))
        return
    }
    if ($kind -eq 'Dns') {
        Restore-TcDnsRecord -Tenant $role -Undo $Undo
        return
    }
    [void](Invoke-TcServiceCommand -Tenant $role -Service (Get-TcProperty $Undo 'service' $Service) -Command $Undo['command'] -Parameters (ConvertTo-TcPlainHashtable -InputObject (Get-TcProperty $Undo 'parameters' @{})) -Url (Get-TcProperty $Undo 'url' ''))
}

function ConvertTo-TcPlainHashtable {
    <#
    .SYNOPSIS
    Copies a dictionary into a hashtable, for a splat.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]$InputObject
    )

    $copy = @{}
    if ($InputObject -is [System.Collections.IDictionary]) { foreach ($key in @($InputObject.Keys)) { $copy[$key] = $InputObject[$key] } }
    $copy
}

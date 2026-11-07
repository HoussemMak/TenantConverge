function Get-TcRemediationCatalog {
    <#
    .SYNOPSIS
    Reads Data\remediations.json once, by identifier.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param()

    if ($null -eq $script:TcRemediationCatalog) {
        $data = Read-TcJsonFile -Path (Join-Path $PSScriptRoot '..\..\Data\remediations.json')
        $catalog = [ordered]@{}
        foreach ($entry in @($data['remediations'])) { $catalog[$entry['id']] = $entry }
        $script:TcRemediationCatalog = $catalog
    }
    $script:TcRemediationCatalog
}

function Get-TcRemediationEntry {
    <#
    .SYNOPSIS
    Returns one entry of the manifest, and refuses an identifier it does not know.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Id
    )

    $catalog = Get-TcRemediationCatalog
    if (-not $catalog.Contains($Id)) { throw "Unknown remediation: $Id. Get-TcRemediation lists them." }
    $catalog[$Id]
}

function Get-TcRemediationDefault {
    <#
    .SYNOPSIS
    The settings a remediation reads, with their defaults.

    .DESCRIPTION
    Names of the objects a script creates, thresholds, and the accounts it must never touch. Nothing here
    names a project. A person changes them in <output>\decisions\settings.json, or with -Setting.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @{
        ObjectPrefix = 'TenantConverge'; EmergencyAccountPrefix = 'emergency'; EmergencyAccountCount = 2; EmergencyAccountDomain = ''
        ProtectedAccountPattern = '^(emergency|breakglass|rescue)'; MigrationAccountPattern = ''; ProtectedApplicationPattern = '^TenantConverge '
        KeptAccounts = @{}; InactiveDays = 90; StaleDeviceDays = 90; LargeMailboxGb = 45; LargeSiteGb = 100; SecretExpiryDays = 60; LicenseSku = ''; UsageLocation = 'US'
        StorageMarginPercent = 20; DomainRemovalMinutes = 1440; DeviceNamePattern = 'DEV-%RAND:4%'; SourceGroups = @{}; UsualCountries = @('US')
        DnsServer = '1.1.1.1'; DnsTtl = 300; DnsWaitMinutes = 120; DnsPollSeconds = 30; DnsApiTokenVariable = 'CF_API_TOKEN'; DnsHosts = @{}
        MaxSnapshotAgeDays = 14; TestRecipients = @(); TestSender = ''; SharePointAdminUrl = @{}; PnpClientId = ''
    }
}

function Get-TcRemediationOption {
    <#
    .SYNOPSIS
    Reads one setting of the running remediation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name
    )

    $options = $script:TcRemediationRun['Options']
    if (-not $options.ContainsKey($Name)) { throw "Unknown remediation setting: $Name." }
    $options[$Name]
}

function Resolve-TcRemediationOption {
    <#
    .SYNOPSIS
    Merges the defaults, the file <output>\decisions\settings.json and -Setting. An unknown name stops the run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$DecisionFolder,
        [hashtable]$Setting = @{}
    )

    $options = Get-TcRemediationDefault
    $file = Join-Path $DecisionFolder 'settings.json'
    $layers = @()
    if (Test-Path -LiteralPath $file) { $layers += , (Read-TcJsonFile -Path $file) }
    $layers += , $Setting
    foreach ($layer in $layers) {
        foreach ($key in @($layer.Keys)) {
            if (-not $options.ContainsKey($key)) { throw "Unknown remediation setting: $key. Known settings: $(@($options.Keys | Sort-Object) -join ', ')." }
            $options[$key] = $layer[$key]
        }
    }
    $options
}

function Write-TcUntestedNotice {
    <#
    .SYNOPSIS
    Shows the notice every run must show, on screen and in the log.
    #>
    [CmdletBinding()]
    param()

    Write-TcMessage -Message $script:TcUntestedNotice -Level Warning
    Write-TcLog -Message $script:TcUntestedNotice -Level WARN
}

function New-TcRemediationRun {
    <#
    .SYNOPSIS
    Prepares what a remediation reads: its tenants, its folder, its settings and its data.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Prepares a local run. No tenant is touched.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Entry,
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan,
        [string[]]$Tenant,
        [bool]$Apply,
        [bool]$Acknowledged,
        [hashtable]$Setting = @{},
        [Parameter(Mandatory)][string]$Output
    )

    $decisionFolder = Join-Path $Output 'decisions'
    $options = Resolve-TcRemediationOption -DecisionFolder $decisionFolder -Setting $Setting
    $sources = @(@(Get-TcProperty $Project 'sources' @()) | ForEach-Object { Get-TcProperty $_ 'role' } | Sort-Object)
    $known = @('Target') + $sources

    $roles = @($Tenant | Where-Object { $_ } | ForEach-Object { $_ -split '[,; ]+' } | Where-Object { $_ })
    foreach ($role in $roles) { if ($role -notin $known) { throw "Unknown tenant: $role. This project has $($known -join ', ')." } }
    if (-not $roles.Count) {
        $roles = switch ([string](Get-TcProperty $Entry 'scope' 'Plan')) {
            'Target' { @('Target') }
            'Source' { $sources }
            'All' { $known }
            default { Get-TcRemediationPlanRole -Plan $Plan -RuleId @(Get-TcProperty $Entry 'ruleIds' @()) -Known $known }
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $folder = Join-Path (Join-Path $Output 'remediations') ('{0}-{1}-{2}' -f $stamp, $Entry['id'], $(if ($Apply) { 'Apply' } else { 'Preview' }))
    $number = 2
    while (Test-Path -LiteralPath $folder) { $folder = Join-Path (Join-Path $Output 'remediations') ('{0}-{1}-{2}-{3}' -f $stamp, $Entry['id'], $(if ($Apply) { 'Apply' } else { 'Preview' }), $number); $number++ }

    @{
        Entry = $Entry; Id = $Entry['id']; Project = $Project; Snapshot = $Snapshot; PlanData = $Plan; Tenants = @($roles); Known = $known; Sources = $sources; Apply = $Apply; Acknowledged = $Acknowledged
        ConfirmedTenants = @(); CurrentAction = $null; Stopped = $false; Refused = $false; Folder = $folder; Output = $Output; DecisionFolder = $decisionFolder; Options = $options; Started = Get-Date; OperationsFile = Join-Path $folder 'operations.jsonl'
        Actions = [System.Collections.Generic.List[object]]::new(); Results = [System.Collections.Generic.List[object]]::new(); Alerts = 0; Pending = 0; Reports = 0; Blocking = 0; Rank = 0; Total = @($roles).Count + 1
        BlockOpen = $false; Clock = $null; Family = $null; Connections = @{}; Postponed = @{}; UnreadSaid = @{}; AcceptedDomains = $null
    }
}

function Open-TcRemediation {
    <#
    .SYNOPSIS
    Opens the run for the script that starts: the first line of every remediation.
    #>
    [CmdletBinding()]
    param()

    $run = $script:TcRemediationRun
    Initialize-TcLog -Path $run['Folder']
    Write-TcUntestedNotice
    Write-TcMessage -Message ('{0}: {1}' -f $run['Id'], $run['Entry']['title'])
    Write-TcMessage -Message ('Tenants: {0}' -f $(if ($run['Tenants'].Count) { $run['Tenants'] -join ', ' } else { 'none in the plan' }))
    Write-TcMessage -Message $(if ($run['Apply']) { 'Mode: APPLY. The confirmed changes are written to the tenants.' } else { 'Mode: PREVIEW. No connection and no write.' })
    Write-TcMessage -Message "Log: $($run['Folder'])"
    Write-TcLog -Message ('Start {0}, tenants {1}, apply {2}' -f $run['Id'], ($run['Tenants'] -join ','), $run['Apply'])

    # Here, not with the other confirmations: some scripts read a tenant to build their plan, and that read signs in.
    if ($run['Apply'] -and -not (Confirm-TcRemediationUntested)) {
        $run['Stopped'] = $true
        $run['Refused'] = $true
        Write-TcRemediationLine -Status Warning -Text 'Not confirmed. Stopped: nothing was changed.' -Step $run['Id']
        throw 'Not confirmed.'
    }

    [pscustomobject]@{ Id = $run['Id']; Tenants = @($run['Tenants']); Apply = $run['Apply']; Folder = $run['Folder'] }
}

function Close-TcRemediationBlock {
    <#
    .SYNOPSIS
    Ends the block of the current tenant on screen.
    #>
    [CmdletBinding()]
    param()

    $run = $script:TcRemediationRun
    if (-not $run['BlockOpen']) { return }
    Write-TcStepEnd -Status Done -Seconds $run['Clock'].Elapsed.TotalSeconds
    $run['BlockOpen'] = $false
}

function Write-TcRemediationTenant {
    <#
    .SYNOPSIS
    Announces the tenant the next lines are about.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant,
        [Parameter(Position = 1)][string]$Title = ''
    )

    Close-TcRemediationBlock
    $run = $script:TcRemediationRun
    $run['Rank']++
    Write-TcStepStart -Rank $run['Rank'] -Total $run['Total'] -Id $Tenant -Title $(if ($Title) { $Title } else { (Get-TcRemediationTenant -Tenant $Tenant)['Name'] })
    $run['Clock'] = [System.Diagnostics.Stopwatch]::StartNew()
    $run['BlockOpen'] = $true
}

function Write-TcRemediationLine {
    <#
    .SYNOPSIS
    Shows one result on screen and in the log, with the status of the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('OK', 'Warning', 'Blocking', 'Info', 'Planned', 'Applied', 'Failed', 'Manual', 'Skipped')][string]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Step = ''
    )

    $shown = switch ($Status) {
        { $_ -in 'OK', 'Applied' } { 'OK' }
        { $_ -in 'Warning', 'Blocking', 'Failed', 'Manual' } { 'Warning' }
        default { 'Info' }
    }
    Write-TcStepLine -Status $shown -Text "$Status`: $Text" -Step $Step
}

function Write-TcRemediationNote {
    <#
    .SYNOPSIS
    Writes a fact about the tenant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text
    )

    Write-TcRemediationLine -Status Info -Text $Text -Step $script:TcRemediationRun['Id']
}

function Write-TcRemediationAlert {
    <#
    .SYNOPSIS
    Writes a point to look at. The run then ends with code 1.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text
    )

    $script:TcRemediationRun['Alerts']++
    Write-TcRemediationLine -Status Warning -Text $Text -Step $script:TcRemediationRun['Id']
}

function Write-TcRemediationInstruction {
    <#
    .SYNOPSIS
    Shows what a person must do.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string[]]$Line
    )

    foreach ($text in $Line) { Write-TcMessage -Message "        > $text" -Level Warning }
}

function Export-TcRemediationReport {
    <#
    .SYNOPSIS
    Writes a CSV to exports\ in the run folder and returns its path. Excel never runs a cell of it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Position = 1)][AllowNull()][AllowEmptyCollection()][object[]]$Rows
    )

    $run = $script:TcRemediationRun
    $path = Join-Path (Join-Path $run['Folder'] 'exports') "$Name.csv"
    $lines = @($Rows | Where-Object { $null -ne $_ } | ForEach-Object {
            $source = if ($_ -is [System.Collections.IDictionary]) { $_ } else { $copy = [ordered]@{}; foreach ($property in $_.PSObject.Properties) { $copy[$property.Name] = $property.Value }; $copy }
            $line = [ordered]@{}
            foreach ($key in @($source.Keys)) { $line[$key] = ConvertTo-TcCsvCell $source[$key] }
            [pscustomobject]$line
        })
    if ($lines.Count) { $lines | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding utf8BOM }
    else { [System.IO.File]::WriteAllText($path, '', [System.Text.UTF8Encoding]::new($true)) }
    $run['Reports']++
    Write-TcRemediationLine -Status OK -Text ('Report: {0} ({1} row(s))' -f $path, $lines.Count) -Step $run['Id']
    $path
}

function Close-TcRemediation {
    <#
    .SYNOPSIS
    Ends the run: writes summary.json and sets the code. 0 done, 1 points left open, 2 failed, 3 stopped at a confirmation.
    #>
    [CmdletBinding()]
    param()

    Close-TcRemediationBlock
    $run = $script:TcRemediationRun
    $tally = Get-TcRemediationTally
    $code = if ($tally['Failed'] -or $run['Blocking']) { 2 } elseif ($run['Stopped']) { 3 } elseif ($run['Alerts'] -or $run['Pending'] -or $tally['ForAPerson'] -or $tally['Waiting']) { 1 } else { 0 }
    $run['Code'] = $code

    Write-TcJsonFile -Path (Join-Path $run['Folder'] 'summary.json') -InputObject ([ordered]@{
            id = $run['Id']; title = $run['Entry']['title']; nature = $run['Entry']['nature']; mode = $(if ($run['Apply']) { 'Apply' } else { 'Preview' }); tenants = @($run['Tenants'])
            actions = $tally['Total']; applied = $tally['Applied']; alreadyInPlace = $tally['AlreadyInPlace']; failed = $tally['Failed']; forAPerson = $tally['ForAPerson']; waiting = $tally['Waiting']
            pendingDecisions = $run['Pending']; alerts = $run['Alerts']; blocking = $run['Blocking']; reports = $run['Reports']; code = $code; seconds = [math]::Round(((Get-Date) - $run['Started']).TotalSeconds, 1); folder = $run['Folder']
            testedOnRealTenant = $false
        })

    $line = if ($run['Apply']) { '{0} applied, {1} already in place, {2} failed' -f $tally['Applied'], $tally['AlreadyInPlace'], $tally['Failed'] } else { '{0} planned, none applied' -f $tally['Total'] }
    $label = @{ 0 = 'DONE'; 1 = 'DONE, POINTS LEFT OPEN'; 2 = 'FAILED'; 3 = 'STOPPED, NOTHING CHANGED' }[$code]
    Write-TcMessage -Message ('Result: {0}. Actions: {1}.' -f $label, $line) -Level $(if ($code -eq 0) { 'Success' } else { 'Warning' })
    Write-TcMessage -Message ('Decisions pending: {0}. For a person: {1}. Alerts: {2}.' -f $run['Pending'], $tally['ForAPerson'], $run['Alerts'])
    Write-TcLog -Message "End, code $code" -Level $(if ($code -eq 2) { 'ERROR' } else { 'OK' })
    Disconnect-TcRemediationService
}

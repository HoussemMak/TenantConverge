function Get-TcRemediationTable {
    <#
    .SYNOPSIS
    The rows of a table of a tenant, from the snapshot. A table that was not fully read raises an alert once.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant,
        [Parameter(Mandatory, Position = 1)][string]$Table
    )

    $run = $script:TcRemediationRun
    $dictionary = Get-TcTableDictionary
    if (-not $dictionary.Contains($Table)) { throw "Unknown table: $Table." }
    $state = Get-TcTableState -Snapshot $run['Snapshot'] -Role $Tenant -Table $Table
    if ($state.State -in 'NotCollected', 'NotFullyRead' -and -not $run['UnreadSaid'].ContainsKey("$Tenant|$Table")) {
        $run['UnreadSaid']["$Tenant|$Table"] = $true
        Write-TcRemediationAlert ('{0}: table {1} was not fully read ({2}). An empty result proves nothing here.' -f $Tenant, $Table, $state.Status)
    }
    @(Get-TcProperty (Get-TcProperty (Get-TcProperty $run['Snapshot']['tenants'] $Tenant) 'tables') $Table @() | Where-Object { $null -ne $_ })
}

function Get-TcRemediationValue {
    <#
    .SYNOPSIS
    A value from a Setting and Value table such as securitySettings or exchangeSettings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant,
        [Parameter(Mandatory, Position = 1)][string]$Table,
        [Parameter(Mandatory, Position = 2)][string]$Parameter,
        [Parameter(Position = 3)]$Default = $null
    )

    $row = Get-TcRemediationTable -Tenant $Tenant -Table $Table | Where-Object { $_['Setting'] -eq $Parameter } | Select-Object -First 1
    if ($row) { return $row['Value'] }
    $Default
}

function Test-TcCollectionComplete {
    <#
    .SYNOPSIS
    False when the collector of a table did not finish: an empty table then proves nothing.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant,
        [Parameter(Mandatory, Position = 1)][string]$Table
    )

    (Get-TcTableState -Snapshot $script:TcRemediationRun['Snapshot'] -Role $Tenant -Table $Table).State -in 'Collected', 'NotUsed'
}

function Get-TcRemediationPlanAction {
    <#
    .SYNOPSIS
    The actions of the plan for a procedure, with their items.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Procedure,
        [string]$Tenant
    )

    @(Get-TcProperty $script:TcRemediationRun['PlanData'] 'actions' @()) |
        Where-Object { ($_['procedure'] -eq $Procedure -or $_['ruleId'] -eq $Procedure) -and (-not $Tenant -or $_['role'] -eq $Tenant -or $_['role'] -eq 'All') } |
        ForEach-Object {
            $copy = [ordered]@{}
            foreach ($key in @($_.Keys)) { $copy[$key] = $_[$key] }
            $copy['tenant'] = $_['role']
            $copy
        }
}

function Get-TcRemediationPlanBlocker {
    <#
    .SYNOPSIS
    The blocking actions of the plan for a tenant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant
    )

    @(Get-TcProperty $script:TcRemediationRun['PlanData'] 'actions' @()) | Where-Object { $_['blocking'] -and ($_['role'] -eq $Tenant -or $_['role'] -eq 'All') }
}

function Get-TcRemediationPlanRole {
    <#
    .SYNOPSIS
    The tenants the plan names for some rules. All covers every tenant of the project.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][System.Collections.IDictionary]$Plan,
        [AllowEmptyCollection()][string[]]$RuleId = @(),
        [string[]]$Known
    )

    if (-not $Plan) { $Plan = $script:TcRemediationRun['PlanData']; $Known = $script:TcRemediationRun['Known'] }
    $roles = @(@(Get-TcProperty $Plan 'actions' @()) | Where-Object { $_['procedure'] -in $RuleId -or $_['ruleId'] -in $RuleId } | ForEach-Object { $_['role'] } | Select-Object -Unique)
    if ('All' -in $roles) { return $Known }
    @($Known | Where-Object { $_ -in $roles })
}

function Get-TcRemediationTenant {
    <#
    .SYNOPSIS
    What a remediation knows about a tenant: name, identifier, domains, and the accounts to keep.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant
    )

    $run = $script:TcRemediationRun
    $node = if ($Tenant -eq 'Target') { Get-TcProperty $run['Project'] 'target' } else { @(Get-TcProperty $run['Project'] 'sources' @()) | Where-Object { (Get-TcProperty $_ 'role') -eq $Tenant } | Select-Object -First 1 }
    if ($null -eq $node) { throw "Unknown tenant: $Tenant." }
    $snapshotNode = Get-TcProperty $run['Snapshot']['tenants'] $Tenant
    $domains = @(Get-TcProperty (Get-TcProperty $snapshotNode 'tables') 'domains' @())
    $initial = $domains | Where-Object { Test-TcTrue (Get-TcProperty $_ 'Initial') } | Select-Object -First 1
    $custom = @($domains | Where-Object { [string](Get-TcProperty $_ 'Domain') -notmatch '\.onmicrosoft\.com$' } | ForEach-Object { [string](Get-TcProperty $_ 'Domain') })
    $primary = [string](Get-TcProperty $node 'primaryDomain')
    if (-not $custom.Count -and $primary) { $custom = @($primary) }
    @{
        Code = $Tenant; Name = [string](Get-TcProperty $node 'displayName' $Tenant); TenantId = Get-TcProperty $node 'tenantId' (Get-TcProperty $snapshotNode 'tenantId'); PrimaryDomain = $primary
        InitialDomain = [string](Get-TcProperty $initial 'Domain' $primary); Domains = $custom; Prefix = $Tenant.ToLowerInvariant()
        KeptAccounts = @(Get-TcProperty (Get-TcRemediationOption 'KeptAccounts') $Tenant @())
    }
}

function Get-TcRemediationIdentity {
    <#
    .SYNOPSIS
    The draft identity matrix of a source, as the plan computes it, or the validated one when it exists.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant
    )

    $matrix = Import-TcSourceMatrix -Source $Tenant
    $rows = @($matrix['Rows'])
    $synced = @{}
    foreach ($user in @(Get-TcProperty (Get-TcProperty (Get-TcProperty $script:TcRemediationRun['Snapshot']['tenants'] 'Target') 'tables') 'users' @())) {
        if (Test-TcTrue (Get-TcProperty $user 'Synced')) { $synced[([string](Get-TcProperty $user 'UPN')).ToLowerInvariant()] = $true }
    }
    foreach ($row in $rows) { $row['Synced'] = $synced.ContainsKey(([string](Get-TcProperty $row 'Target UPN')).ToLowerInvariant()) }
    @{ Rows = $rows; State = $matrix['State']; Bookings = @($rows | Where-Object { [string](Get-TcProperty $_ 'Notes') -match 'Bookings' }).Count }
}

function Import-TcSourceMatrix {
    <#
    .SYNOPSIS
    The validated matrix of a source if it exists, in <output>\decisions\identity-matrix-<role>.csv, or the draft.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Source
    )

    $run = $script:TcRemediationRun
    $file = Read-TcDecisionFile -Name "identity-matrix-$Source"
    if ($file['State'] -eq 'Read') {
        foreach ($number in @($file['Refused'])) { Write-TcRemediationAlert ('{0}, row {1}: a cell starts with a formula sign. The row is not used.' -f $file['Path'], $number) }
        $rows = @($file['Rows'] | ForEach-Object { $copy = [ordered]@{}; foreach ($property in $_.PSObject.Properties) { $copy[$property.Name] = $property.Value }; $copy })
        return @{ State = 'Validated'; Rows = $rows }
    }
    if ($Source -notin $run['Sources'] -or -not $run['Snapshot']['tenants'].Contains($Source)) { return @{ State = 'Missing'; Rows = @() } }
    @{ State = 'Draft'; Rows = @(ConvertTo-TcIdentityMatrix -Snapshot $run['Snapshot'] -SourceRole $Source) }
}

function Find-TcMatrixRow {
    <#
    .SYNOPSIS
    The row of an account in the matrix of a source.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant,
        [Parameter(Mandatory, Position = 1)][AllowEmptyString()][string]$Account
    )

    (Get-TcRemediationIdentity -Tenant $Tenant)['Rows'] | Where-Object { $_['Source UPN'] -eq $Account } | Select-Object -First 1
}

function ConvertTo-TcBoolean {
    <#
    .SYNOPSIS
    One way to read a value that may be a boolean or a text.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowNull()]$Value
    )

    if ($Value -is [bool]) { return $Value }
    ([string]$Value).Trim() -in 'Yes', 'True', 'true', 'yes', '1', 'Enabled', 'enabled', 'Active', 'active', 'On'
}

function Copy-TcObject {
    <#
    .SYNOPSIS
    A full copy of an object, as dictionaries and arrays.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$InputObject
    )

    ConvertTo-TcHashtable -InputObject ($InputObject | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable -Depth 50)
}

function Get-TcRowIndex {
    <#
    .SYNOPSIS
    A dictionary of rows by one column, whatever the case.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Position = 0)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory, Position = 1)][string]$Key
    )

    $index = @{}
    foreach ($item in @($Rows)) {
        $value = ([string](Get-TcProperty $item $Key)).ToLowerInvariant()
        if ($value) { $index[$value] = $item }
    }
    $index
}

function Get-TcRandomPassword {
    <#
    .SYNOPSIS
    A random password with every character class. It never goes in a log.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Generates a secret.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [int]$Length = 20
    )

    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#$%&*+-=?@')
    $characters = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $sets) { $characters.Add($set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)]) }
    $all = -join $sets
    foreach ($i in 1..($Length - 4)) { $characters.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)]) }
    -join ($characters | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32(1000) })
}

function Get-TcRemediationLicense {
    <#
    .SYNOPSIS
    The license migrated accounts get, from the LicenseSku setting. A script that needs it stops without one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $sku = ([string](Get-TcRemediationOption 'LicenseSku')).Trim()
    if (-not $sku) { throw 'This script needs the license migrated accounts get: set LicenseSku in the remediation settings, with -Setting or in decisions\settings.json. Nothing was changed.' }
    $sku
}

function Save-TcRemediationSecret {
    <#
    .SYNOPSIS
    Saves a secret with DPAPI: only this Windows account on this computer can read it. Returns the file path.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The value comes from the service, and only exists as plain text at this point.')]
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    $folder = Join-Path $script:TcRemediationRun['Folder'] 'secrets'
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $path = Join-Path $folder "$Name.xml"
    ConvertTo-SecureString $Value -AsPlainText -Force | Export-Clixml -LiteralPath $path
    $path
}

function Test-TcPostponed {
    <#
    .SYNOPSIS
    In a -Test block: the action does not run, the run ends with code 1, and a rerun picks it up.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)]$Action,
        [Parameter(Mandatory, Position = 1)][string]$Reason
    )

    $run = $script:TcRemediationRun
    if (-not $run['Postponed'].ContainsKey($Reason)) {
        $run['Postponed'][$Reason] = $true
        Write-TcRemediationAlert ('Postponed: {0}' -f $Reason)
    }
    $Action['postponed'] = $true
    $Action['description'] = 'Postponed, {0}: {1}' -f $Reason, $Action['description']
    $true
}

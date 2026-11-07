function Get-TcDecisionFolder {
    <#
    .SYNOPSIS
    The folder of the decision files of the project: <output>\decisions.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $script:TcRemediationRun['DecisionFolder']
}

function Get-TcDecisionKey {
    <#
    .SYNOPSIS
    The key of a row: its key columns, trimmed and in lowercase.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]$Row,
        [Parameter(Mandatory, Position = 1)][string[]]$Key
    )

    @($Key | ForEach-Object { ([string](Get-TcProperty $Row $_)).Trim().ToLowerInvariant() }) -join '|'
}

function ConvertFrom-TcDecisionCell {
    <#
    .SYNOPSIS
    Reads one cell. Strips the apostrophe ConvertTo-TcCsvCell added, and returns $null for a raw formula.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Value
    )

    if ($Value -match "^'\s*[=+\-@\uFF1D\uFF0B\uFF0D\uFF20]") { return $Value.Substring(1) }
    # This module writes no such cell, so it came from somewhere else and shows what Excel made of it.
    if ((ConvertTo-TcCsvCell $Value) -cne $Value) { return $null }
    $Value
}

function Read-TcDecisionFile {
    <#
    .SYNOPSIS
    Reads a decisions file safely: comma, UTF-8, apostrophes stripped, a row with a formula set aside.

    .DESCRIPTION
    Returns Rows, the rows that can be used, Columns, and Refused, the numbers of the rows set aside. A
    missing or empty file returns no rows and says which of the two it was. A row is never repaired.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name
    )

    $path = Join-Path (Get-TcDecisionFolder) "$Name.csv"
    if (-not (Test-Path -LiteralPath $path)) { return @{ Path = $path; State = 'Missing'; Rows = @(); Columns = @(); Refused = @() } }
    $text = [System.IO.File]::ReadAllText($path)
    if (-not $text.Trim()) { return @{ Path = $path; State = 'Empty'; Rows = @(); Columns = @(); Refused = @() } }

    $raw = @($text | ConvertFrom-Csv)
    $columns = @(($text -split "`r?`n", 2)[0] | ConvertFrom-Csv -Header @(1..512 | ForEach-Object { "c$_" }) | ForEach-Object { $_.PSObject.Properties.Value } | Where-Object { $_ })
    $rows = [System.Collections.Generic.List[object]]::new()
    $refused = [System.Collections.Generic.List[int]]::new()
    $number = 1
    foreach ($row in $raw) {
        $number++
        $clean = [ordered]@{}
        $bad = $false
        foreach ($property in $row.PSObject.Properties) {
            $value = ConvertFrom-TcDecisionCell -Value ([string]$property.Value)
            if ($null -eq $value) { $bad = $true }
            $clean[$property.Name] = $value
        }
        if ($bad) { $refused.Add($number) } else { $rows.Add([pscustomobject]$clean) }
    }
    @{ Path = $path; State = 'Read'; Rows = $rows.ToArray(); Columns = $columns; Refused = $refused.ToArray() }
}

function Read-TcDecisionEntry {
    <#
    .SYNOPSIS
    The rows of a decisions file, by key.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Key
    )

    $entries = @{}
    foreach ($row in @((Read-TcDecisionFile -Name $Name)['Rows'])) { $entries[(Get-TcDecisionKey $row $Key)] = $row }
    $entries
}

function Get-TcUndecidedRow {
    <#
    .SYNOPSIS
    Guards a script that depends on the decisions of another: the keys with no valid decision.

    .DESCRIPTION
    Counts an expected row missing from the file, and any row empty or outside the allowed values. It
    never rewrites the file. -Tenant limits what it reads of the file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string[]]$Key,
        [Parameter(Mandatory)][string[]]$Choice,
        [AllowEmptyCollection()][object[]]$Expected = @(),
        [string]$Tenant
    )

    $entries = Read-TcDecisionEntry -Name $Name -Key $Key
    $open = [System.Collections.Generic.List[string]]::new()
    foreach ($row in @($Expected | Where-Object { $_ })) {
        $rowKey = Get-TcDecisionKey $row $Key
        if (-not $entries.ContainsKey($rowKey) -or [string](Get-TcProperty $entries[$rowKey] 'Decision') -cnotin $Choice) { $open.Add($rowKey) }
    }
    foreach ($rowKey in @($entries.Keys)) {
        if ($Tenant -and [string](Get-TcProperty $entries[$rowKey] 'Tenant') -ne $Tenant) { continue }
        if ([string](Get-TcProperty $entries[$rowKey] 'Decision') -cnotin $Choice -and $rowKey -notin $open) { $open.Add($rowKey) }
    }
    @($open)
}

function Test-TcSameDecisionCell {
    <#
    .SYNOPSIS
    True when two cells hold the same value, once Excel had its way: a number or a date it wrote its own way is the same.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][AllowEmptyString()][string]$Old,
        [AllowNull()][AllowEmptyString()][string]$New
    )

    if ($Old -ceq $New) { return $true }
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $oldNumber = 0.0; $newNumber = 0.0
    if ([double]::TryParse($Old, [System.Globalization.NumberStyles]::Float, $culture, [ref]$oldNumber) -and [double]::TryParse($New, [System.Globalization.NumberStyles]::Float, $culture, [ref]$newNumber)) { return $oldNumber -eq $newNumber }
    foreach ($reader in $culture, [System.Globalization.CultureInfo]::CurrentCulture) {
        $oldDate = [datetime]::MinValue; $newDate = [datetime]::MinValue
        if ([datetime]::TryParse($Old, $reader, [System.Globalization.DateTimeStyles]::None, [ref]$oldDate) -and [datetime]::TryParse($New, $reader, [System.Globalization.DateTimeStyles]::None, [ref]$newDate)) { return $oldDate -eq $newDate }
    }
    $false
}

function Get-TcDecisionChange {
    <#
    .SYNOPSIS
    What changed in a row since it was decided, one text per column, for each column both rows have.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Old,
        [Parameter(Mandatory)][System.Collections.IDictionary]$New,
        [Parameter(Mandatory)][string[]]$Ignore
    )

    foreach ($name in @($New.Keys | Where-Object { $_ -notin $Ignore })) {
        $column = $Old.PSObject.Properties[$name]
        if (-not $column) { continue }
        # The new value goes through what the file does to a cell, so a formula sign is no change.
        $after = [string](ConvertFrom-TcDecisionCell -Value (ConvertTo-TcCsvCell ([string]$New[$name])))
        if (-not (Test-TcSameDecisionCell -Old ([string]$column.Value) -New $after)) { '{0} was "{1}", now "{2}"' -f $name, $column.Value, $after }
    }
}

function Get-TcDecision {
    <#
    .SYNOPSIS
    Returns the rows a person decided for this run, and keeps the proposals file up to date.

    .DESCRIPTION
    A script asks nothing while it runs. What a person must settle lives in <output>\decisions\<Name>.csv,
    which opens in Excel. The first run writes the proposals, later runs add new rows and never touch what
    was decided. A row with no decision is never applied. A decided row that the tenant no longer proposes
    stays in the file as a trace, and is never applied either.

    A decision is taken on what the row said. When a column other than the key, the Decision columns or
    Allowed values changes, the row goes back to pending, with an alert that says what changed. Its Note stays.

    A row acts only when its key matches a proposal of this run, so a damaged key acts on nothing. A file
    with an unknown column, or without the key and Decision columns, stops the script and stays as it is.

    .PARAMETER Name
    The file, without extension: the identifier of the remediation, with a suffix for a second file.

    .PARAMETER Proposal
    The rows proposed, as dictionaries. A Proposal column gives the suggested value.

    .PARAMETER Key
    The columns that identify a row.

    .PARAMETER Choice
    The values allowed in the Decision column. They are compared exactly, case included.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][AllowEmptyCollection()][object[]]$Proposal = @(),
        [Parameter(Mandatory)][string[]]$Key,
        [Parameter(Mandatory)][string[]]$Choice
    )

    $run = $script:TcRemediationRun
    $folder = Get-TcDecisionFolder
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $file = Read-TcDecisionFile -Name $Name
    $path = $file['Path']

    $fixed = 'Proposal', 'Allowed values', 'Decision', 'Decision maker', 'Date', 'Note'
    $expected = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $Key) { $expected.Add($name) }
    foreach ($row in @($Proposal | Where-Object { $_ })) { foreach ($name in @($row.Keys)) { if ($name -notin $expected) { $expected.Add($name) } } }
    foreach ($name in $fixed) { if ($name -notin $expected) { $expected.Add($name) } }

    if ($file['State'] -eq 'Read') {
        $unknown = @($file['Columns'] | Where-Object { $_ -notin $expected })
        $missing = @(@($Key) + 'Decision' | Where-Object { $_ -notin $file['Columns'] })
        if ($unknown.Count -or $missing.Count) {
            throw ('{0} cannot be read: {1}{2}. Nothing was changed. Fix the columns, or delete the file to start again.' -f $path, $(if ($unknown.Count) { "unknown column(s): $($unknown -join ', ')" } else { '' }), $(if ($missing.Count) { " missing column(s): $($missing -join ', ')" } else { '' }))
        }
        foreach ($number in @($file['Refused'])) { Write-TcRemediationAlert ('{0}, row {1}: a cell starts with a formula sign. The row is not used.' -f $path, $number) }
    }

    $existing = @{}
    foreach ($row in @($file['Rows'])) {
        $rowKey = Get-TcDecisionKey $row $Key
        if ($existing.ContainsKey($rowKey)) { Write-TcRemediationAlert ('{0}: the row {1} appears twice, the last one counts.' -f $path, $rowKey) }
        $existing[$rowKey] = $row
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $seen = @{}
    foreach ($item in @($Proposal | Where-Object { $_ })) {
        $line = [ordered]@{}
        foreach ($name in @($item.Keys)) { $line[$name] = $item[$name] }
        if (-not $line.Contains('Proposal')) { $line['Proposal'] = '' }
        $rowKey = Get-TcDecisionKey $line $Key
        if ($seen.ContainsKey($rowKey)) { continue }
        $seen[$rowKey] = $true
        $old = if ($existing.ContainsKey($rowKey)) { $existing[$rowKey] } else { $null }
        $line['Allowed values'] = $Choice -join ', '
        $changes = @(if ([string](Get-TcProperty $old 'Decision' '')) { Get-TcDecisionChange -Old $old -New $line -Ignore (@($Key) + @('Allowed values', 'Decision', 'Decision maker', 'Date', 'Note')) })
        foreach ($name in 'Decision', 'Decision maker', 'Date', 'Note') { $line[$name] = [string](Get-TcProperty $old $name '') }
        if ($changes.Count) {
            foreach ($name in 'Decision', 'Decision maker', 'Date') { $line[$name] = '' }
            Write-TcRemediationAlert ('{0}: the row {1} changed since its decision, which goes back to pending: {2}.' -f $path, $rowKey, ($changes -join '; '))
        }
        $rows.Add([pscustomobject]$line)
    }

    # A decided row stays as a trace. A row of a tenant outside this run stays too.
    foreach ($rowKey in @($existing.Keys)) {
        if ($seen.ContainsKey($rowKey)) { continue }
        $old = $existing[$rowKey]
        $otherTenant = [bool]$old.PSObject.Properties['Tenant'] -and [string]$old.Tenant -notin $run['Tenants']
        if ([string](Get-TcProperty $old 'Decision') -or $otherTenant) { $rows.Add($old) }
    }

    if ($rows.Count) { Write-TcDecisionFile -Path $path -Row $rows.ToArray() -Column $expected.ToArray() }

    $decided = @($rows | Where-Object { $seen.ContainsKey((Get-TcDecisionKey $_ $Key)) -and [string]$_.Decision })
    $valid = @($decided | Where-Object { [string]$_.Decision -cin $Choice })
    $invalid = @($decided | Where-Object { [string]$_.Decision -cnotin $Choice })
    $waiting = @($rows | Where-Object { $seen.ContainsKey((Get-TcDecisionKey $_ $Key)) -and -not [string]$_.Decision }).Count
    foreach ($row in $invalid) { Write-TcRemediationAlert ('Decision not recognized "{0}" in {1}.csv. Allowed values: {2}.' -f $row.Decision, $Name, ($Choice -join ', ')) }
    $run['Pending'] += $waiting + $invalid.Count

    switch ($file['State']) {
        'Missing' { Write-TcRemediationLine -Status Manual -Text ('No decisions file yet: nothing will be applied. {0} proposal(s) written to {1}.' -f $rows.Count, $path) -Step $run['Id'] }
        'Empty' { Write-TcRemediationLine -Status Manual -Text ('The decisions file was empty: nothing will be applied. {0} proposal(s) written to {1}.' -f $rows.Count, $path) -Step $run['Id'] }
        default {
            if ($rows.Count) { Write-TcRemediationLine -Status $(if ($waiting) { 'Manual' } else { 'OK' }) -Text ('Decisions: {0} row(s) decided, {1} pending, {2}' -f $valid.Count, $waiting, $path) -Step $run['Id'] }
        }
    }
    $valid
}

function Write-TcDecisionFile {
    <#
    .SYNOPSIS
    Writes a decisions file: comma, UTF-8 with a BOM, every cell safe for Excel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Row,
        [Parameter(Mandatory)][string[]]$Column
    )

    $lines = foreach ($item in $Row) {
        $line = [ordered]@{}
        foreach ($name in $Column) { $line[$name] = ConvertTo-TcCsvCell ([string](Get-TcProperty $item $name '')) }
        [pscustomobject]$line
    }
    @($lines) | Export-Csv -LiteralPath $Path -NoTypeInformation -Encoding utf8BOM
}

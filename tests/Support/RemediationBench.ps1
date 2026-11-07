<#
    The bench of the remediation scripts: runs each of them on a fictional project, on offline stubs.
    Nothing here reaches a tenant or the network. RemediationStubs.ps1 must be loaded first.
#>

$script:TcBenchCodeError = 'cannot be found on this object|is not recognized|Cannot bind|Cannot index|The variable .* cannot be retrieved|Unable to index|null-valued|Method invocation failed|Cannot convert|Index was outside|parameter set|Argument types do not match|does not contain a method|Unexpected token|Cannot process argument'

function New-TcBenchProject {
    <# A project that matches a fictional snapshot. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot, [Parameter(Mandatory)][string]$Output)
    $target = $Snapshot['tenants']['Target']
    $sources = foreach ($role in @($Snapshot['tenants'].Keys | Where-Object { $_ -ne 'Target' })) {
        [pscustomobject]@{
            role = $role; displayName = $Snapshot['tenants'][$role]['displayName']; primaryDomain = $Snapshot['tenants'][$role]['primaryDomain']
            tenantId = $Snapshot['tenants'][$role]['tenantId']; state = 'Production'; wave = 1
        }
    }
    [pscustomobject]@{
        schemaVersion = 1; name = 'Bench'
        target = [pscustomobject]@{ displayName = $target['displayName']; primaryDomain = $target['primaryDomain']; tenantId = $target['tenantId']; state = 'Production' }
        sources = @($sources); access = [pscustomobject]@{ mode = 'Browser' }; output = [pscustomobject]@{ path = $Output }
    }
}

function Set-TcBenchLicense {
    <# Names, in the settings of the project, the most used license of the target. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot, [Parameter(Mandatory)][string]$Output)
    $top = @($Snapshot['tenants']['Target']['tables']['licenses'] | Sort-Object { [int]$_['Consumed'] } -Descending)[0]
    $folder = Join-Path $Output 'decisions'
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    @{ LicenseSku = [string]$top['SKU'] } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $folder 'settings.json') -Encoding utf8
}

function Set-TcBenchDecision {
    <# Fills the rows a person leaves open in every decisions file: the proposal when allowed, or the Nth allowed value. #>
    param([Parameter(Mandatory)][string]$Output, [int]$Choice = 0)
    $folder = Join-Path $Output 'decisions'
    if (-not (Test-Path -LiteralPath $folder)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $folder -Filter '*.csv') {
        $rows = @(Import-Csv -LiteralPath $file.FullName -Encoding utf8BOM)
        if (-not $rows.Count -or $rows[0].PSObject.Properties.Name -notcontains 'Decision') { continue }
        foreach ($row in $rows) {
            if ($row.Decision) { continue }
            $names = @($row.PSObject.Properties.Name)
            $allowed = if ($names -contains 'Allowed values') { @(([string]$row.'Allowed values') -split ', ' | Where-Object { $_ }) } else { @() }
            $proposal = if ($names -contains 'Proposal') { [string]$row.Proposal } else { '' }
            $row.Decision = if ($Choice -eq 0 -and $proposal -in $allowed) { $proposal } elseif ($allowed.Count) { $allowed[[Math]::Min($Choice, $allowed.Count - 1)] } else { $proposal }
            if ($names -contains 'Decision maker') { $row.'Decision maker' = 'Bench' }
            if ($names -contains 'Date') { $row.Date = '2030-01-01' }
        }
        $rows | Export-Csv -LiteralPath $file.FullName -NoTypeInformation -Encoding utf8BOM
    }
}

function Get-TcBenchFailure {
    <# What a run shows of a defect in the code: an error text, or an action that failed on a code error. #>
    param([Parameter(Mandatory)]$Outcome)
    $found = [System.Collections.Generic.List[string]]::new()
    $journal = Join-Path $Outcome.Folder 'journal.log'
    if (Test-Path -LiteralPath $journal) {
        foreach ($line in Get-Content -LiteralPath $journal -Encoding utf8) {
            if ($line -cmatch $script:TcBenchCodeError -or $line -match 'Unreadable plan item|\[ERROR\] Stopped:') { $found.Add($line) }
        }
    }
    $operations = Join-Path $Outcome.Folder 'operations.jsonl'
    if (Test-Path -LiteralPath $operations) {
        foreach ($line in Get-Content -LiteralPath $operations -Encoding utf8) {
            if ($line -cmatch $script:TcBenchCodeError) { $found.Add($line) }
        }
    }
    @($found | Select-Object -Unique)
}

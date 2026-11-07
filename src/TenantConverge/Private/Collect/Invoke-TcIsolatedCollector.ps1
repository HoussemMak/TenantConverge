function Invoke-TcIsolatedCollector {
    <#
    .SYNOPSIS
    Runs collectors in a separate process and merges their tables. Returns how many were not collected.

    .DESCRIPTION
    PnP.PowerShell and the Graph and Exchange modules cannot share a process: PowerShell stops abruptly.
    So the PnP collectors of a tenant run together in their own process, and if it stops, only they are
    missing. The process needs the initial domain, which only Graph can read, so it is found here first.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][hashtable[]]$Collector,
        [Parameter(Mandatory)][string]$Role,
        [int[]]$Rank = @(),
        [int]$Total = 0,
        [AllowEmptyString()][string]$Folder = ''
    )

    $output = Join-Path ([System.IO.Path]::GetTempPath()) ('tc-isolated-{0}.json' -f [guid]::NewGuid())
    $ids = ($Collector | ForEach-Object { $_['Id'] }) -join ','

    $tenant = $script:TcTenants[$Role]
    if (-not (Get-TcProperty $tenant 'initialDomain')) {
        try { Connect-TcTenant -Role $Role }
        catch { Write-TcLog -Message "The initial domain of $Role is unknown: $(Get-TcErrorText $_)" -Level WARN }
    }

    $script = Join-Path $PSScriptRoot '..' '..' 'Scripts' 'Invoke-TcIsolatedCollection.ps1'
    $arguments = @(
        '-NoProfile', '-File', $script, '-ProjectPath', $script:TcProjectPath, '-Role', $Role, '-CollectorId', $ids,
        '-Rank', ($Rank -join ','), '-Total', [string]$Total, '-Depth', $script:TcDepth, '-OutFile', $output
    )
    if ($Folder) { $arguments += @('-Folder', $Folder) }
    if ($script:TcUnattended) { $arguments += '-Unattended' }
    $initialDomain = Get-TcProperty $tenant 'initialDomain'
    if ($initialDomain) { $arguments += @('-InitialDomain', $initialDomain) }

    Write-TcLog -Message "Collectors $ids started in a separate process."
    $exitCode = Invoke-TcIsolatedProcess -Arguments $arguments
    if ($exitCode -ne 0) { Write-TcLog -Message "The separate process stopped with code $exitCode." -Level WARN }

    $result = $null
    if (Test-Path -LiteralPath $output) {
        try { $result = Read-TcJsonFile -Path $output }
        catch { Write-TcLog -Message 'The result of the separate process could not be read.' -Level WARN }
        Remove-Item -LiteralPath $output -Force -ErrorAction SilentlyContinue
    }

    if ($result) {
        $tables = Get-TcProperty $result 'tables'
        foreach ($key in @($tables.Keys)) {
            $rows = [System.Collections.Generic.List[object]]::new()
            foreach ($row in @($tables[$key])) { $rows.Add($row) }
            $script:TcCurrentTenant['tables'][$key] = $rows
        }
    }

    $missing = 0
    foreach ($item in $Collector) {
        $line = if ($result) { @(Get-TcProperty $result 'coverage') | Where-Object { (Get-TcProperty $_ 'id') -eq $item['Id'] } | Select-Object -First 1 }
        if (-not $line) {
            $line = [ordered]@{
                role     = $Role
                tenant   = $script:TcCurrentTenant['tenant']
                id       = $item['Id']
                workload = $item['Workload']
                title    = $item['Title']
                service  = (Get-TcServiceInfo $item['Service'])['Label']
                status   = 'Failed'
                message  = "The separate process of this workload stopped before the end (code $exitCode)."
                remedy   = "Run this workload alone: Invoke-TcAssessment -Workload '$($item['Workload'])'. The details are in journal.log."
                duration = 0
                rows     = 0
                tables   = @()
            }
            Write-TcStepLine -Status Warning -Text "$($item['Id']): not collected, the separate process stopped (code $exitCode)."
        }
        $script:TcCurrentTenant['coverage'].Add($line)
        if ((Get-TcProperty $line 'status') -notin 'OK', 'Partial') { $missing++ }
    }

    $missing
}

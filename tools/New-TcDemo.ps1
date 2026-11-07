<#
.SYNOPSIS
Writes the demonstration report and workbook from fictional tenants.

.DESCRIPTION
Builds a snapshot with New-TcFakeSnapshot.ps1, then runs New-TcReport and New-TcWorkbook on it. All the
data is invented, on reserved .example domains. It connects to nothing and does not start Excel. The
workbook needs the ImportExcel module.

Returns the paths of the two files.

.PARAMETER OutputPath
The folder to write to. The default is docs/demo in this repository.

.PARAMETER SourceCount
The number of fictional source tenants: 1, 2 or 3.

.PARAMETER Seed
The seed of the generator. The same seed gives the same tenants.

.EXAMPLE
./tools/New-TcDemo.ps1

Writes docs/demo/consolidation-report.html and docs/demo/consolidation-workbook.xlsx.

.EXAMPLE
./tools/New-TcDemo.ps1 -OutputPath ./demo -SourceCount 1

Writes the two files for one source tenant in another folder.
#>
[CmdletBinding()]
[OutputType([string])]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot '..' 'docs' 'demo'),
    [ValidateRange(1, 3)][int]$SourceCount = 3,
    [int]$Seed = 1
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$snapshot = & (Join-Path $PSScriptRoot 'New-TcFakeSnapshot.ps1') -SourceCount $SourceCount -Seed $Seed

$target = $snapshot['tenants']['Target']
$sources = foreach ($role in @($snapshot['tenants'].Keys | Where-Object { $_ -ne 'Target' })) {
    $tenant = $snapshot['tenants'][$role]
    [pscustomobject]@{ role = $role; displayName = $tenant['displayName']; primaryDomain = $tenant['primaryDomain']; tenantId = $tenant['tenantId']; wave = [int]$role.Substring(1) }
}
$project = [pscustomobject]@{
    schemaVersion = 1
    name          = "$($snapshot['meta']['project']) (fictional demonstration)"
    target        = [pscustomobject]@{ displayName = $target['displayName']; primaryDomain = $target['primaryDomain']; tenantId = $target['tenantId']; state = 'Production' }
    sources       = @($sources)
    access        = [pscustomobject]@{ mode = 'Browser' }
    output        = [pscustomobject]@{ path = './output' }
    team          = @('Pat Example', 'Sam Example')
}

# Written apart, so the tracking file and the copy of an older workbook stay out of the result.
$work = Join-Path ([IO.Path]::GetTempPath()) "tc-demo-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $report = New-TcReport -Project $project -Snapshot $snapshot -OutputPath $work -WarningAction SilentlyContinue
    $workbook = New-TcWorkbook -Project $project -Snapshot $snapshot -OutputPath $work

    $folder = New-Item -ItemType Directory -Force -Path $OutputPath
    foreach ($file in [string]$report.Path, [string]$workbook) {
        $copy = Join-Path $folder.FullName (Split-Path -Path $file -Leaf)
        Copy-Item -LiteralPath $file -Destination $copy -Force
        $copy
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force
}

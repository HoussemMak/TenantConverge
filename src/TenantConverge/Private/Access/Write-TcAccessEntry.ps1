function Write-TcAccessEntry {
    <#
    .SYNOPSIS
    Saves or forgets the application details of one tenant in the local access file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Role,
        [AllowNull()]$Entry
    )

    $tenants = [ordered]@{}
    $existing = Read-TcAccessFile -ProjectPath $ProjectPath
    foreach ($key in @($existing.Keys)) { $tenants[$key] = $existing[$key] }

    if ($null -eq $Entry) { $tenants.Remove($Role) } else { $tenants[$Role] = $Entry }

    Write-TcJsonFile -Path (Get-TcAccessPath -ProjectPath $ProjectPath) -InputObject ([ordered]@{ schemaVersion = 1; tenants = $tenants })
}

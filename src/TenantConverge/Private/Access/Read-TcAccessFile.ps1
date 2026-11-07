function Read-TcAccessFile {
    <#
    .SYNOPSIS
    Reads the application details of each tenant, by role. Returns an empty dictionary without a file.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$ProjectPath
    )

    $path = Get-TcAccessPath -ProjectPath $ProjectPath
    if (-not (Test-Path -LiteralPath $path)) { return [ordered]@{} }

    $tenants = Get-TcProperty (Read-TcJsonFile -Path $path) 'tenants'
    if ($null -eq $tenants) { return [ordered]@{} }
    $tenants
}

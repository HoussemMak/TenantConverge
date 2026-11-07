function Write-TcJsonFile {
    <#
    .SYNOPSIS
    Writes JSON to a temporary file, then moves it into place, so a stopped run never leaves half a file.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowNull()]$InputObject
    )

    # .NET resolves a relative path against the folder of the process, not the PowerShell location.
    $fullPath = Resolve-TcPath -Path $Path
    $temporary = "$fullPath.tmp"
    $json = ConvertTo-Json -InputObject $InputObject -Depth 50
    [System.IO.File]::WriteAllText($temporary, $json, [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $fullPath -Force
}

function Write-TcProjectFile {
    <#
    .SYNOPSIS
    Writes a project file in UTF-8 without a byte order mark.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Project,
        [Parameter(Mandatory)][string]$Path
    )

    $fullPath = Resolve-TcPath -Path $Path
    $folder = [IO.Path]::GetDirectoryName($fullPath)
    if ($folder) { [void][IO.Directory]::CreateDirectory($folder) }

    # ConvertTo-Json ends its lines the way the system does.
    $json = ($Project | ConvertTo-Json -Depth 10) -replace "`r`n", "`n"
    [IO.File]::WriteAllText($fullPath, $json + "`n", [Text.UTF8Encoding]::new($false))
}

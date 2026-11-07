function Get-TcAccessPath {
    <#
    .SYNOPSIS
    Returns the local access file of a project: project.json gives project.access.local.json.

    .DESCRIPTION
    Application IDs and certificate thumbprints stay in that file, next to the project, and git
    ignores it. They never go into project.json.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$ProjectPath
    )

    $folder = Split-Path -Path $ProjectPath -Parent
    $name = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    $file = "$name.access.local.json"
    if ($folder) { Join-Path $folder $file } else { $file }
}

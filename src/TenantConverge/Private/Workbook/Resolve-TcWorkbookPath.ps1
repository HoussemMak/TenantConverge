function Resolve-TcWorkbookPath {
    <#
    .SYNOPSIS
    Returns the full path of the workbook: the file given, a file in the folder given, or the output folder of the project.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object]$Project,
        [Parameter(Mandatory)][object]$ProjectData,
        [string]$OutputPath
    )

    $fileName = 'consolidation-workbook.xlsx'
    if ($OutputPath) {
        $resolved = Resolve-TcPath -Path $OutputPath
        if ((Test-Path -LiteralPath $resolved -PathType Container) -or -not [System.IO.Path]::HasExtension($resolved)) { return Join-Path $resolved $fileName }
        return $resolved
    }

    $root = [string](Get-TcProperty (Get-TcProperty $ProjectData 'output') 'path')
    if (-not [System.IO.Path]::IsPathRooted($root)) {
        $base = if ($Project -is [string]) { Split-Path -Path (Resolve-TcPath -Path $Project) -Parent } else { Resolve-TcPath -Path '.' }
        $root = Join-Path $base $root
    }
    Join-Path ([System.IO.Path]::GetFullPath($root)) $fileName
}

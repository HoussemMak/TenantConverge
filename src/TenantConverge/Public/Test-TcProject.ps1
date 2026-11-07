function Test-TcProject {
    <#
    .SYNOPSIS
    Checks a TenantConverge project file.

    .DESCRIPTION
    Returns True when the file is valid and False otherwise. With -Detailed, it returns one record per
    problem, with Code, Path and Message, and returns nothing for a valid file.

    .PARAMETER Path
    The project file to check.

    .PARAMETER Detailed
    Returns the problems instead of True or False.

    .EXAMPLE
    Test-TcProject -Path ./project.json -Detailed
    #>
    [CmdletBinding()]
    [OutputType([bool], [pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Detailed
    )

    $problems = @((Import-TcProjectJson -Path $Path).Errors)
    if ($Detailed) { return $problems }
    $problems.Count -eq 0
}

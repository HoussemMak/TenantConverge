function Read-TcProjectFile {
    <#
    .SYNOPSIS
    Reads a project file and stops with the validation codes when it is not valid.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $result = Import-TcProjectJson -Path $Path
    Assert-TcNoProjectProblem -Problem $result.Errors
    $result.Project
}

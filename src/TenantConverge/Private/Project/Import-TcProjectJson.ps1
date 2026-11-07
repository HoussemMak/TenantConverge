function Import-TcProjectJson {
    <#
    .SYNOPSIS
    Loads a project file and returns the project with its validation problems.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $fullPath = Resolve-TcPath -Path $Path
    if (-not [IO.File]::Exists($fullPath)) {
        return [pscustomobject]@{
            Project = $null
            Errors  = @([pscustomobject]@{ Code = 'TC1015'; Path = $Path; Message = "Project file not found: $Path" })
        }
    }

    $project = $null
    try {
        $project = [IO.File]::ReadAllText($fullPath) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $project = $null
    }

    if ($null -eq $project) {
        return [pscustomobject]@{
            Project = $null
            Errors  = @([pscustomobject]@{ Code = 'TC1014'; Path = $Path; Message = "'$Path' is not valid JSON." })
        }
    }

    [pscustomobject]@{
        Project = $project
        Errors  = @(Test-TcProjectDefinition -Project $project)
    }
}

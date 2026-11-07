function Assert-TcNoProjectProblem {
    <#
    .SYNOPSIS
    Stops with one line per problem of a project, each starting with its code. Does nothing without a problem.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$Problem
    )

    $lines = @($Problem | Where-Object { $_ } | ForEach-Object { "$($_.Code): $($_.Message)" })
    if ($lines.Count -gt 0) { throw ($lines -join [Environment]::NewLine) }
}

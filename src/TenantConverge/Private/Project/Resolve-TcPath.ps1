function Resolve-TcPath {
    <#
    .SYNOPSIS
    Resolves a path, which may not exist yet, against the current PowerShell location.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

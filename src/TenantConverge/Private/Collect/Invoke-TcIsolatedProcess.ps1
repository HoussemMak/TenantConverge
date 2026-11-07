function Invoke-TcIsolatedProcess {
    <#
    .SYNOPSIS
    Starts a separate PowerShell process and returns its exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string[]]$Arguments
    )

    & (Get-Process -Id $PID).Path @Arguments | Out-Host
    $LASTEXITCODE
}

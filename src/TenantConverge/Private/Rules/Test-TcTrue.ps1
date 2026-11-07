function Test-TcTrue {
    <#
    .SYNOPSIS
    Reads a value as true, whether it came as a boolean or as text.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Position = 0)][AllowNull()]$Value
    )

    $Value -eq $true -or [string]$Value -match '^(?i)(true|1|yes)$'
}

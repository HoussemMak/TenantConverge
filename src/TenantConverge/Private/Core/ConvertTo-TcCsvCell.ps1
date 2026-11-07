function ConvertTo-TcCsvCell {
    <#
    .SYNOPSIS
    Makes a value safe for a CSV that Excel opens: text that would run as a formula gets a leading apostrophe.

    .DESCRIPTION
    Tenant values are written by people, so a display name can hold a formula. Excel runs a cell that
    starts with =, + , - or @, after spaces too, and their full-width forms. The apostrophe stays visible
    and the value stays readable. A plain number such as -1 or +15145550100 cannot run, and stays as it is.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Value
    )

    if ($Value -isnot [string]) { return $Value }
    if ($Value -match '^\s*[=+\-@\uFF1D\uFF0B\uFF0D\uFF20]' -and $Value -notmatch '^\s*[+-]?\d+([.,]\d+)?\s*$') { return "'$Value" }
    $Value
}

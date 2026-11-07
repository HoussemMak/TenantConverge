function Write-TcWorkbookValue {
    <#
    .SYNOPSIS
    Writes a value in a cell: a number stays a number, and anything else is text, and stays text.

    .DESCRIPTION
    This is the only way a value of a tenant reaches a sheet, and it has no way to make a formula. The
    cell is written as a string with the text format, so Excel runs nothing and changes nothing, even
    when a person presses Enter in the cell. Text that starts like a formula also gets the quote prefix,
    the file's own form of a leading apostrophe. It does not show in the cell.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][int]$Column,
        [AllowNull()]$Value
    )

    if ($null -eq $Value) { return }

    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) {
        $Sheet.SetValue($Row, $Column, [double]$Value)
        return
    }

    $text = if ($Value -is [bool]) { if ($Value) { 'Yes' } else { 'No' } } else { ConvertTo-TcWorkbookText $Value }
    if (-not $text) { return }

    $Sheet.SetValue($Row, $Column, $text)
    $style = $Sheet.Cells[$Row, $Column].Style
    $style.Numberformat.Format = '@'
    if ($text -match '^\s*[=+\-@\uFF1D\uFF0B\uFF0D\uFF20]') { $style.QuotePrefix = $true }
}

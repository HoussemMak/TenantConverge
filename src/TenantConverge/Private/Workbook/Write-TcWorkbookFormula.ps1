function Write-TcWorkbookFormula {
    <#
    .SYNOPSIS
    Writes a formula made by this module.

    .DESCRIPTION
    Only code of this module calls this, with text of its own and cell addresses. A value of a tenant
    never goes in a formula: a formula reads it from its cell. Compare it with =, not with COUNTIF, which
    reads a value such as >5 or Al* as a condition.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][int]$Row,
        [Parameter(Mandatory)][int]$Column,
        [Parameter(Mandatory)][string]$Formula,
        [string]$Format
    )

    $cell = $Sheet.Cells[$Row, $Column]
    $cell.Formula = $Formula
    if ($Format) { $cell.Style.Numberformat.Format = $Format }
}

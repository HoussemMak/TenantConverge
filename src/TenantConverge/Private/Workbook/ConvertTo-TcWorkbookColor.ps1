function ConvertTo-TcWorkbookColor {
    <#
    .SYNOPSIS
    Turns a color written as RRGGBB into what EPPlus wants.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Hex
    )

    [System.Drawing.ColorTranslator]::FromHtml("#$Hex")
}

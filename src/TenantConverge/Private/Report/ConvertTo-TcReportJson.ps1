function ConvertTo-TcReportJson {
    <#
    .SYNOPSIS
    Writes JSON that is safe inside an HTML script block.

    .DESCRIPTION
    Tenant values are written by people, so a name can hold </script> or <!--. Every <, >, & and ' leaves
    as a \u escape: HTML sees no markup, and JSON.parse gives the value back unchanged.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowNull()]$InputObject
    )

    ConvertTo-Json -InputObject $InputObject -Depth 50 -Compress -EscapeHandling EscapeHtml
}

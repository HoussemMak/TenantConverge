function Format-TcRuleText {
    <#
    .SYNOPSIS
    Fills the {name} placeholders of a catalog text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory, Position = 1)][System.Collections.IDictionary]$Values
    )

    foreach ($key in $Values.Keys) { $Text = $Text.Replace("{$key}", [string]$Values[$key]) }
    $Text
}

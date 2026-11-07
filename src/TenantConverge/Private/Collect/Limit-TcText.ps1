function Limit-TcText {
    <#
    .SYNOPSIS
    Shortens a text to a maximum length.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Position = 1)][int]$Maximum = 1500
    )

    if ($Text.Length -gt $Maximum) { return $Text.Substring(0, $Maximum) + [char]0x2026 }
    $Text
}

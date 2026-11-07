function ConvertTo-TcWorkbookText {
    <#
    .SYNOPSIS
    Makes any value safe as the text of a cell.

    .DESCRIPTION
    Tenant text is written by people, and a few characters break the file itself. Half of a surrogate pair
    stops the save, and the control characters are not valid XML. Excel holds 32,767 characters in a cell
    and asks to repair a file with more, so a longer text is cut, and it says so.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()]$Value
    )

    if ($null -eq $Value) { return '' }

    $limit = 32767
    $text = ([string]$Value) -replace "`r`n?", "`n"
    $text = $text -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F\uFFFE\uFFFF]', ''
    $text = $text -replace '[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]', [string][char]0xFFFD
    if ($text.Length -le $limit) { return $text }

    $note = " ... [cut: $($text.Length) characters in all]"
    $keep = $limit - $note.Length
    if ([char]::IsHighSurrogate($text[$keep - 1])) { $keep-- }
    $text.Substring(0, $keep) + $note
}

function ConvertTo-TcPersonKey {
    <#
    .SYNOPSIS
    Reduces a name to a key that matches one person across tenants.

    .DESCRIPTION
    No accents and no punctuation, and anything in parentheses goes. Punctuation becomes a space, so a
    hyphenated name stays two words. Display names of two words or more are what the rule compares.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Position = 0)][AllowNull()][string]$Name
    )

    # Normalize stops on half of a surrogate pair and on a non-character. Neither is a letter of a name.
    $text = (([string]$Name) -replace '[\p{Cs}\p{Cn}]', ' ').Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
    (($text -replace '\(.*?\)', ' ' -replace '[^A-Za-z ]', ' ' -replace '\s+', ' ').Trim().ToLowerInvariant())
}

function ConvertTo-TcMatchName {
    <#
    .SYNOPSIS
    Reduces a display name to the letters that identify a person: no accents, case or punctuation.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()][string]$Name,
        [AllowEmptyCollection()][string[]]$IgnoreSuffix = @()
    )

    # Normalize stops on half of a surrogate pair and on a non-character. Neither is a letter of a name.
    $text = (([string]$Name) -replace '[\p{Cs}\p{Cn}]', '').Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '' -replace '[^a-zA-Z ]', ''
    $text = $text.Trim()
    foreach ($suffix in $IgnoreSuffix) { $text = $text -replace "(?i)\s+$([regex]::Escape($suffix))$", '' }
    $text.Trim().ToLowerInvariant()
}
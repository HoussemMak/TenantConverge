function ConvertTo-TcSlug {
    <#
    .SYNOPSIS
    Turns a name into a short folder name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Value
    )

    # Normalize stops on half of a surrogate pair and on a non-character. Neither belongs in a folder name.
    $plain = ($Value -replace '[\p{Cs}\p{Cn}]', ' ').Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
    $slug = ($plain.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ($slug) { $slug } else { 'project' }
}

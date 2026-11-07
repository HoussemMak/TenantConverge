function Read-TcJsonFile {
    <#
    .SYNOPSIS
    Reads a JSON file into ordered dictionaries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable -Depth 50
}

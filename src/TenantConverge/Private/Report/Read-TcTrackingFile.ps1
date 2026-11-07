function Read-TcTrackingFile {
    <#
    .SYNOPSIS
    Reads the team tracking file. It is created when it does not exist, and never written after that.

    .DESCRIPTION
    The file is authoritative: the team and the report write to it, and a generation only reads it, so
    generating again loses nothing. It starts in English, with commas, as UTF-8 with a byte order mark for
    Excel. Excel can save it back with semicolons in an old code page, in some languages: both are read.
    Readable is false when the columns are gone: the report then shows that, and overwrites nothing.
    Locked is true when a program holds the file and shares it with nobody: Readable is then false too.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$Create
    )

    $header = 'Type,Id,Label,Field,Value,Author,Date,Replaces'
    if (-not (Test-Path -LiteralPath $Path)) {
        if ($Create) { [System.IO.File]::WriteAllText($Path, "$header`r`n", [System.Text.UTF8Encoding]::new($true)) }
        return [pscustomobject]@{ Text = ''; Rows = @(); Readable = $true; Created = [bool]$Create; Locked = $false }
    }

    try { $text = Read-TcSharedText -Path $Path }
    catch [System.IO.IOException] { return [pscustomobject]@{ Text = ''; Rows = @(); Readable = $false; Created = $false; Locked = $true } }
    if (-not $text.Trim()) { return [pscustomobject]@{ Text = ''; Rows = @(); Readable = $true; Created = $false; Locked = $false } }

    $first = ($text -split "`r?`n", 2)[0]
    $semicolons = ([regex]::Matches($first, ';')).Count
    $commas = ([regex]::Matches($first, ',')).Count
    $delimiter = if ($semicolons -gt $commas) { ';' } else { ',' }

    $columns = @($first -split $delimiter | ForEach-Object { $_.Trim('"') })
    $readable = 'Type' -in $columns -and 'Id' -in $columns -and 'Value' -in $columns
    $rows = if ($readable) { @($text | ConvertFrom-Csv -Delimiter $delimiter) } else { @() }

    [pscustomobject]@{ Text = $text; Rows = @($rows); Readable = $readable; Created = $false; Locked = $false }
}

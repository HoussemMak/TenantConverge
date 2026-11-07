function Export-TcTableCsv {
    <#
    .SYNOPSIS
    Writes one CSV per table and per tenant in the exports folder: commas, UTF-8 with a BOM for Excel.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Folder
    )

    $exports = Join-Path $Folder 'exports'
    New-Item -ItemType Directory -Force -Path $exports | Out-Null

    foreach ($role in @($script:TcCollection.Keys)) {
        $tables = $script:TcCollection[$role]['tables']
        foreach ($key in @($tables.Keys)) {
            $rows = @($tables[$key])
            if ($rows.Count -eq 0) { continue }

            $columns = [System.Collections.Generic.List[string]]::new()
            foreach ($row in $rows) {
                foreach ($column in @($row.Keys)) {
                    if (-not $columns.Contains([string]$column)) { $columns.Add([string]$column) }
                }
            }

            $rows | ForEach-Object {
                $row = $_
                $line = [ordered]@{}
                foreach ($column in $columns) { $line[$column] = ConvertTo-TcCsvCell (Get-TcProperty $row $column) }
                [pscustomobject]$line
            } | Export-Csv -LiteralPath (Join-Path $exports "$role.$key.csv") -NoTypeInformation -Encoding utf8BOM
        }
    }
}

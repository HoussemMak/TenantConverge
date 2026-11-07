function Add-TcWorkbookTable {
    <#
    .SYNOPSIS
    Writes rows under a header row and makes an Excel table of them.

    .DESCRIPTION
    A column is a dictionary: Name, Width, and optionally Input (for the team to fill in, kept and yellow),
    Keep (kept even when empty), Wrap, Center, Bold, Small, Clip. A column that no row fills is left out,
    so no tab shows an empty column for a source that does not exist. Clip stops a long text at the edge
    of its cell, for a list that would make a row 409 points high if it wrapped.

    A table with no row is a file Excel asks to repair, so with no row there is a sentence and no table.

    Returns what formulas need: the sheet, the rows, and the number of each column. With no row, the
    columns are all there and the range is one empty row, so a formula counts 0 and raises no error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Book,
        [Parameter(Mandatory)][object]$Sheet,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][object[]]$Column,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row,
        [Parameter(Mandatory)][string]$Empty,
        [int]$HeaderRow = 9
    )

    $theme = $Book['Theme']
    $hasRows = $Row.Count -gt 0
    $kept = @($Column | Where-Object {
            $key = $_['Name']
            if (-not $hasRows -or (Get-TcProperty $_ 'Input') -or (Get-TcProperty $_ 'Keep')) { return $true }
            foreach ($line in $Row) {
                $value = $line[$key]
                if ($null -ne $value -and "$value" -ne '') { return $true }
            }
            $false
        })

    $numbers = [ordered]@{}
    $index = 0
    foreach ($item in $kept) {
        $index++
        $numbers[$item['Name']] = $index
    }

    $first = $HeaderRow + 1
    $last = if ($hasRows) { $HeaderRow + $Row.Count } else { $first }
    $inputs = @($kept | Where-Object { Get-TcProperty $_ 'Input' } | ForEach-Object { $_['Name'] })
    $table = @{ Sheet = $Sheet; SheetName = $Sheet.Name; Name = $Name; HeaderRow = $HeaderRow; First = $first; Last = $last; Columns = $numbers; Inputs = $inputs; Count = $Row.Count; Rows = $Row }
    $Book['Tables'][$Name] = $table

    if (-not $hasRows) {
        Write-TcWorkbookValue -Sheet $Sheet -Row $HeaderRow -Column 1 -Value $Empty
        return $table
    }

    for ($c = 1; $c -le $kept.Count; $c++) {
        $item = $kept[$c - 1]
        Write-TcWorkbookValue -Sheet $Sheet -Row $HeaderRow -Column $c -Value $item['Name']
        $Sheet.Column($c).Width = $item['Width']
    }
    for ($r = 0; $r -lt $Row.Count; $r++) {
        $line = $Row[$r]
        for ($c = 1; $c -le $kept.Count; $c++) {
            $value = $line[$kept[$c - 1]['Name']]
            Write-TcWorkbookValue -Sheet $Sheet -Row ($first + $r) -Column $c -Value $value
            if ((Get-TcProperty $kept[$c - 1] 'Clip') -and ([string]$value).Length -gt $kept[$c - 1]['Width']) { $Sheet.Cells[($first + $r), $c].Style.HorizontalAlignment = 'Fill' }
        }
    }

    $body = $Sheet.Cells[$first, 1, $last, $kept.Count]
    $body.Style.Font.Size = 10
    $body.Style.Font.Color.SetColor((ConvertTo-TcWorkbookColor $theme['Ink']))
    $body.Style.VerticalAlignment = 'Top'

    for ($c = 1; $c -le $kept.Count; $c++) {
        $item = $kept[$c - 1]
        $cells = $Sheet.Cells[$first, $c, $last, $c]
        if (Get-TcProperty $item 'Wrap') { $cells.Style.WrapText = $true }
        if (Get-TcProperty $item 'Center') { $cells.Style.HorizontalAlignment = 'Center' }
        if (Get-TcProperty $item 'Bold') { $cells.Style.Font.Bold = $true }
        if (Get-TcProperty $item 'Small') { $cells.Style.Font.Size = 9 }
        if (Get-TcProperty $item 'Input') {
            $cells.Style.Fill.PatternType = 'Solid'
            $cells.Style.Fill.BackgroundColor.SetColor((ConvertTo-TcWorkbookColor $theme['Input']))
        }
    }

    $excelTable = $Sheet.Tables.Add($Sheet.Cells[$HeaderRow, 1, $last, $kept.Count], $Name)
    $excelTable.TableStyle = 'Light9'

    $header = $Sheet.Cells[$HeaderRow, 1, $HeaderRow, $kept.Count]
    $header.Style.WrapText = $true
    $header.Style.VerticalAlignment = 'Center'
    $Sheet.Row($HeaderRow).Height = 30

    $table
}

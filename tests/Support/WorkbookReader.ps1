# Reads a saved .xlsx straight from its zip and its XML, with nothing of the code that wrote it, so what a
# test sees is what is in the file: a text cell, a formula, a style, a validation.

Add-Type -AssemblyName System.IO.Compression.FileSystem

# A sheet holds tens of thousands of cells: this one loop is compiled, or the tests spend their time in it.
if (-not ('TcXlsxParser' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Collections.Specialized;
using System.IO;
using System.Text;
using System.Xml;

public class TcXlsxCell {
    public string Sheet, Address, Type, Formula, Value, Format;
    public int Row, Column;
    public bool Quote;
}

public static class TcXlsxParser {
    public static OrderedDictionary Parse(string xml, string sheet, string[] strings, bool[] quotes, string[] formats) {
        var cells = new OrderedDictionary();
        TcXlsxCell cell = null;
        StringBuilder text = null;
        string inside = null;
        using (var reader = XmlReader.Create(new StringReader(xml))) {
            while (reader.Read()) {
                if (reader.NodeType == XmlNodeType.Element) {
                    if (reader.LocalName == "c") {
                        var address = reader.GetAttribute("r");
                        int column = 0, row = 0;
                        foreach (var letter in address) {
                            if (char.IsDigit(letter)) { row = row * 10 + (letter - '0'); } else { column = column * 26 + letter - 64; }
                        }
                        var style = int.Parse(reader.GetAttribute("s") ?? "0");
                        cell = new TcXlsxCell { Sheet = sheet, Address = address, Row = row, Column = column, Type = reader.GetAttribute("t") ?? "", Quote = quotes[style], Format = formats[style] };
                        cells[address] = cell;
                        if (reader.IsEmptyElement) { cell = null; }
                    }
                    else if (cell != null && (reader.LocalName == "f" || reader.LocalName == "v") && !reader.IsEmptyElement) {
                        inside = reader.LocalName;
                        text = new StringBuilder();
                    }
                }
                else if (inside != null && (reader.NodeType == XmlNodeType.Text || reader.NodeType == XmlNodeType.SignificantWhitespace || reader.NodeType == XmlNodeType.Whitespace)) {
                    text.Append(reader.Value);
                }
                else if (reader.NodeType == XmlNodeType.EndElement) {
                    if (inside != null && reader.LocalName == inside) {
                        if (inside == "f") { cell.Formula = text.ToString(); }
                        else { cell.Value = cell.Type == "s" ? strings[int.Parse(text.ToString())] : text.ToString(); }
                        inside = null;
                    }
                    else if (reader.LocalName == "c") { cell = null; }
                }
            }
        }
        return cells;
    }
}
'@
}

function Get-TcXlsxText {
    <# Turns the _xHHHH_ escapes of the file format back into characters. #>
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    [regex]::Replace($Text, '_x([0-9A-Fa-f]{4})_', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
}

function Get-TcXlsxColumnNumber {
    param([string]$Address)
    $number = 0
    foreach ($letter in ($Address -replace '\d', '').ToCharArray()) { $number = $number * 26 + [int]$letter - 64 }
    $number
}

function Read-TcXlsx {
    <#
    .SYNOPSIS
    Reads a workbook file into plain dictionaries: Sheets, Tables, Names, Properties, Parts.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $main = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $relations = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    $parts = @{}
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -notmatch '\.(xml|rels|vml)$') { $parts[$entry.FullName] = $null; continue }
            $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
            try { $parts[$entry.FullName] = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
    }
    finally { $zip.Dispose() }

    $load = {
        param([string]$Part)
        $document = [System.Xml.XmlDocument]::new()
        $document.PreserveWhitespace = $true
        $document.LoadXml($parts[$Part])
        $manager = [System.Xml.XmlNamespaceManager]::new($document.NameTable)
        $manager.AddNamespace('m', $main)
        $manager.AddNamespace('r', $relations)
        $manager.AddNamespace('p', 'http://schemas.openxmlformats.org/package/2006/relationships')
        $manager.AddNamespace('c', 'http://schemas.openxmlformats.org/drawingml/2006/chart')
        @{ Document = $document; Manager = $manager }
    }

    # Every XML part must parse: a part that does not is a file Excel would refuse.
    foreach ($name in @($parts.Keys | Where-Object { $parts[$_] -and $_ -match '\.(xml|rels)$' })) { [void](& $load $name) }

    $strings = [System.Collections.Generic.List[string]]::new()
    if ($parts.ContainsKey('xl/sharedStrings.xml')) {
        $shared = & $load 'xl/sharedStrings.xml'
        foreach ($node in $shared.Document.SelectNodes('/m:sst/m:si', $shared.Manager)) { $strings.Add((Get-TcXlsxText $node.InnerText)) }
    }

    $styles = & $load 'xl/styles.xml'
    $formats = @{}
    foreach ($node in $styles.Document.SelectNodes('/m:styleSheet/m:numFmts/m:numFmt', $styles.Manager)) { $formats[$node.GetAttribute('numFmtId')] = $node.GetAttribute('formatCode') }
    $xfs = @($styles.Document.SelectNodes('/m:styleSheet/m:cellXfs/m:xf', $styles.Manager) | ForEach-Object {
            $id = $_.GetAttribute('numFmtId')
            @{ Quote = $_.GetAttribute('quotePrefix') -eq '1'; Format = if ($id -eq '49') { '@' } elseif ($formats.ContainsKey($id)) { $formats[$id] } else { $id } }
        })

    $book = & $load 'xl/workbook.xml'
    $links = & $load 'xl/_rels/workbook.xml.rels'
    $targets = @{}
    foreach ($node in $links.Document.SelectNodes('/p:Relationships/p:Relationship', $links.Manager)) { $targets[$node.GetAttribute('Id')] = $node.GetAttribute('Target') }

    $names = [ordered]@{}
    foreach ($node in $book.Document.SelectNodes('/m:workbook/m:definedNames/m:definedName', $book.Manager)) { $names[$node.GetAttribute('name')] = $node.InnerText }

    $sheets = [ordered]@{}
    $tables = [ordered]@{}
    foreach ($node in $book.Document.SelectNodes('/m:workbook/m:sheets/m:sheet', $book.Manager)) {
        $name = $node.GetAttribute('name')
        $target = $targets[$node.GetAttribute('id', $relations)] -replace '^/?xl/', ''
        $part = "xl/$target"
        $xml = & $load $part
        $manager = $xml.Manager

        $cells = [TcXlsxParser]::Parse($parts[$part], $name, [string[]]$strings.ToArray(), [bool[]]@($xfs | ForEach-Object { $_['Quote'] }), [string[]]@($xfs | ForEach-Object { $_['Format'] }))

        $validations = @($xml.Document.SelectNodes('/m:worksheet/m:dataValidations/m:dataValidation', $manager) | ForEach-Object {
                $source = $_.SelectSingleNode('m:formula1', $manager)
                [pscustomobject]@{ Type = $_.GetAttribute('type'); Range = $_.GetAttribute('sqref'); Formula = if ($source) { $source.InnerText } else { $null } }
            })
        $formats_ = @($xml.Document.SelectNodes('/m:worksheet/m:conditionalFormatting', $manager) | ForEach-Object {
                $range = $_.GetAttribute('sqref')
                foreach ($rule in $_.SelectNodes('m:cfRule', $manager)) {
                    $source = $rule.SelectSingleNode('m:formula', $manager)
                    [pscustomobject]@{ Range = $range; Type = $rule.GetAttribute('type'); Formula = if ($source) { $source.InnerText } else { $null } }
                }
            })
        $hidden = @($xml.Document.SelectNodes('/m:worksheet/m:cols/m:col[@hidden="1"]', $manager) | ForEach-Object { [int]$_.GetAttribute('min') })
        $hiddenRows = @($xml.Document.SelectNodes('/m:worksheet/m:sheetData/m:row[@hidden="1"]', $manager) | ForEach-Object { [int]$_.GetAttribute('r') })
        $linksOut = @($xml.Document.SelectNodes('/m:worksheet/m:hyperlinks/m:hyperlink', $manager) | ForEach-Object {
                [pscustomobject]@{ Cell = $_.GetAttribute('ref'); Location = $_.GetAttribute('location'); External = $_.GetAttribute('id', $relations) }
            })

        $charts = @()
        $sheetRels = 'xl/worksheets/_rels/{0}.rels' -f (Split-Path $target -Leaf)
        if ($parts.ContainsKey($sheetRels)) {
            $own = & $load $sheetRels
            foreach ($relation in $own.Document.SelectNodes('/p:Relationships/p:Relationship', $own.Manager)) {
                $relationTarget = $relation.GetAttribute('Target') -replace '^(\.\./|/xl/)', ''
                if ($relationTarget -match '^tables/') {
                    $table = & $load "xl/$relationTarget"
                    $root = $table.Document.DocumentElement
                    $tables[$root.GetAttribute('name')] = [pscustomobject]@{
                        Sheet = $name; Name = $root.GetAttribute('name'); Range = $root.GetAttribute('ref')
                        Columns = @($table.Document.SelectNodes('/m:table/m:tableColumns/m:tableColumn', $table.Manager) | ForEach-Object { $_.GetAttribute('name') })
                    }
                }
                if ($relationTarget -match '^drawings/') {
                    $drawingRels = 'xl/drawings/_rels/{0}.rels' -f (Split-Path $relationTarget -Leaf)
                    if ($parts.ContainsKey($drawingRels)) {
                        $drawn = & $load $drawingRels
                        $charts = @($drawn.Document.SelectNodes('/p:Relationships/p:Relationship', $drawn.Manager) | ForEach-Object { 'xl/' + ($_.GetAttribute('Target') -replace '^(\.\./|/xl/)', '') })
                    }
                }
            }
        }

        $sheets[$name] = [pscustomobject]@{
            Name = $name; Part = $part; Cells = $cells; Validations = $validations; Formats = $formats_; Charts = $charts
            HiddenColumns = $hidden; HiddenRows = $hiddenRows; Links = $linksOut; Xml = $parts[$part]
        }
    }

    $properties = @{}
    foreach ($part in 'docProps/core.xml', 'docProps/app.xml') {
        if (-not $parts.ContainsKey($part)) { continue }
        $document = & $load $part
        foreach ($node in $document.Document.DocumentElement.ChildNodes) { $properties[$node.LocalName] = $node.InnerText }
    }

    [pscustomobject]@{ Path = $Path; Sheets = $sheets; Tables = $tables; Names = $names; Properties = $properties; Parts = $parts; Workbook = $parts['xl/workbook.xml'] }
}

function Get-TcXlsxRow {
    <#
    .SYNOPSIS
    Returns the rows of a table of the workbook as dictionaries, by column name.
    #>
    param([Parameter(Mandatory)]$Book, [Parameter(Mandatory)][string]$Table)

    $definition = $Book.Tables[$Table]
    if (-not $definition) { throw "No table $Table." }
    $sheet = $Book.Sheets[$definition.Sheet]
    $start, $end = $definition.Range -split ':'
    $first = [int]($start -replace '\D', '')
    $last = [int]($end -replace '\D', '')
    $left = Get-TcXlsxColumnNumber $start

    $byRow = @{}
    foreach ($cell in $sheet.Cells.Values) {
        if ($cell.Row -le $first -or $cell.Row -gt $last) { continue }
        if (-not $byRow.ContainsKey($cell.Row)) { $byRow[$cell.Row] = @{} }
        $byRow[$cell.Row][$cell.Column] = $cell
    }
    for ($row = $first + 1; $row -le $last; $row++) {
        $line = [ordered]@{ '#Row' = $row }
        for ($i = 0; $i -lt $definition.Columns.Count; $i++) {
            $cell = if ($byRow.ContainsKey($row)) { $byRow[$row][$left + $i] }
            $line[$definition.Columns[$i]] = if ($cell) { $cell.Value } else { $null }
        }
        $line
    }
}

function Get-TcXlsxAllCell {
    <# Every cell of every sheet, with the name of its sheet. #>
    param([Parameter(Mandatory)]$Book)
    foreach ($sheet in $Book.Sheets.Values) { $sheet.Cells.Values }
}

function Get-TcXlsxColumnLetter {
    <# The letter of a column of a table, from the file. #>
    param([Parameter(Mandatory)]$Book, [Parameter(Mandatory)][string]$Table, [Parameter(Mandatory)][string]$Column)

    $definition = $Book.Tables[$Table]
    $start = ($definition.Range -split ':')[0]
    $number = (Get-TcXlsxColumnNumber $start) + [array]::IndexOf($definition.Columns, $Column)
    $letters = ''
    while ($number -gt 0) {
        $rest = ($number - 1) % 26
        $letters = [string][char](65 + $rest) + $letters
        $number = [math]::Floor(($number - 1) / 26)
    }
    $letters
}

function Invoke-TcXlsxRecalculation {
    <#
    .SYNOPSIS
    Opens a copy of a workbook, types values as a person would, recalculates, and returns the cells asked for.
    #>
    param([Parameter(Mandatory)][string]$Path, [hashtable[]]$Change = @(), [Parameter(Mandatory)][hashtable[]]$Read)

    Import-Module ImportExcel -Verbose:$false
    $copy = Join-Path ([System.IO.Path]::GetDirectoryName($Path)) ('{0}.recalc.xlsx' -f [guid]::NewGuid())
    Copy-Item -LiteralPath $Path -Destination $copy
    $package = Open-ExcelPackage -Path $copy
    try {
        foreach ($item in $Change) { $package.Workbook.Worksheets[$item['Sheet']].Cells[$item['Address']].Value = $item['Value'] }
        [OfficeOpenXml.CalculationExtension]::Calculate($package.Workbook)
        foreach ($item in $Read) { , $package.Workbook.Worksheets[$item['Sheet']].Cells[$item['Address']].Value }
    }
    finally {
        $package.Dispose()
        Remove-Item -LiteralPath $copy -Force
    }
}

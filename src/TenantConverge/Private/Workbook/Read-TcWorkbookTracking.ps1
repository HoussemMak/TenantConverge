function Read-TcWorkbookTracking {
    <#
    .SYNOPSIS
    Reads team-tracking.csv into one row per item, for the workbook to show what the team recorded.

    .DESCRIPTION
    The file holds one row per item and column, or one row per piece of information (Type, Id, Field,
    Value). Both give rows with Id, Type, Status, Assigned to, Note, Answer, Applied and Label. A status keeps
    the words of the workbook, whether the file holds a label or a key such as doing. The notes of two people
    are joined. A leading apostrophe that protects a value from Excel goes away. A file that is missing or
    cannot be read gives no row: the workbook does not depend on it, and a file that cannot be read is
    said so.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }

    try {
        $text = Read-TcSharedText -Path $Path
        $firstLine = ($text -split "`r?`n", 2)[0]
        $delimiter = if (([regex]::Matches($firstLine, ';')).Count -gt ([regex]::Matches($firstLine, ',')).Count) { ';' } else { ',' }
        $rows = @($text | ConvertFrom-Csv -Delimiter $delimiter)
    }
    catch {
        Write-TcMessage -Message "The tracking file $Path could not be read: $(Get-TcErrorText $_). The workbook leaves it out." -Level Warning
        return
    }
    if (-not $rows.Count) { return }

    $columns = @($rows[0].PSObject.Properties.Name)
    if ('Id' -notin $columns) {
        Write-TcMessage -Message "The tracking file $Path has no Id column. The workbook leaves it out." -Level Warning
        return
    }

    $clean = {
        param($Value)
        ([string]$Value) -replace '^''(?=\s*[=+\-@\uFF1D\uFF0B\uFF0D\uFF20])', ''
    }

    $items = [ordered]@{}
    $take = {
        param([string]$Id, [string]$Type)
        if (-not $items.Contains("$Type|$Id")) { $items["$Type|$Id"] = [ordered]@{ Id = $Id; Type = $Type } }
        $items["$Type|$Id"]
    }

    $long = 'Field' -in $columns -and 'Value' -in $columns
    $names = @{ status = 'Status'; assignee = 'Assigned to'; owner = 'Assigned to'; note = 'Note'; answer = 'Answer'; applied = 'Applied'; label = 'Label' }
    $statuses = @{ todo = 'To do'; doing = 'In progress'; done = 'Done'; blocked = 'Blocked'; na = 'Not applicable'; open = 'Open'; decided = 'Decided'; postponed = 'Postponed' }
    $store = {
        param($Item, [string]$Name, [string]$Value)
        if ($Name -eq 'Status' -and $statuses.ContainsKey($Value)) { $Value = $statuses[$Value] }
        if ($Name -eq 'Note' -and $Item.Contains('Note')) { $Value = '{0}; {1}' -f $Item['Note'], $Value }
        $Item[$Name] = $Value
    }
    foreach ($row in $rows) {
        $id = & $clean (Get-TcProperty $row 'Id')
        if (-not $id) { continue }
        $item = & $take $id ([string](Get-TcProperty $row 'Type')).ToLowerInvariant()
        if (Get-TcProperty $row 'Label') { $item['Label'] = & $clean (Get-TcProperty $row 'Label') }

        if ($long) {
            $name = $names[([string](Get-TcProperty $row 'Field')).ToLowerInvariant()]
            if ($name) { & $store $item $name (& $clean (Get-TcProperty $row 'Value')) }
            continue
        }
        foreach ($column in $columns) {
            $name = $names[$column.ToLowerInvariant()]
            if ($name -and (Get-TcProperty $row $column)) { & $store $item $name (& $clean (Get-TcProperty $row $column)) }
        }
    }
    $items.Values
}

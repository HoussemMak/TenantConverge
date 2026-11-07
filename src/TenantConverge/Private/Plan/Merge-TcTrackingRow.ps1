function Merge-TcTrackingRow {
    <#
    .SYNOPSIS
    Joins the team's tracking rows to the items of the plan, and keeps the rows whose item is gone.

    .DESCRIPTION
    Each planned item comes back once, with the columns of its tracking row. A tracking row that matches
    no planned item, for example after a service was found to be absent, comes back after them with
    orphan set to true. Nothing the team wrote is dropped. When an item appears twice, the last row wins.
    The plan decides what is an orphan: an orphan column in the tracking file is ignored.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Item,
        [AllowEmptyCollection()][object[]]$Tracking = @()
    )

    $names = {
        param($Row)
        if ($Row -is [System.Collections.IDictionary]) { @($Row.Keys) } else { @($Row.PSObject.Properties.Name) }
    }

    $rows = [ordered]@{}
    foreach ($row in $Tracking) {
        $id = [string](Get-TcProperty $row 'id')
        if ($id) { $rows[$id] = $row }
    }

    foreach ($planned in $Item) {
        $merged = [ordered]@{}
        foreach ($key in & $names $planned) { $merged[$key] = $planned[$key] }
        $merged['orphan'] = $false
        $id = [string]$planned['id']
        if ($rows.Contains($id)) {
            foreach ($key in & $names $rows[$id]) { if ($key -notin 'id', 'orphan') { $merged[$key] = Get-TcProperty $rows[$id] $key } }
            $rows.Remove($id)
        }
        $merged
    }

    foreach ($id in @($rows.Keys)) {
        $merged = [ordered]@{ id = $id; orphan = $true }
        foreach ($key in & $names $rows[$id]) { if ($key -notin 'id', 'orphan') { $merged[$key] = Get-TcProperty $rows[$id] $key } }
        $merged
    }
}

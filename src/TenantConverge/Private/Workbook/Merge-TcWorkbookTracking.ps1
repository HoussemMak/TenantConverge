function Merge-TcWorkbookTracking {
    <#
    .SYNOPSIS
    Applies what the team recorded to the rows of a tab, and keeps a recorded row that matches nothing.

    .DESCRIPTION
    Merge-TcTrackingRow does the join. A recorded row with no item stays visible, as an Orphan row: the
    work behind it is not lost when an item leaves the plan.

    .PARAMETER Prefix
    What the plan puts before a recorded identifier, as D- for a decision.

    .PARAMETER Orphan
    The values of an orphan row, by column.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tracking,
        [string]$Prefix = '',
        [Parameter(Mandatory)][hashtable]$Orphan
    )

    if (-not $Tracking.Count) { return $Row }

    $known = @{}
    foreach ($item in $Row) { $known[[string]$item['ID']] = $true }

    $recorded = @(foreach ($item in $Tracking) {
            $copy = [ordered]@{}
            foreach ($name in @($item.Keys)) { if ($name -ne 'Type') { $copy[$name] = $item[$name] } }
            $id = [string]$item['Id']
            if (-not $known.ContainsKey($id) -and $Prefix -and $known.ContainsKey("$Prefix$id")) { $copy['Id'] = "$Prefix$id" }
            $copy
        })

    foreach ($line in @(Merge-TcTrackingRow -Item $Row -Tracking $recorded)) {
        if (-not $line['orphan']) {
            $line.Remove('orphan')
            $line.Remove('Label')
            $line
            continue
        }
        $orphanRow = [ordered]@{}
        foreach ($name in $Orphan.Keys) { $orphanRow[$name] = $Orphan[$name] }
        foreach ($name in @($line.Keys)) { if ($name -notin 'orphan', 'Label') { $orphanRow[$name] = $line[$name] } }
        $label = Get-TcProperty $line 'Label'
        $orphanRow[$Orphan['LabelColumn']] = $(if ($label) { $label } else { '(no title in the tracking file)' })
        $orphanRow.Remove('LabelColumn')
        $orphanRow
    }
}

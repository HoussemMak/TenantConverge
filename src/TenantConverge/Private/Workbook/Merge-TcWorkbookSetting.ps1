function Merge-TcWorkbookSetting {
    <#
    .SYNOPSIS
    Applies what the team recorded on the settings to the rows of the Target configurations tab.

    .DESCRIPTION
    The report records a setting under role|setting, and a row is found here by the same key, compared
    exactly. One setting can stand on two rows, under two actions, and one record covers both, as in the
    report: Merge-TcTrackingRow gives a record to one row, so it does not serve here. Only the word Yes
    reads as applied, as in the report.

    A record that matches no row stays visible, as an Orphan row. It belongs to no tenant of this plan, so
    it has the role Orphan, which no count of the Dashboard reads.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Row,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Tracking
    )

    $applied = { param($Record) if ((Get-TcProperty $Record 'Applied') -ceq 'Yes') { 'Yes' } else { 'No' } }

    $recorded = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::Ordinal)
    foreach ($record in $Tracking) { $recorded[[string]$record['Id']] = $record }

    $used = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($item in $Row) {
        $key = '{0}|{1}' -f $item['Role'], $item['Setting']
        if ($recorded.ContainsKey($key)) {
            $item['Applied'] = & $applied $recorded[$key]
            [void]$used.Add($key)
        }
        $item
    }

    foreach ($key in $recorded.Keys) {
        if ($used.Contains($key)) { continue }
        [ordered]@{
            Role = 'Orphan'; Tenant = 'Not in this plan'; Setting = $key; Current = 'Not measured'; Origin = 'Orphan'; Applied = & $applied $recorded[$key]
            Target = 'This row of the tracking file matches nothing in this plan. It stays here so that nothing is lost.'
        }
    }
}

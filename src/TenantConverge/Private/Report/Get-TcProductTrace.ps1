function Get-TcProductTrace {
    <#
    .SYNOPSIS
    Looks for the catalog products in the technical tables of each tenant.

    .DESCRIPTION
    Tables about people are left out: a first name or an address would read as a product. Rows from a tenant
    are data, so patterns only ever run on them, never the other way round. The result also says which
    technical tables were not read: finding nothing in a table nobody read proves nothing.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Catalog,
        [Parameter(Mandatory)][string[]]$Role,
        [Parameter(Mandatory)][System.Collections.IDictionary]$TableState
    )

    $people = 'users', 'teamsUsers', 'mfaRegistrations', 'contacts', 'mailboxes', 'mailboxUsage', 'userActivity', 'oneDrive', 'oneDriveUsage', 'mailboxPermissions', 'mailboxProtocols', 'signInSummary', 'devices', 'managedDevices', 'mobileDevices', 'sharePointExternalUsers', 'riskyUsers', 'teamComposition', 'teamsSettings', 'exchangeSettings'
    $nameColumns = 'Name', 'Application', 'Domain', 'Setting', 'Value', 'Title'
    $options = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::CultureInvariant

    $searches = @(foreach ($product in $Catalog['products']) {
            if ($product['detection']) { @{ Id = $product['id']; Regex = [regex]::new($product['detection'], $options) } }
        })

    $traces = @{}
    foreach ($search in $searches) { $traces[$search['Id']] = [ordered]@{} }

    $coverage = [ordered]@{}
    foreach ($tenant in $Role) {
        $states = $TableState[$tenant]
        $coverage[$tenant] = [ordered]@{
            unread = @($states.Keys | Where-Object { $_ -notin $people -and $states[$_]['state'] -in 'NotCollected', 'NotFullyRead' })
        }

        $tables = Get-TcProperty (Get-TcProperty $Snapshot['tenants'] $tenant) 'tables'
        if ($null -eq $tables) { continue }

        $texts = @{}
        foreach ($name in @($tables.Keys)) {
            if ($name -in $people) { continue }
            $rows = @($tables[$name])
            if (-not $rows.Count) { continue }
            $lines = [string[]]::new($rows.Count)
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $row = $rows[$i]
                $values = if ($row -is [System.Collections.IDictionary]) { $row.Values } else { $row }
                $lines[$i] = @($values) -join ' '
            }
            $texts[$name] = @{ Rows = $rows; Lines = $lines; Blob = $lines -join "`n" }
        }

        foreach ($search in $searches) {
            $regex = $search['Regex']
            $byTable = @{}
            $examples = [System.Collections.Generic.List[string]]::new()
            foreach ($name in $texts.Keys) {
                $text = $texts[$name]
                if (-not $regex.IsMatch($text['Blob'])) { continue }
                $count = 0
                for ($i = 0; $i -lt $text['Lines'].Count; $i++) {
                    if (-not $regex.IsMatch($text['Lines'][$i])) { continue }
                    $count++
                    if ($examples.Count -ge 40) { continue }
                    foreach ($column in $nameColumns) {
                        $value = Get-TcProperty $text['Rows'][$i] $column
                        if ($value -is [string] -and $value -and $value.Length -lt 90 -and $regex.IsMatch($value)) { $examples.Add($value); break }
                    }
                }
                if ($count) { $byTable[$name] = $count }
            }
            if (-not $byTable.Count) { continue }

            $sorted = @($byTable.GetEnumerator() | Sort-Object -Property @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key' })
            $traces[$search['Id']][$tenant] = [ordered]@{
                total    = [int](($sorted | Measure-Object -Property Value -Sum).Sum)
                tables   = @($sorted | Select-Object -First 6 | ForEach-Object { , @($_.Key, $_.Value) })
                examples = @($examples | Select-Object -Unique -First 5)
            }
        }
    }

    @{ Traces = $traces; Coverage = $coverage }
}

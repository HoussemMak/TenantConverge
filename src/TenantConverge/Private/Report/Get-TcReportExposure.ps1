function Get-TcReportExposure {
    <#
    .SYNOPSIS
    Computes what the limits of the tools touch in the sources, from the snapshot alone.

    .DESCRIPTION
    A value is empty when its table was not read, so a gap never reads as a zero. A zero is a real zero:
    the table was read and holds nothing. Each line says which sources it could not see, and its text says
    so too: it never concludes on what was not read.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Catalog,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Source,
        [Parameter(Mandatory)][System.Collections.IDictionary]$TableState,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Measure,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Identity,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Name
    )

    $tenants = $Snapshot['tenants']
    $states = $TableState
    $measures = $Measure

    $rowsOf = {
        param([string]$Role, [string]$Table)
        if ($states[$Role][$Table]['state'] -in 'NotCollected', 'NotFullyRead') { return $null }
        , @(Get-TcProperty (Get-TcProperty (Get-TcProperty $tenants $Role) 'tables') $Table @())
    }

    # Calls a block on the rows of a table, for each source. An unread table gives an empty value.
    $perSource = {
        param([string]$Table, [scriptblock]$Read)
        $values = [ordered]@{}
        foreach ($role in $Source) {
            $rows = & $rowsOf $role $Table
            $values[$role] = if ($null -eq $rows) { $null } else { & $Read $rows }
        }
        $values
    }

    $count = { param($Rows) @($Rows).Count }

    $largest = & $perSource 'mailboxUsage' {
        param($Rows)
        $sizes = @($Rows | ForEach-Object { Get-TcRowNumber $_ 'Size GB' })
        if ($sizes.Count) { [math]::Round((($sizes | Measure-Object -Maximum).Maximum), 1) } else { 0 }
    }
    $bigSites = & $perSource 'siteUsage' { param($Rows) @($Rows | Where-Object { (Get-TcRowNumber $_ 'Storage GB') -ge 100 }).Count }
    $bigVolume = & $perSource 'siteUsage' {
        param($Rows)
        $sum = (@($Rows | ForEach-Object { Get-TcRowNumber $_ 'Storage GB' } | Where-Object { $_ -ge 100 }) | Measure-Object -Sum).Sum
        [math]::Round([double]$sum)
    }

    $duplicates = [ordered]@{}
    foreach ($role in $Source) {
        $line = $Identity[$role]
        $duplicates[$role] = if ($line -and $line['drafted']) { [int]$line['counts']['Duplicate'] } else { $null }
    }

    $fromMeasure = {
        param([string]$Label)
        $line = @($measures | Where-Object { $_['label'] -eq $Label }) | Select-Object -First 1
        $values = [ordered]@{}
        foreach ($role in $Source) { $values[$role] = if ($line) { Get-TcProperty $line['values'] $role } else { $null } }
        $values
    }

    $values = [ordered]@{
        largestMailbox     = $largest
        largeSites         = $bigSites
        likelyDuplicates   = $duplicates
        bookings           = & $perSource 'mailboxes' { param($Rows) @($Rows | Where-Object { (Get-TcProperty $_ 'Type') -eq 'SchedulingMailbox' }).Count }
        sharedChannels     = & $fromMeasure 'Shared channels'
        plannerPlans       = & $perSource 'plannerPlans' $count
        microsoft365Groups = & $perSource 'microsoft365Groups' $count
        archives           = & $perSource 'mailboxes' { param($Rows) @($Rows | Where-Object { Test-TcRowTrue $_ 'Archive' }).Count }
        holds              = & $perSource 'mailboxes' { param($Rows) @($Rows | Where-Object { (Test-TcRowTrue $_ 'Litigation hold') -or (Get-TcProperty $_ 'Holds') }).Count }
        frontline          = & $perSource 'licenses' {
            param($Rows)
            $seats = @($Rows | Where-Object { [string](Get-TcProperty $_ 'SKU') -match '(?i)KIOSK|DESKLESS|SPE_F1|M365_F1|M365_F3|SPE_F3' } | ForEach-Object { Get-TcRowNumber $_ 'Consumed' })
            [int](($seats | Measure-Object -Sum).Sum)
        }
        userMailboxes      = & $fromMeasure 'User mailboxes'
        sharedMailboxes    = & $fromMeasure 'Shared mailboxes'
        oneDriveAccounts   = & $fromMeasure 'OneDrive accounts'
        sites              = & $fromMeasure 'Sites'
        teams              = & $fromMeasure 'Teams'
        privateChannels    = & $fromMeasure 'Private channels'
        autopilotDevices   = & $fromMeasure 'Autopilot devices'
    }

    $facts = foreach ($line in $Catalog['exposure']) {
        $id = $line['id']
        $mine = $values[$id]
        $read = @($Source | Where-Object { $null -ne $mine[$_] })
        $unread = @($Source | Where-Object { $null -eq $mine[$_] })
        $names = @($unread | ForEach-Object { $Name[$_] }) -join ', '
        $numbers = @($read | ForEach-Object { [double]$mine[$_] })
        $highest = if ($numbers.Count) { ($numbers | Measure-Object -Maximum).Maximum } else { 0 }
        $total = if ($numbers.Count) { ($numbers | Measure-Object -Sum).Sum } else { 0 }

        if (-not $read.Count) { $tone = 'gap'; $text = 'Not read: nothing can be said here.' }
        elseif ($total -gt 0) {
            $volume = (@($read | ForEach-Object { [double]$bigVolume[$_] }) | Measure-Object -Sum).Sum
            $tone = $line['someTone']
            $text = ([string]$line['some']).Replace('{hours}', [string][math]::Round($highest / 1.5)).Replace('{volume}', [string][math]::Round([double]$volume))
            if ($unread.Count) { $text += " Not read: $names, so this is a minimum." }
        }
        elseif ($unread.Count) { $tone = 'gap'; $text = "None in what was read. Not read: $names." }
        else { $tone = $line['noneTone']; $text = $line['none'] }

        [ordered]@{ id = $id; label = $line['label']; unit = $line['unit']; source = $line['source']; values = $mine; unread = $unread; tone = $tone; text = $text }
    }

    @{ Values = $values; Facts = @($facts) }
}

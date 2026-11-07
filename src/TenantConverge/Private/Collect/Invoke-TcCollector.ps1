function Invoke-TcCollector {
    <#
    .SYNOPSIS
    Runs one collector, in isolation, and records its coverage.

    .DESCRIPTION
    A missing module or a refused access ends up in the coverage with what to do about it, and the
    collection continues. A collector that did not collect leaves no empty table behind: an empty table
    means the service is not used, so it must never stand for a table that could not be read. A collector
    cut by a row limit ends up Partial and says so.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Collector,
        [Parameter(Mandatory)][string]$Role,
        [int]$Rank = 1,
        [int]$Total = 1
    )

    $id = $Collector['Id']
    $service = $Collector['Service']
    $label = (Get-TcServiceInfo $service)['Label']
    Write-TcStepStart -Rank $Rank -Total $Total -Id $id -Title $Collector['Title'] -Purpose "$($Collector['Workload']) - $label"

    $state = [ordered]@{
        id       = $id
        tables   = [System.Collections.Generic.List[string]]::new()
        warnings = [System.Collections.Generic.List[string]]::new()
        classes  = [System.Collections.Generic.List[string]]::new()
        notes    = [System.Collections.Generic.List[string]]::new()
        limits   = [System.Collections.Generic.List[string]]::new()
    }
    $script:TcCurrentCollector = $state
    $status = 'OK'
    $message = ''
    $remedy = ''
    $connected = $false
    $timer = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        $module = Test-TcServiceModule $service
        $blocked = Get-TcBlockedRequirement -Collector $Collector
        if (-not $module['ok']) {
            $status = $module['status']
            $message = $module['message']
            $remedy = $module['remedy']
        }
        elseif ($blocked) {
            $status = $blocked['status']
            $message = $blocked['message']
            $remedy = $blocked['remedy']
        }
        else {
            Connect-TcService -Service $service -Role $Role
            $connected = $true
            & $Collector['Collect'] $Role

            if ($state['warnings'].Count) {
                $rows = (@($state['tables'] | ForEach-Object { @(Get-TcTable $_).Count }) | Measure-Object -Sum).Sum
                $first = $state['classes'][0]
                $status = if ($rows -gt 0) { 'Partial' } elseif ($first -eq 'Not configured') { 'Insufficient access' } else { $first }
                $message = (@($state['warnings']) | Select-Object -First 4) -join ' - '
                $remedy = Get-TcRemedy -Service $service -Class ($state['classes'] | Where-Object { $_ -ne 'Failed' } | Select-Object -First 1) -Role $Role
            }

            if ($state['limits'].Count) {
                $message = (@($message) + @($state['limits']) | Where-Object { $_ }) -join ' - '
                if ($status -eq 'OK') {
                    $status = 'Partial'
                    $remedy = 'The limit protects the run on a large tenant. Review by hand what is beyond it.'
                }
            }
        }
    }
    catch {
        $text = Get-TcErrorText -ErrorInput $_
        $class = Get-TcErrorClass -Text $text
        # A service that could not be reached was not read at all: that is an access gap, not an empty result.
        if (-not $connected -and $class -eq 'Failed') { $class = 'Insufficient access' }
        $status = if ($class -eq 'Not configured') { 'Insufficient access' } else { $class }
        $message = $text -replace '^NOTCONFIGURED\s*:\s*', ''
        $remedy = Get-TcRemedy -Service $service -Class $class -Role $Role
        Write-TcLog -Message "Collector ${id}: $status - $text" -Level WARN -Step $id
    }

    $timer.Stop()
    $seconds = [math]::Round($timer.Elapsed.TotalSeconds, 1)

    if ($status -notin 'OK', 'Partial') {
        foreach ($table in @($state['tables'])) {
            if (@(Get-TcTable $table).Count -eq 0) {
                $script:TcCurrentTenant['tables'].Remove($table)
                [void]$state['tables'].Remove($table)
            }
        }
    }

    $rows = [int](@($state['tables'] | ForEach-Object { @(Get-TcTable $_).Count }) | Measure-Object -Sum).Sum
    $notes = @($state['notes']) -join ' - '
    if ($notes) { $message = if ($message) { "$message - $notes" } else { $notes } }
    $message = Protect-TcSecret -InputObject $message

    switch ($status) {
        'OK' {
            Write-TcStepLine -Status OK -Text ('{0} tables, {1} rows' -f $state['tables'].Count, $rows) -Step $id
            Write-TcStepEnd -Status Done -Seconds $seconds
        }
        'Partial' {
            Write-TcStepLine -Status Warning -Text ('Partial collection: {0} rows - {1}' -f $rows, $message) -Step $id
            Write-TcStepLine -Status Info -Text $remedy -Step $id
            Write-TcStepEnd -Status Warning -Seconds $seconds
        }
        default {
            Write-TcStepLine -Status Warning -Text ('{0}: {1}' -f $status, $message) -Step $id
            Write-TcStepLine -Status Info -Text $remedy -Step $id
            Write-TcStepEnd -Status Skipped -Seconds $seconds -Detail $status
        }
    }

    $line = [ordered]@{
        role     = $Role
        tenant   = $script:TcCurrentTenant['tenant']
        id       = $id
        workload = $Collector['Workload']
        title    = $Collector['Title']
        service  = $label
        status   = $status
        message  = $message
        remedy   = $remedy
        duration = $seconds
        rows     = $rows
        tables   = @($state['tables'])
    }
    $script:TcCurrentTenant['coverage'].Add($line)
    $script:TcCurrentCollector = $null
    $line
}

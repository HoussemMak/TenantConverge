function Test-TcReportReference {
    <#
    .SYNOPSIS
    Returns every reference of the product catalog that points to nothing: task, decision, source, family.

    .DESCRIPTION
    Each line names the entry and the missing reference. New-TcReport stops when there is one: a sheet that
    cites a source or a task that does not exist is a broken promise to the reader.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Catalog
    )

    $tasks = Get-TcTaskCatalog
    $sources = $Catalog['sources']
    $families = @($Catalog['families'] | ForEach-Object { $_['id'] })
    $products = @($Catalog['products'] | ForEach-Object { $_['id'] })
    $states = $Catalog['matrixStates']
    $exposure = @($Catalog['exposure'] | ForEach-Object { $_['id'] }) + 'userMailboxes', 'sharedMailboxes', 'oneDriveAccounts', 'sites', 'teams', 'privateChannels', 'autopilotDevices'

    $source = {
        param([string]$Where, [AllowNull()]$Fact)
        if ($Fact -and $Fact['source'] -and -not $sources.Contains($Fact['source'])) { "$Where cites the source $($Fact['source']), which does not exist." }
    }

    foreach ($product in $Catalog['products']) {
        $id = $product['id']
        if ($product['family'] -notin $families) { "$id is in the family $($product['family']), which does not exist." }
        foreach ($task in @($product['tasks'])) { if (-not $tasks.Contains($task)) { "$id points to the task $task, which does not exist." } }
        foreach ($decision in @($product['decisions'])) {
            if (-not $tasks.Contains($decision)) { "$id points to the decision $decision, which does not exist." }
            elseif (-not (Get-TcProperty $tasks[$decision] 'decision')) { "$id points to the decision $decision, a task with no decision." }
        }
        foreach ($key in 'license', 'rights', 'dataLocation') { & $source "$id ($key)" $product[$key] }
        foreach ($limit in @($product['limits'])) { & $source "$id (limit)" $limit }
    }

    foreach ($tool in $Catalog['copyTools']) {
        if ($tool['id'] -notin $products) { "The copy tool $($tool['id']) is not a product." }
    }

    foreach ($need in $Catalog['copyMatrix']) {
        $cells = $need['cells']
        if ($need['exposure'] -and $need['exposure'] -notin $exposure) { "$($need['id']) points to the exposure $($need['exposure']), which does not exist." }
        foreach ($tool in $Catalog['copyTools']) {
            $name = $tool['id']
            if (-not $cells.Contains($name)) { "$($need['id']) has no cell for $name."; continue }
            if (-not $states.Contains($cells[$name]['state'])) { "$($need['id']) uses the state $($cells[$name]['state']), which does not exist." }
            & $source "$($need['id']) ($name)" $cells[$name]
        }
    }

    foreach ($fact in $Catalog['exposure']) { & $source "$($fact['id']) (exposure)" $fact }
    foreach ($key in 'milestones', 'dependencies') {
        foreach ($fact in $Catalog['ews'][$key]) { & $source "EWS $key" $fact }
    }
}

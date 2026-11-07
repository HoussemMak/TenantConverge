function Get-TcTaskCatalog {
    <#
    .SYNOPSIS
    Returns the task templates by identifier, in the order of Data\tasks.json.

    .DESCRIPTION
    Read once. A template declares its scope (Project, Target, Source or Wave) and, when it is useful only
    in some cases, the condition that makes it apply: rules that fired or tables with rows.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    if ($null -eq $script:TcTaskCatalog) {
        $file = Join-Path $PSScriptRoot '..' '..' 'Data' 'tasks.json'
        $catalog = [ordered]@{}
        foreach ($task in @((Read-TcJsonFile -Path $file)['tasks'])) { $catalog[$task['id']] = $task }
        $script:TcTaskCatalog = $catalog
    }
    $script:TcTaskCatalog
}

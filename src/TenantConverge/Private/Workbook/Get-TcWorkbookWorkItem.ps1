function Get-TcWorkbookWorkItem {
    <#
    .SYNOPSIS
    Turns the actions and the tasks of a plan into the rows of the Action plan tab.

    .DESCRIPTION
    A wave task belongs to all tenants in the plan. When its wave has one source, the row names that
    source, so the Tenant view finds it.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    $procedures = Get-TcProperty $Plan 'procedures' @{}
    $badges = Get-TcWorkbookRemediationBadge -Plan $Plan
    $names = @{ All = 'All tenants' }
    foreach ($tenant in @(Get-TcProperty $Plan 'tenants' @())) { $names[$tenant['role']] = $tenant['displayName'] }

    $duration = { param($Id) if ($Id) { Get-TcProperty (Get-TcProperty $procedures $Id) 'duration' } }
    $goal = { param($Id) if ($Id) { Get-TcProperty (Get-TcProperty $procedures $Id) 'goal' } }

    foreach ($action in @(Get-TcProperty $Plan 'actions' @())) {
        $procedure = Get-TcProperty $action 'procedure'
        $time = & $duration $procedure
        [ordered]@{
            ID = $action['id']; Kind = 'Action'; Role = $action['role']; Tenant = $action['tenant']; Wave = Get-TcProperty $action 'wave'; Moment = $action['moment']
            Workload = Get-TcProperty $action 'workload'; 'What to do' = $action['title']; Severity = $action['severity']; Blocking = $(if ($action['blocking']) { 'Yes' })
            Owner = $action['owner']; Duration = $(if ($time) { $time } else { Get-TcProperty $action 'effort' }); Status = 'To do'
            Finding = Get-TcProperty $action 'finding'; 'Recommended action' = Get-TcProperty $action 'action'; Why = Get-TcProperty $action 'why'; Goal = & $goal $procedure
            'Item count' = $(if (Get-TcProperty $action 'itemCount' 0) { [int]$action['itemCount'] }); Items = @(Get-TcProperty $action 'items' @()) -join '; '
            Question = Get-TcProperty $action 'question'; Procedure = $procedure
            Remediations = @(@(Get-TcProperty $action 'remediations' @()) | ForEach-Object { '{0} ({1})' -f $_, $(if ($badges.ContainsKey([string]$_)) { $badges[[string]$_] } else { 'Untested' }) }) -join ', '
        }
    }

    foreach ($task in @(Get-TcProperty $Plan 'tasks' @())) {
        $procedure = Get-TcProperty $task 'procedure'
        $sources = @(Get-TcProperty $task 'sources' @())
        $role = if ($task['role'] -eq 'All' -and $sources.Count -eq 1) { $sources[0] } else { $task['role'] }
        [ordered]@{
            ID = $task['id']; Kind = 'Task'; Role = $role; Tenant = $names[$role]; Wave = Get-TcProperty $task 'wave'; Moment = $task['moment']
            Workload = Get-TcProperty $task 'workstream'; 'What to do' = $task['title']; Owner = $task['owner']; Duration = & $duration $procedure; Status = 'To do'
            Goal = & $goal $procedure; Confirmation = Get-TcProperty $task 'confirmation'; Reason = Get-TcProperty $task 'reason'; Question = Get-TcProperty $task 'decision'; Procedure = $procedure
        }
    }
}

function Get-TcPlanDecision {
    <#
    .SYNOPSIS
    Lists the decisions to make: the question of each action and of each task that has one.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Action,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Task
    )

    foreach ($item in @($Action | Where-Object { $_['question'] })) {
        [ordered]@{ id = "D-$($item['id'])"; role = $item['role']; wave = $item['wave']; question = $item['question']; owner = $item['owner']; moment = $item['moment']; origin = 'Action'; reference = $item['id'] }
    }
    foreach ($item in @($Task | Where-Object { $_['decision'] })) {
        [ordered]@{ id = "D-$($item['id'])"; role = $item['role']; wave = $item['wave']; question = $item['decision']; owner = $item['owner']; moment = $item['moment']; origin = 'Task'; reference = $item['id'] }
    }
}

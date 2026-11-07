function Get-TcWorkbookStep {
    <#
    .SYNOPSIS
    Turns the procedures of the work items into the rows of the Detailed steps tab.

    .DESCRIPTION
    A watch point is to read before acting: it is not ticked, and it does not count in the progress.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Item,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Plan
    )

    $procedures = Get-TcProperty $Plan 'procedures' @{}
    foreach ($row in $Item) {
        $id = $row['Procedure']
        if (-not $id) { continue }
        $procedure = Get-TcProperty $procedures $id
        if (-not $procedure) { continue }

        $lines = @(
            @(Get-TcProperty $procedure 'prerequisites' @()) | ForEach-Object { , @('Prerequisite', $_, '', '') }
            @(Get-TcProperty $procedure 'risks' @()) | ForEach-Object { , @('Watch point', $_, '', '') }
            @(Get-TcProperty $procedure 'steps' @()) | ForEach-Object { , @('Step', (Get-TcProperty $_ 'text'), (Get-TcProperty $_ 'where'), (Get-TcProperty $_ 'command')) }
            @(Get-TcProperty $procedure 'verification' @()) | ForEach-Object { , @('Verification', $_, '', '') }
        )

        $number = 0
        foreach ($line in $lines) {
            $number++
            [ordered]@{
                Item = $row['ID']; Role = $row['Role']; Tenant = $row['Tenant']; Moment = $row['Moment']; 'Item title' = $row['What to do']; Type = $line[0]; 'No.' = $number
                'What to do' = $line[1]; Where = $line[2]; Command = $line[3]; Owner = $row['Owner']; Status = $(if ($line[0] -eq 'Watch point') { 'To read' } else { 'To do' })
            }
        }
    }
}

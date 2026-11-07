function Get-TcPlanTask {
    <#
    .SYNOPSIS
    Turns the task templates into the tasks of this project.

    .DESCRIPTION
    A Project or Target task appears once, a Source task once per source, a Wave task once per wave. The
    identifier is the template plus the scope (ID-02.S1), so it stays the same from one run to the next,
    whatever the row order or the number of sources. A Wave task takes the roles of its members, in role
    order (CUT-01.S1, CUT-01.S1-S2), not the wave number: a Done recorded for one source never moves to
    another when two sources swap waves. When the members change, the identifier changes, and the old
    tracking row shows as an orphan.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable]$Context
    )

    $sources = @($Context['Sources'])
    $rows = foreach ($template in (Get-TcTaskCatalog).Values) {
        $state = Get-TcProperty $template 'targetState'
        if ($state -and $state -ne $Context['TargetState']) { continue }

        $templateId = $template['id']
        $instances = switch ($template['scope']) {
            'Project' { @{ Id = $templateId; Role = 'All'; Roles = @('Target') + $sources; Wave = $null; Sources = @(); Tenant = ''; Label = '' } }
            'Target' { @{ Id = "$templateId.Target"; Role = 'Target'; Roles = @('Target'); Wave = $null; Sources = @(); Tenant = ''; Label = '' } }
            'Source' {
                foreach ($source in $sources) {
                    @{ Id = "$templateId.$source"; Role = $source; Roles = @($source); Wave = $Context['WaveOf'][$source]; Sources = @($source); Tenant = $Context['Names'][$source]; Label = '' }
                }
            }
            'Wave' {
                foreach ($wave in @($Context['Waves'])) {
                    @{ Id = "$templateId.$(@($wave['sources']) -join '-')"; Role = 'All'; Roles = @($wave['sources']); Wave = $wave['wave']; Sources = @($wave['sources']); Tenant = ''; Label = $wave['label'] }
                }
            }
        }

        foreach ($instance in @($instances)) {
            $result = Test-TcTaskCondition -Condition (Get-TcProperty $template 'condition') -Role $instance['Roles'] -Context $Context
            if ($result.State -eq 'Absent') { continue }

            [ordered]@{
                id = $instance['Id']; templateId = $templateId
                title = $template['title'].Replace('{tenant}', $instance['Tenant']).Replace('{wave}', $instance['Label'])
                workstream = $template['workstream']; scope = $template['scope']; role = $instance['Role']; wave = $instance['Wave']; sources = @($instance['Sources'])
                moment = $template['moment']; owner = $template['owner']; procedure = [string](Get-TcProperty $template 'procedure' ''); decision = [string](Get-TcProperty $template 'decision' '')
                confirmation = $(if ($result.State -eq 'Unconfirmed') { 'Unconfirmed' } else { 'Confirmed' }); reason = $result.Reason
            }
        }
    }

    $moments = $Context['Moments']
    @($rows | Sort-Object -Stable { [array]::IndexOf($moments, $_['moment']) })
}

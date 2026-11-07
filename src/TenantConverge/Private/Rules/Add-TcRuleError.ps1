function Add-TcRuleError {
    <#
    .SYNOPSIS
    Notes that a rule, a measure or a setting comparison stopped. The rest of the rule set carries on.

    .DESCRIPTION
    A rule that stopped says nothing, which must not read as a rule that found nothing. Readiness counts
    the workload as not fully read, and a task that depends on its rules stays unconfirmed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Role,
        [AllowNull()][AllowEmptyString()][string]$Workload,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $text = Get-TcErrorText $ErrorRecord
    $script:TcRuleRun['Errors'].Add([ordered]@{ role = $Role; workload = $Workload; message = "$text at $($ErrorRecord.InvocationInfo.ScriptLineNumber)" })
    Write-TcLog -Message "A rule stopped ($Role, $Workload): $text" -Level 'WARN'
}

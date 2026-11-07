function Write-TcStepLine {
    <#
    .SYNOPSIS
    Shows the result of part of a step on screen and in the log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('OK', 'Warning', 'Info')][string]$Status,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string]$Step = ''
    )

    $display = switch ($Status) {
        'OK' { @{ Symbol = [char]0x2714; Level = 'Success'; Log = 'OK' } }
        'Warning' { @{ Symbol = [char]0x26A0; Level = 'Warning'; Log = 'WARN' } }
        default { @{ Symbol = [char]0x2022; Level = 'Info'; Log = 'INFO' } }
    }

    Write-TcMessage -Message ('        {0} {1}' -f $display['Symbol'], $Text) -Level $display['Level']
    Write-TcLog -Message ('{0}: {1}' -f $Status, $Text) -Level $display['Log'] -Step $Step
}

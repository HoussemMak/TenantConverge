function Write-TcStepEnd {
    <#
    .SYNOPSIS
    Closes a step on screen with its result and its duration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Done', 'Warning', 'Skipped')][string]$Status,
        [double]$Seconds,
        [string]$Detail = ''
    )

    $suffix = if ($Detail) { " - $Detail" } else { '' }
    $level = switch ($Status) {
        'Done' { 'Success' }
        'Warning' { 'Warning' }
        default { 'Info' }
    }
    $seconds = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:N1}', $Seconds)
    Write-TcMessage -Message ('        {0} in {1} s{2}' -f $Status, $seconds, $suffix) -Level $level
}

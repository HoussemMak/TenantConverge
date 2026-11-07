function Get-TcRetryDelay {
    <#
    .SYNOPSIS
    Returns the seconds to wait before a retry: what the service asked for in Retry-After, otherwise a growing delay.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [AllowNull()]$ErrorRecord,
        [Parameter(Mandatory)][int]$Attempt,
        [int]$BaseSeconds = 5
    )

    $text = Get-TcErrorText -ErrorInput $ErrorRecord
    if ($text -match '(?i)Retry-After\D{0,3}(\d+)') { return [int]$Matches[1] }

    $response = Get-TcProperty (Get-TcProperty $ErrorRecord 'Exception') 'Response'
    $headers = Get-TcProperty $response 'Headers'
    $retryAfter = Get-TcProperty $headers 'RetryAfter'
    $delta = Get-TcProperty $retryAfter 'Delta'
    if ($delta) { return [int]$delta.TotalSeconds }

    $BaseSeconds * $Attempt
}

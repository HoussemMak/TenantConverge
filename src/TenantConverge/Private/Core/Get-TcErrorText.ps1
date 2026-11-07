function Get-TcErrorText {
    <#
    .SYNOPSIS
    Reads the useful text of an error, unwrapping the JSON body Graph returns.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()]$ErrorInput
    )

    if ($null -eq $ErrorInput) { return '' }

    $text = if ($ErrorInput -is [System.Management.Automation.ErrorRecord]) {
        $details = Get-TcProperty (Get-TcProperty $ErrorInput 'ErrorDetails') 'Message'
        if ($details) { $details } else { $ErrorInput.Exception.Message }
    }
    elseif ($ErrorInput -is [System.Exception]) { $ErrorInput.Message }
    else { [string]$ErrorInput }

    $start = $text.IndexOf('{"error"')
    if ($start -ge 0) {
        try {
            $body = $text.Substring($start) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            $text = '{0}: {1}' -f (Get-TcProperty $body['error'] 'code'), (Get-TcProperty $body['error'] 'message')
        }
        catch { Write-Verbose 'The error body is not JSON: keeping it as text.' }
    }

    ($text -replace '\s+', ' ').Trim()
}

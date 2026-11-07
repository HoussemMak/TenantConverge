function Write-TcLog {
    <#
    .SYNOPSIS
    Adds a line to the text log and an event to the JSONL file. Secrets are masked first.

    .DESCRIPTION
    Does nothing until Initialize-TcLog has run. The separate collection process writes to the same
    files, so a locked file is retried a few times.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$Step = '',
        [hashtable]$Data
    )

    if (-not $script:TcLogFile) { return }

    $now = Get-Date
    $safeMessage = Protect-TcSecret -InputObject $Message
    $prefix = if ($Step) { "[$Step] " } else { '' }
    $line = '{0} [{1,-5}] {2}{3}' -f $now.ToString('yyyy-MM-dd HH:mm:ss'), $Level, $prefix, $safeMessage

    $record = [ordered]@{ timestamp = $now.ToString('o'); level = $Level; step = $Step; message = $safeMessage }
    if ($Data) { $record['data'] = Protect-TcSecret -InputObject $Data }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            [System.IO.File]::AppendAllText($script:TcLogFile, $line + [Environment]::NewLine, $encoding)
            [System.IO.File]::AppendAllText($script:TcEventFile, ($record | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine, $encoding)
            return
        }
        catch { Start-Sleep -Milliseconds 100 }
    }
}

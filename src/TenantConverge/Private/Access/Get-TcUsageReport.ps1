function Get-TcUsageReport {
    <#
    .SYNOPSIS
    Reads a Microsoft 365 usage report as CSV rows, over D7, D30, D90 or D180.

    .DESCRIPTION
    On a large tenant a report can exceed the 300 second limit of the Graph client. The period then
    shrinks to 30 days, then 7, and the collector notes it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [string]$Period
    )

    if (-not $Period) { $Period = Get-TcCollectionSetting 'reportPeriod' }
    $shorter = @{ D180 = 'D30'; D90 = 'D30'; D30 = 'D7' }
    $file = [System.IO.Path]::GetTempFileName()

    try {
        for ($attempt = 1; $attempt -le 4; $attempt++) {
            try {
                Invoke-MgGraphRequest -Method GET -Uri ("https://graph.microsoft.com/v1.0/reports/{0}(period='{1}')" -f $Name, $Period) -OutputFilePath $file -ErrorAction Stop
                break
            }
            catch {
                $text = Get-TcErrorText -ErrorInput $_
                if ($attempt -lt 4 -and $text -match '429|503|TooManyRequests|ServiceUnavailable') {
                    Start-Sleep -Seconds (Get-TcRetryDelay -ErrorRecord $_ -Attempt $attempt)
                    continue
                }
                if ($attempt -lt 4 -and $text -match 'Timeout|timed out|canceled|504' -and $shorter.ContainsKey($Period)) {
                    $next = $shorter[$Period]
                    Add-TcCollectorNote ('Report {0} covers {1} days (the {2} request timed out).' -f $Name, $next.TrimStart('D'), $Period)
                    $Period = $next
                    continue
                }
                throw
            }
        }
        @(Import-Csv -LiteralPath $file -Encoding UTF8)
    }
    finally {
        Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
    }
}

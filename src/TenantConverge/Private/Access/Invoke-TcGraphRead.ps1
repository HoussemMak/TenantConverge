function Invoke-TcGraphRead {
    <#
    .SYNOPSIS
    Reads from Microsoft Graph, always with GET. Throttled calls are retried. -All follows every page.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [switch]$All
    )

    $url = if ($Uri -match '^https://') { $Uri } else { "https://graph.microsoft.com/$Uri" }

    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $response = Invoke-MgGraphRequest -Method GET -Uri $url -OutputType Hashtable -ErrorAction Stop
            if (-not $All) { return $response }

            $items = [System.Collections.Generic.List[object]]::new()
            while ($true) {
                foreach ($value in @(Get-TcProperty $response 'value')) {
                    if ($null -ne $value) { $items.Add($value) }
                }
                $next = Get-TcProperty $response '@odata.nextLink'
                if (-not $next) { break }
                $response = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType Hashtable -ErrorAction Stop
            }
            return $items.ToArray()
        }
        catch {
            $text = Get-TcErrorText -ErrorInput $_
            if ($attempt -lt 4 -and $text -match '429|TooManyRequests|503|504|ServiceUnavailable|GatewayTimeout') {
                Start-Sleep -Seconds (Get-TcRetryDelay -ErrorRecord $_ -Attempt $attempt)
                continue
            }
            throw
        }
    }
}

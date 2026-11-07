function Protect-TcSecret {
    <#
    .SYNOPSIS
    Masks anything that looks like a secret in a text or in structured data, before it is logged.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject
    )

    $mask = '***'
    $sensitiveKey = '(?i)password|passwd|pwd|secret|token|credential|thumbprint|private'

    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [securestring]) { return $mask }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $safe = [ordered]@{}
        foreach ($key in @($InputObject.Keys)) {
            $safe[[string]$key] = if ([string]$key -match $sensitiveKey) { $mask } else { Protect-TcSecret -InputObject $InputObject[$key] }
        }
        return $safe
    }

    if ($InputObject -isnot [string] -and $InputObject -is [System.Collections.IEnumerable]) {
        return , @($InputObject | ForEach-Object { Protect-TcSecret -InputObject $_ })
    }

    if ($InputObject -isnot [string]) { return $InputObject }

    $text = $InputObject
    $text = $text -replace '(?s)-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----', $mask
    $text = $text -replace '\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*', $mask
    $text = $text -replace '(?i)\bBearer\s+[A-Za-z0-9\-._~+/]+=*', "Bearer $mask"
    $text = $text -replace '(?i)("?(?:password|passwd|pwd|client_?secret|secret|api_?key|access_token|refresh_token|id_token|token)"?\s*[:=]\s*"?)[^\s"'';,&]+', "`$1$mask"
    $text = $text -replace '\b[0-9A-Fa-f]{40}\b', $mask
    $text
}

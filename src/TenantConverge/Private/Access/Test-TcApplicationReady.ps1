function Test-TcApplicationReady {
    <#
    .SYNOPSIS
    Tells whether a tenant has the read-only application, with its valid certificate on this computer.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()]$Tenant
    )

    $auth = Get-TcApplicationAuth -Tenant $Tenant
    if (-not $auth) { return $false }

    $certificate = Get-Item -LiteralPath "Cert:\CurrentUser\My\$($auth['thumbprint'])" -ErrorAction SilentlyContinue
    [bool]($certificate -and $certificate.HasPrivateKey -and $certificate.NotAfter -gt (Get-Date))
}

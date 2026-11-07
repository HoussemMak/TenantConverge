function Test-TcTenantAccess {
    <#
    .SYNOPSIS
    Tries each service of a tenant with the read-only application, and creates nothing.

    .DESCRIPTION
    Permissions take a few minutes to reach every service, so each service is tried a few times. PnP
    runs in its own process, because it stops PowerShell when loaded with the Graph and Exchange modules.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tenant,
        [string[]]$Service = @('Graph', 'Exo', 'Ipps', 'Teams', 'Pnp')
    )

    $name = Get-TcProperty $Tenant 'displayName'
    $auth = Get-TcApplicationAuth -Tenant $Tenant
    if (-not $auth) {
        return [pscustomobject]@{ Tenant = $name; Service = 'All'; Result = 'Not initialized' }
    }

    $clientId = $auth['clientId']
    $thumbprint = $auth['thumbprint']
    $tenantId = Get-TcProperty $Tenant 'tenantId'
    $domain = Get-TcProperty $Tenant 'initialDomain'
    if (-not $domain) { $domain = Get-TcProperty $auth 'initialDomain' }

    $tests = [ordered]@{
        Graph = {
            Connect-MgGraph -ClientId $clientId -TenantId $tenantId -CertificateThumbprint $thumbprint -NoWelcome -ErrorAction Stop
            $organization = @(Get-TcProperty (Invoke-TcGraphRead -Uri 'v1.0/organization') 'value') | Select-Object -First 1
            Invoke-TcGraphRead -Uri 'v1.0/users?$top=1' | Out-Null
            Get-TcProperty $organization 'displayName'
        }
        Exo   = {
            Connect-ExchangeOnline -AppId $clientId -CertificateThumbprint $thumbprint -Organization $domain -ShowBanner:$false -ErrorAction Stop
            Get-TcProperty (Get-OrganizationConfig -ErrorAction Stop) 'DisplayName'
        }
        Ipps  = {
            Connect-IPPSSession -AppId $clientId -CertificateThumbprint $thumbprint -Organization $domain -ShowBanner:$false -ErrorAction Stop
            '{0} retention policies' -f @(Get-RetentionCompliancePolicy -ErrorAction Stop).Count
        }
        Teams = {
            Connect-MicrosoftTeams -TenantId $tenantId -ApplicationId $clientId -CertificateThumbprint $thumbprint -ErrorAction Stop | Out-Null
            [string](Get-TcProperty (Get-CsTenant -ErrorAction Stop) 'DisplayName')
        }
    }

    $attempts = 6
    foreach ($key in $tests.Keys) {
        if ($key -notin $Service) { continue }
        $answer = $null
        $failure = ''
        for ($attempt = 1; $attempt -le $attempts -and $null -eq $answer; $attempt++) {
            try { $answer = [string](& $tests[$key] | Select-Object -Last 1) }
            catch {
                $failure = ($_.Exception.Message -split "`n")[0]
                if ($attempt -lt $attempts) {
                    Write-TcMessage -Message "$name, ${key}: not ready ($failure). Trying again in 30 s."
                    Start-Sleep -Seconds 30
                }
            }
        }
        $result = if ($null -ne $answer) { "OK - $answer" } else { "Failed - $failure" }
        [pscustomobject]@{ Tenant = $name; Service = $key; Result = $result }
    }

    try { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null } catch { Write-Verbose 'No Teams session to close.' }
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue } catch { Write-Verbose 'No Exchange session to close.' }
    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

    if ('Pnp' -in $Service -and @(Get-TcProperty $auth 'grants') -contains 'SharePoint') {
        $code = @'
param($Url, $ClientId, $Thumbprint, $Domain)
try {
    $connection = Connect-PnPOnline -Url $Url -ClientId $ClientId -Thumbprint $Thumbprint -Tenant $Domain -ReturnConnection -ErrorAction Stop
    'OK - sharing ' + [string](Get-PnPTenant -Connection $connection -ErrorAction Stop).SharingCapability
}
catch { 'Failed - ' + ($_.Exception.Message -split "`n")[0] }
'@
        $file = Join-Path ([System.IO.Path]::GetTempPath()) ('tc-verify-pnp-{0}.ps1' -f [guid]::NewGuid())
        try {
            Set-Content -LiteralPath $file -Value $code -Encoding UTF8
            $url = Get-TcProperty $auth 'sharePointAdminUrl'
            if (-not $url) { $url = 'https://{0}-admin.sharepoint.com' -f ($domain -split '\.')[0] }
            $result = ''
            for ($attempt = 1; $attempt -le 4; $attempt++) {
                $result = [string](& pwsh -NoProfile -File $file -Url $url -ClientId $clientId -Thumbprint $thumbprint -Domain $domain | Select-Object -Last 1)
                if ($result -like 'OK*') { break }
                Start-Sleep -Seconds 30
            }
            [pscustomobject]@{ Tenant = $name; Service = 'SharePoint'; Result = $result }
        }
        finally {
            Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
        }
    }
}

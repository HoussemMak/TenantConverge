# Stand-ins for every service command the module calls directly in these tests. A function wins over
# a cmdlet of the same name, so an installed Microsoft module is never reached. A test mocks the stubs
# it expects. Anything else stops the test instead of touching a tenant.

function global:Connect-MgGraph {
    [CmdletBinding()]
    param($TenantId, $ClientId, $CertificateThumbprint, [string[]]$Scopes, [switch]$NoWelcome, $ContextScope, [switch]$UseDeviceCode)
    throw 'Unmocked call: Connect-MgGraph'
}

function global:Disconnect-MgGraph { [CmdletBinding()] param() throw 'Unmocked call: Disconnect-MgGraph' }

function global:Get-MgContext { [CmdletBinding()] param() throw 'Unmocked call: Get-MgContext' }

function global:Invoke-MgGraphRequest {
    [CmdletBinding()]
    param($Method, $Uri, $Body, $ContentType, $OutputType, $OutputFilePath, $Headers)
    throw "Unmocked call: Invoke-MgGraphRequest $Method $Uri"
}

function global:Invoke-RestMethod {
    [CmdletBinding()]
    param($Uri, $TimeoutSec, $Method, $Body, $Headers)
    throw "Unmocked call: Invoke-RestMethod $Uri"
}

function global:Connect-ExchangeOnline {
    [CmdletBinding()]
    param($AppId, $CertificateThumbprint, $Organization, $UserPrincipalName, [switch]$ShowBanner)
    throw 'Unmocked call: Connect-ExchangeOnline'
}

function global:Disconnect-ExchangeOnline {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    throw 'Unmocked call: Disconnect-ExchangeOnline'
}

function global:Get-AcceptedDomain { [CmdletBinding()] param() throw 'Unmocked call: Get-AcceptedDomain' }

function global:Connect-IPPSSession {
    [CmdletBinding()]
    param($AppId, $CertificateThumbprint, $Organization, $UserPrincipalName, [switch]$ShowBanner)
    throw 'Unmocked call: Connect-IPPSSession'
}

function global:Get-ConnectionInformation { [CmdletBinding()] param() throw 'Unmocked call: Get-ConnectionInformation' }

function global:Connect-MicrosoftTeams {
    [CmdletBinding()]
    param($TenantId, $ApplicationId, $CertificateThumbprint, [switch]$DisableWAM)
    throw 'Unmocked call: Connect-MicrosoftTeams'
}

function global:Disconnect-MicrosoftTeams { [CmdletBinding()] param() throw 'Unmocked call: Disconnect-MicrosoftTeams' }

function global:Get-CsTenant { [CmdletBinding()] param() throw 'Unmocked call: Get-CsTenant' }

function global:Connect-PnPOnline {
    [CmdletBinding()]
    param($Url, $ClientId, $Thumbprint, $Tenant, [switch]$Interactive, [switch]$ReturnConnection)
    throw 'Unmocked call: Connect-PnPOnline'
}

function global:Disconnect-PnPOnline { [CmdletBinding()] param() throw 'Unmocked call: Disconnect-PnPOnline' }

function global:Get-OrganizationConfig { [CmdletBinding()] param() throw 'Unmocked call: Get-OrganizationConfig' }

function global:Get-RetentionCompliancePolicy { [CmdletBinding()] param() throw 'Unmocked call: Get-RetentionCompliancePolicy' }

function global:New-SelfSignedCertificate {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    throw 'Unmocked call: New-SelfSignedCertificate'
}

function Remove-TcServiceStub {
    $names = 'Connect-MgGraph', 'Disconnect-MgGraph', 'Get-MgContext', 'Invoke-MgGraphRequest', 'Invoke-RestMethod',
        'Connect-ExchangeOnline', 'Disconnect-ExchangeOnline', 'Get-AcceptedDomain', 'Connect-IPPSSession', 'Get-ConnectionInformation',
        'Connect-MicrosoftTeams', 'Disconnect-MicrosoftTeams', 'Get-CsTenant', 'Connect-PnPOnline', 'Disconnect-PnPOnline',
        'Get-OrganizationConfig', 'Get-RetentionCompliancePolicy', 'New-SelfSignedCertificate'
    foreach ($name in $names) { Remove-Item -Path "Function:\$name" -ErrorAction SilentlyContinue }
}

function New-TcTestProject {
    <# Writes a fictional project file and returns its path. #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [ValidateSet('Browser', 'Application')][string]$Mode = 'Browser',
        [ValidateRange(1, 4)][int]$SourceCount = 1
    )

    $names = 'Alpine Group', 'Birch Partners', 'Cedar Services', 'Dune Trading'
    $sources = for ($i = 0; $i -lt $SourceCount; $i++) {
        [ordered]@{
            role          = "S$($i + 1)"
            displayName   = $names[$i]
            primaryDomain = ($names[$i] -split ' ')[0].ToLowerInvariant() + '.example'
            tenantId      = $null
            wave          = 1
        }
    }

    $project = [ordered]@{
        schemaVersion = 1
        name          = 'Summit consolidation'
        target        = [ordered]@{ displayName = 'Summit Holdings'; primaryDomain = 'summit.example'; tenantId = $null; state = 'Production' }
        sources       = @($sources)
        access        = [ordered]@{ mode = $Mode }
        output        = [ordered]@{ path = (Join-Path $Folder 'output') }
        team          = @()
    }

    $path = Join-Path $Folder 'project.json'
    $project | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    $path
}

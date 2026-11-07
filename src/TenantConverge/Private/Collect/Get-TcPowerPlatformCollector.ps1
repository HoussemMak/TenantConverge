function Get-TcPowerPlatformCollector {
    <#
    .SYNOPSIS
    Lists the Power Platform collectors, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @(
        @{
            Id       = 'POW-01'
            Workload = 'Power Platform'
            Title    = 'Environments, apps, flows and DLP'
            Service  = 'PowerPlatform'
            Collect  = {
                param($Role)
                $tenant = $script:TcTenants[$Role]
                $code = @'
param($TenantId, $OutFile, $ClientId, $Thumbprint)
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerApps.Administration.PowerShell
if ($ClientId) { Add-PowerAppsAccount -Endpoint prod -TenantID $TenantId -ApplicationId $ClientId -CertificateThumbprint $Thumbprint | Out-Null }
else { Add-PowerAppsAccount -TenantID $TenantId | Out-Null }
$result = [ordered]@{ errors = @() }
try { $result.environments = @(Get-AdminPowerAppEnvironment | ForEach-Object { [ordered]@{ Name = $_.DisplayName; Id = $_.EnvironmentName; Type = [string]$_.EnvironmentType; Region = $_.Location; IsDefault = [bool]$_.IsDefault; Dataverse = [string]$_.CommonDataServiceDatabaseType; Created = [string]$_.CreatedTime } }) } catch { $result.errors += "Environments: $($_.Exception.Message)" }
try { $result.apps = @(Get-AdminPowerApp | ForEach-Object { [ordered]@{ Name = $_.DisplayName; Environment = $_.EnvironmentName; Owner = [string]$_.Owner.email; Modified = [string]$_.LastModifiedTime } }) } catch { $result.errors += "Apps: $($_.Exception.Message)" }
try { $result.flows = @(Get-AdminFlow | ForEach-Object { [ordered]@{ Name = $_.DisplayName; Environment = $_.EnvironmentName; Owner = [string]$_.CreatedBy.userId; Enabled = [bool]$_.Enabled; Modified = [string]$_.LastModifiedTime } }) } catch { $result.errors += "Flows: $($_.Exception.Message)" }
try { $result.dlp = @((Get-DlpPolicy).value | ForEach-Object { [ordered]@{ Name = $_.displayName; Scope = [string]$_.environmentType; Environments = @($_.environments | ForEach-Object { $_.name }) -join ', ' } }) } catch { $result.errors += "DLP: $($_.Exception.Message)" }
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8
'@
                $file = Join-Path ([System.IO.Path]::GetTempPath()) ('tc-power-{0}.ps1' -f [guid]::NewGuid())
                $json = "$file.json"
                try {
                    Set-Content -LiteralPath $file -Value $code -Encoding UTF8
                    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file, '-TenantId', $tenant['tenantId'], '-OutFile', $json)
                    if (Test-TcApplicationGrant -Tenant $tenant -Grant 'PowerPlatform') {
                        $auth = Get-TcApplicationAuth -Tenant $tenant
                        $arguments += @('-ClientId', $auth['clientId'], '-Thumbprint', $auth['thumbprint'])
                        $how = 'management application, no window'
                    }
                    else {
                        Assert-TcInteractiveAllowed -Service 'Power Platform' -Domain $tenant['primaryDomain']
                        $how = 'sign-in window'
                    }
                    Write-TcMessage -Message "Power Platform connects in Windows PowerShell 5.1 ($how)."
                    & powershell.exe @arguments | Out-Null
                    if (-not (Test-Path -LiteralPath $json)) { throw 'No result from Windows PowerShell: the sign-in was cancelled or the module failed.' }
                    $result = Read-TcJsonFile -Path $json
                }
                finally {
                    Remove-Item -LiteralPath $file, $json -ErrorAction SilentlyContinue
                }

                foreach ($problem in @(Get-TcProperty $result 'errors' @())) { Add-TcCollectorWarning 'Power Platform' $problem }
                $environments = @{}
                foreach ($environment in @(Get-TcProperty $result 'environments' @())) { $environments[$environment['Id']] = $environment['Name'] }
                $users = @{}
                foreach ($user in Get-TcTable 'users') { $users[(Get-TcProperty $user 'Id')] = Get-TcProperty $user 'UPN' }

                if ($result.Contains('environments')) {
                    Add-TcTable 'powerEnvironments' @(foreach ($environment in @($result['environments'])) {
                            [ordered]@{
                                'Name'      = $environment['Name']
                                'Type'      = $environment['Type']
                                'Region'    = $environment['Region']
                                'Default'   = $environment['IsDefault']
                                'Dataverse' = [bool]($environment['Dataverse'] -and $environment['Dataverse'] -ne 'None')
                                'Created'   = $environment['Created']
                            }
                        })
                }
                if ($result.Contains('apps')) {
                    Add-TcTable 'powerApps' @(foreach ($app in @($result['apps'])) {
                            [ordered]@{
                                'Name'        = $app['Name']
                                'Environment' = $environments[$app['Environment']]
                                'Owner'       = $app['Owner']
                                'Modified'    = $app['Modified']
                            }
                        })
                }
                if ($result.Contains('flows')) {
                    Add-TcTable 'powerFlows' @(foreach ($flow in @($result['flows'])) {
                            $owner = $flow['Owner']
                            [ordered]@{
                                'Name'        = $flow['Name']
                                'Environment' = $environments[$flow['Environment']]
                                'Owner'       = $(if ($users[$owner]) { $users[$owner] } else { $owner })
                                'Enabled'     = $flow['Enabled']
                                'Modified'    = $flow['Modified']
                            }
                        })
                }
                if ($result.Contains('dlp')) {
                    Add-TcTable 'powerDlpPolicies' @(foreach ($policy in @($result['dlp'])) {
                            [ordered]@{ 'Name' = $policy['Name']; 'Scope' = $policy['Scope']; 'Environments' = $policy['Environments'] }
                        })
                }
            }
        }
    )
}

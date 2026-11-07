function Get-TcAzureCollector {
    <#
    .SYNOPSIS
    Lists the Azure collectors, in the order they run.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    @(
        @{
            Id       = 'AZR-01'
            Workload = 'Azure'
            Title    = 'Subscriptions, resources, RBAC and Azure Virtual Desktop'
            Service  = 'Azure'
            Collect  = {
                param($Role)
                # A separate process: Az.Accounts and Microsoft.Graph load different versions of MSAL.
                $tenant = $script:TcTenants[$Role]
                $code = @'
param($TenantId, $OutFile, $ClientId, $Thumbprint)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts, Az.Resources
if ($ClientId) { Connect-AzAccount -ServicePrincipal -ApplicationId $ClientId -CertificateThumbprint $Thumbprint -Tenant $TenantId -WarningAction SilentlyContinue | Out-Null }
else { Connect-AzAccount -Tenant $TenantId -WarningAction SilentlyContinue | Out-Null }
$result = [ordered]@{ subscriptions = @(); resources = @(); errors = @() }
foreach ($subscription in @(Get-AzSubscription -TenantId $TenantId -WarningAction SilentlyContinue)) {
    $assignments = $null
    try {
        Set-AzContext -SubscriptionId $subscription.Id -Tenant $TenantId -WarningAction SilentlyContinue | Out-Null
        foreach ($group in @(Get-AzResource) | Group-Object ResourceType) {
            $result.resources += [ordered]@{ Subscription = $subscription.Name; Type = $group.Name; Count = $group.Count; Regions = ((@($group.Group | ForEach-Object Location) | Sort-Object -Unique) -join ', ') }
        }
        $assignments = @(Get-AzRoleAssignment -Scope "/subscriptions/$($subscription.Id)" -WarningAction SilentlyContinue).Count
    }
    catch { $result.errors += "Subscription $($subscription.Name): $($_.Exception.Message)" }
    $result.subscriptions += [ordered]@{ Name = $subscription.Name; Id = $subscription.Id; State = [string]$subscription.State; Assignments = $assignments }
}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutFile -Encoding UTF8
'@
                $file = Join-Path ([System.IO.Path]::GetTempPath()) ('tc-azure-{0}.ps1' -f [guid]::NewGuid())
                $json = "$file.json"
                $auth = Get-TcApplicationAuth -Tenant $tenant
                try {
                    Set-Content -LiteralPath $file -Value $code -Encoding UTF8
                    $arguments = @('-NoProfile', '-File', $file, '-TenantId', $tenant['tenantId'], '-OutFile', $json)
                    # With the application there is never a window: without the Reader role it just sees no subscription.
                    if ($auth) {
                        $arguments += @('-ClientId', $auth['clientId'], '-Thumbprint', $auth['thumbprint'])
                        $how = 'read-only application, no window'
                    }
                    else {
                        Assert-TcInteractiveAllowed -Service 'Azure' -Domain $tenant['primaryDomain']
                        $how = 'sign-in window'
                    }
                    Write-TcMessage -Message "Azure connects in a separate process ($how)."
                    & pwsh @arguments | Out-Null
                    if (-not (Test-Path -LiteralPath $json)) { throw 'No Azure result: the sign-in was cancelled or there is no access to subscriptions.' }
                    $result = Read-TcJsonFile -Path $json
                }
                finally {
                    Remove-Item -LiteralPath $file, $json -ErrorAction SilentlyContinue
                }

                foreach ($problem in @(Get-TcProperty $result 'errors' @())) { Add-TcCollectorWarning 'Azure' $problem }

                $subscriptions = @(Get-TcProperty $result 'subscriptions' @())
                if ($subscriptions.Count -eq 0) {
                    # No subscription visible cannot be told from no subscription, so this never reads as a service not used.
                    $reason = if (Test-TcApplicationGrant -Tenant $tenant -Grant 'Azure') { 'The read-only application sees no subscription, although it received the Reader role on the visible ones.' }
                    elseif ($auth) { 'The read-only application sees no subscription: it has no Azure role.' }
                    else { 'No subscription is visible: the tenant has none, or the account has no Azure role.' }
                    throw "NOTCONFIGURED: $reason"
                }

                Add-TcTable 'azureSubscriptions' @(foreach ($subscription in $subscriptions) {
                        [ordered]@{ 'Name' = $subscription['Name']; 'Id' = $subscription['Id']; 'State' = $subscription['State']; 'RBAC assignments' = $subscription['Assignments'] }
                    })
                Add-TcTable 'azureResources' @(foreach ($resource in @(Get-TcProperty $result 'resources' @())) {
                        [ordered]@{ 'Subscription' = $resource['Subscription']; 'Type' = $resource['Type']; 'Count' = $resource['Count']; 'Regions' = $resource['Regions'] }
                    })
            }
        }
    )
}

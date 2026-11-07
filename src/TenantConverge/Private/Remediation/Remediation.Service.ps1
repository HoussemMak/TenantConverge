function Get-TcRemediationNow {
    <#
    .SYNOPSIS
    The time, for the waits of a remediation.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param()

    Get-Date
}

function Wait-TcRemediation {
    <#
    .SYNOPSIS
    Pauses a remediation.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Seconds
    )

    Start-Sleep -Seconds $Seconds
}

function Get-TcRemediationScope {
    <#
    .SYNOPSIS
    The Graph permissions of the running script, and nothing else.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @($script:TcRemediationRun['Entry']['permissions'] | Sort-Object -Unique)
}

function Assert-TcRemediationCall {
    <#
    .SYNOPSIS
    Refuses a connection in preview, and a write to a tenant whose primary domain a person did not type.

    .DESCRIPTION
    A write that goes through is added to the action that runs, so the journal says where it really went.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$What,
        [Parameter(Mandatory)][string]$Tenant,
        [switch]$Write
    )

    $run = $script:TcRemediationRun
    if (-not $run['Apply']) { throw "Refused in preview: $What. A preview reads the snapshot only." }
    if (-not $Write) { return }
    if (-not @($run['ConfirmedTenants']).Count) { throw "Write refused before the confirmation: $What. A write belongs in an action of the plan." }
    if ($Tenant -notin $run['ConfirmedTenants']) { throw "Write refused on $Tenant, whose primary domain nobody typed: $What. An action that writes to a second tenant declares it with -AlsoWrites." }
    $action = $run['CurrentAction']
    if ($action -and $Tenant -notin @($action['written'])) { $action['written'] = @($action['written']) + $Tenant }
}

function Assert-TcServiceFamily {
    <#
    .SYNOPSIS
    Refuses to mix Exchange, Teams and PnP in one process: together they stop PowerShell.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Service
    )

    $run = $script:TcRemediationRun
    $family = @{ Exo = 'Exchange'; Scc = 'Exchange'; Teams = 'Teams'; Pnp = 'Pnp' }[$Service]
    if ($run['Family'] -and $run['Family'] -ne $family) { throw "A script cannot mix the $($run['Family']) and $family modules in one process." }
    $run['Family'] = $family
}

function Connect-TcRemediationService {
    <#
    .SYNOPSIS
    Signs a person in to a service of a tenant, with only the permissions of the script.

    .DESCRIPTION
    Never uses the read-only application, which stays read-only. Each connection is checked, as the
    assessment does: a session on another tenant is refused.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][string]$Service,
        [string]$Url
    )

    $run = $script:TcRemediationRun
    $info = Get-TcRemediationTenant -Tenant $Tenant
    $sessions = $run['Connections']

    switch ($Service) {
        'Graph' {
            if ($sessions['Graph'] -eq $Tenant) { return }
            if ($sessions['Graph']) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
            $scopes = @(Get-TcRemediationScope)
            if (-not $scopes.Count) { $scopes = @('Organization.Read.All') }
            Connect-MgGraph -TenantId $info['TenantId'] -Scopes $scopes -NoWelcome -ErrorAction Stop
            $organization = @(Get-TcProperty (Invoke-TcGraphTransport -Method GET -Url 'https://graph.microsoft.com/v1.0/organization') 'value') | Select-Object -First 1
            if ([string](Get-TcProperty $organization 'id') -ne [string]$info['TenantId']) {
                Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
                throw "Connected to the wrong tenant instead of $($info['TenantId']) ($Tenant)."
            }
            $sessions['Graph'] = $Tenant
        }
        'Exo' {
            if ($sessions['Exo'] -eq $Tenant) { return }
            if ($sessions['Exo'] -or $sessions['Scc']) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue; $sessions['Scc'] = $null }
            Connect-ExchangeOnline -Organization $info['InitialDomain'] -ShowBanner:$false -ErrorAction Stop
            if (-not @(Get-AcceptedDomain -ErrorAction Stop | Where-Object { [string](Get-TcProperty $_ 'DomainName') -eq $info['InitialDomain'] }).Count) {
                Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
                throw "Exchange Online connected to the wrong tenant: $($info['InitialDomain']) is not an accepted domain ($Tenant)."
            }
            $sessions['Exo'] = $Tenant
        }
        'Scc' {
            if ($sessions['Scc'] -eq $Tenant) { return }
            if ($sessions['Exo'] -or $sessions['Scc']) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue; $sessions['Exo'] = $null }
            Connect-IPPSSession -ShowBanner:$false -ErrorAction Stop
            $session = @(Get-ConnectionInformation -ErrorAction Stop) | Where-Object { [string](Get-TcProperty $_ 'ConnectionUri') -match 'compliance' } | Select-Object -Last 1
            if ([string](Get-TcProperty $session 'TenantID') -ne [string]$info['TenantId']) {
                Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
                throw "Purview connected to the wrong tenant instead of $($info['TenantId']) ($Tenant)."
            }
            $sessions['Scc'] = $Tenant
        }
        'Teams' {
            if ($sessions['Teams'] -eq $Tenant) { return }
            if ($sessions['Teams']) { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null }
            Connect-MicrosoftTeams -TenantId $info['TenantId'] -ErrorAction Stop | Out-Null
            if ([string](Get-TcProperty (Get-CsTenant -ErrorAction Stop) 'TenantId') -ne [string]$info['TenantId']) {
                Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null
                throw "Teams connected to the wrong tenant instead of $($info['TenantId']) ($Tenant)."
            }
            $sessions['Teams'] = $Tenant
        }
        'Pnp' {
            $adminUrls = Get-TcRemediationOption 'SharePointAdminUrl'
            $site = if ($Url) { $Url } elseif ($adminUrls.ContainsKey($Tenant)) { $adminUrls[$Tenant] } else { 'https://{0}-admin.sharepoint.com' -f ($info['InitialDomain'] -split '\.')[0] }
            $clientId = Get-TcRemediationOption 'PnpClientId'
            if (-not $clientId) { throw 'SharePoint needs the client ID of a PnP application: set PnpClientId in the remediation settings.' }
            if (-not $sessions.ContainsKey("Pnp|$site")) {
                # -ReturnConnection leaves the current connection alone, and Disconnect-PnPOnline takes no connection: a refused one is dropped.
                $connection = Connect-PnPOnline -Url $site -ClientId $clientId -Interactive -ReturnConnection -ErrorAction Stop
                if ([string](Get-PnPTenantId -Connection $connection -ErrorAction Stop) -ne [string]$info['TenantId']) { throw "SharePoint connected to the wrong tenant instead of $($info['TenantId']) ($Tenant): $site." }
                $sessions["Pnp|$site"] = $connection
            }
            return $sessions["Pnp|$site"]
        }
    }
    $null
}

function Disconnect-TcRemediationService {
    <#
    .SYNOPSIS
    Ends the sessions of the run.
    #>
    [CmdletBinding()]
    param()

    $sessions = $script:TcRemediationRun['Connections']
    if ($sessions['Graph']) { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
    if ($sessions['Exo'] -or $sessions['Scc']) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue }
    if ($sessions['Teams']) { Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null }
    $sessions.Clear()
}

function Invoke-TcGraphTransport {
    <#
    .SYNOPSIS
    The only call to Microsoft Graph of the remediations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        $Body,
        [hashtable]$Headers = @{}
    )

    $request = @{ Method = $Method; Uri = $Url; OutputType = 'Hashtable'; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $request['Body'] = $Body | ConvertTo-Json -Depth 30 -Compress; $request['ContentType'] = 'application/json' }
    if ($Headers.Count) { $request['Headers'] = $Headers }
    Invoke-MgGraphRequest @request
}

function Send-TcGraphRequest {
    <#
    .SYNOPSIS
    One Graph request, with retries. Retry-After is respected.

    .DESCRIPTION
    A 429 ran nothing, so any request is retried. After a 503, a 504 or a cut connection a write may have
    gone through, so only idempotent requests are retried, never a POST or a DELETE.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        $Body,
        [hashtable]$Headers = @{}
    )

    $idempotent = $Method -in 'GET', 'PUT', 'PATCH'
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try { return (Invoke-TcGraphTransport -Method $Method -Url $Url -Body $Body -Headers $Headers) }
        catch {
            $text = Get-TcErrorText -ErrorInput $_
            $status = [int](Get-TcProperty (Get-TcProperty $_.Exception 'Response') 'StatusCode' 0)
            if (-not $status -and $text -match '\b(4\d\d|5\d\d)\b') { $status = [int]$Matches[1] }
            $again = $status -eq 429 -or ($idempotent -and $status -in 503, 504)
            if ($again -and $attempt -lt 6) { Wait-TcRemediation -Seconds (Get-TcRetryDelay -ErrorRecord $_ -Attempt $attempt); continue }
            if (-not $status -and -not $idempotent) { throw ("Graph {0} {1} gave no answer: the write may have gone through. Check the tenant before running it again ({2})." -f $Method, $Url, $text) }
            throw ('Graph {0} {1} answered {2}: {3}' -f $Method, $Url, $status, $text)
        }
    }
}

function Invoke-TcGraph {
    <#
    .SYNOPSIS
    A Graph call of a remediation. Any method but GET is refused before the confirmation.

    .PARAMETER All
    Follows the pages and returns the whole list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        $Body,
        [switch]$All,
        [hashtable]$Headers = @{}
    )

    Assert-TcRemediationCall -What "Graph $Method $Uri" -Tenant $Tenant -Write:($Method -ne 'GET')
    [void](Connect-TcRemediationService -Tenant $Tenant -Service Graph)
    $url = if ($Uri -match '^https://') { $Uri } else { "https://graph.microsoft.com/$Uri" }
    if (-not $All) { return (Send-TcGraphRequest -Method $Method -Url $url -Body $Body -Headers $Headers) }
    $items = [System.Collections.Generic.List[object]]::new()
    while ($url) {
        $page = Send-TcGraphRequest -Method $Method -Url $url -Body $Body -Headers $Headers
        foreach ($value in @(Get-TcProperty $page 'value')) { if ($null -ne $value) { $items.Add($value) } }
        $url = Get-TcProperty $page '@odata.nextLink'
    }
    $items.ToArray()
}

function Invoke-TcCommandTransport {
    <#
    .SYNOPSIS
    The only call to a cmdlet of a service.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Parameters = @{},
        $Connection
    )

    $copy = @{}
    foreach ($key in @($Parameters.Keys)) { $copy[$key] = $Parameters[$key] }
    if ((Get-Command $Command -ErrorAction Stop).Parameters.ContainsKey('Confirm')) { $copy['Confirm'] = $false }
    if ($Service -eq 'Pnp') { $copy['Connection'] = $Connection }
    & $Command @copy -ErrorAction Stop
}

function Get-TcCommandParameter {
    <#
    .SYNOPSIS
    The parameters of a service command, once its module is loaded.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string]$Command
    )

    (Get-Command -Name $Command -ErrorAction Stop).Parameters
}

function Invoke-TcServiceCommand {
    <#
    .SYNOPSIS
    Runs a cmdlet on a tenant. Only a Get- or an Export-, which read, run without a confirmed domain.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Tenant,
        [Parameter(Mandatory)][ValidateSet('Exo', 'Scc', 'Teams', 'Pnp')][string]$Service,
        [Parameter(Mandatory)][string]$Command,
        [hashtable]$Parameters = @{},
        [string]$Url
    )

    Assert-TcRemediationCall -What "$Command on $Tenant" -Tenant $Tenant -Write:($Command -notmatch '^(Get|Export)-')
    Assert-TcServiceFamily -Service $Service
    $connection = Connect-TcRemediationService -Tenant $Tenant -Service $Service -Url $Url
    Invoke-TcCommandTransport -Service $Service -Command $Command -Parameters $Parameters -Connection $connection
}

function Get-TcEmergencyAccount {
    <#
    .SYNOPSIS
    The emergency accounts of the target, from the remediation settings.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $domain = Get-TcRemediationOption 'EmergencyAccountDomain'
    if (-not $domain) { $domain = (Get-TcRemediationTenant -Tenant 'Target')['InitialDomain'] }
    $prefix = Get-TcRemediationOption 'EmergencyAccountPrefix'
    @(1..[int](Get-TcRemediationOption 'EmergencyAccountCount') | ForEach-Object { '{0}{1}@{2}' -f $prefix, $_, $domain })
}

function Test-TcProtectedAccount {
    <#
    .SYNOPSIS
    An emergency account, a kept account or an account of the migration team. A script never touches these.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][AllowEmptyString()][string]$Account,
        [Parameter(Position = 1)]$Info
    )

    $migration = Get-TcRemediationOption 'MigrationAccountPattern'
    $Account -match (Get-TcRemediationOption 'ProtectedAccountPattern') -or ($Info -and $Account -in @($Info['KeptAccounts'])) -or ($migration -and $Account -match $migration)
}

function Get-TcProtectedAccount {
    <#
    .SYNOPSIS
    The accounts of a tenant no script may touch.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant
    )

    if ($Tenant -eq 'Target') { return @(Get-TcEmergencyAccount) }
    $info = Get-TcRemediationTenant -Tenant $Tenant
    $found = @(Get-TcRemediationTable $Tenant 'users' | Where-Object { Test-TcProtectedAccount -Account ([string]$_['UPN']) } | ForEach-Object { $_['UPN'] })
    @(@($found) + @($info['KeptAccounts']) | Where-Object { $_ -and $_ -notmatch '^<' } | Select-Object -Unique)
}

function Get-TcMissingProtectedAccount {
    <#
    .SYNOPSIS
    The protected accounts missing from the snapshot, or disabled.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant
    )

    $enabled = @(Get-TcRemediationTable $Tenant 'users' | Where-Object { ConvertTo-TcBoolean $_['Enabled'] } | ForEach-Object { $_['UPN'] })
    @(Get-TcProtectedAccount $Tenant | Where-Object { $_ -notin $enabled })
}

function Test-TcTargetDomain {
    <#
    .SYNOPSIS
    True when Exchange accepts a domain in the target. Read once per run.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Domain
    )

    $run = $script:TcRemediationRun
    if ($null -eq $run['AcceptedDomains']) { $run['AcceptedDomains'] = @(Invoke-TcServiceCommand -Tenant 'Target' -Service Exo -Command 'Get-AcceptedDomain' | ForEach-Object { ([string](Get-TcProperty $_ 'DomainName')).ToLowerInvariant() }) }
    $Domain.ToLowerInvariant() -in $run['AcceptedDomains']
}

function Test-TcTenantDomain {
    <#
    .SYNOPSIS
    True when a domain is present in a tenant.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant,
        [Parameter(Mandatory, Position = 1)][string]$Domain
    )

    [bool]@(Invoke-TcGraph -Tenant $Tenant -Uri 'v1.0/domains' -All | Where-Object { (Get-TcProperty $_ 'id') -eq $Domain }).Count
}

function Test-TcGraphAbsent {
    <#
    .SYNOPSIS
    True when Graph answers 404: the object is gone.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, Position = 0)][string]$Tenant,
        [Parameter(Mandatory, Position = 1)][string]$Uri
    )

    try { [void](Invoke-TcGraph -Tenant $Tenant -Uri $Uri); return $false }
    catch { if ((Get-TcErrorText -ErrorInput $_) -match 'answered 404') { return $true }; throw }
}

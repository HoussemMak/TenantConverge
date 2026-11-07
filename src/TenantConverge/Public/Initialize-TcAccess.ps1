function Initialize-TcAccess {
    <#
    .SYNOPSIS
    Creates the read-only application in the tenants of a project, for assessments without a sign-in window.

    .DESCRIPTION
    For each tenant, once per tenant with a Global Administrator:

      1. creates a self-signed certificate in the store of the current user, once, with a CSP key that
         cannot be exported, because Exchange Online refuses CNG keys;
      2. creates the TenantConverge Read-Only application, or reuses the one this project created, and
         adds the certificate;
      3. requests read-only permissions: Microsoft Graph, and Exchange.ManageAsApp for Exchange Online
         and Purview;
      4. with -GrantAdminConsent only: grants those permissions and the Global Reader role;
      5. saves the identifiers in <project>.access.local.json, never in project.json.

    It stops, and changes nothing in that tenant, when an application of that name exists that this
    project did not create, or when the application holds a credential TenantConverge did not add.

    Extended access needs the written agreement of the customer:

      SharePoint     Sites.FullControl.All. It is the only application permission that opens SharePoint
                     administration. TenantConverge only reads with it.
      PowerPlatform  Registers the application for Power Platform management. One more sign-in per tenant.
      Azure          Reader role on each subscription the account can see. One more sign-in per tenant.

    It writes to the tenant: the application, its certificate, its permissions and its role, nothing else.
    Apart from this command and Remove-TcAccess, only Invoke-TcRemediation and Undo-TcRemediation write to a
    tenant, when you run them with -Apply. Use -WhatIf to see what it would do, -Verify to test connections
    without creating anything, and Remove-TcAccess at the end of the project.

    .PARAMETER Project
    The project file.

    .PARAMETER Tenant
    The roles to prepare. The default is the target and every source.

    .PARAMETER ExtendedAccess
    SharePoint, PowerPlatform, Azure, or None. Without this parameter, a tenant keeps what it has.

    .PARAMETER CertificateMonths
    How long the certificate stays valid. The default is 6 months.

    .PARAMETER GrantAdminConsent
    Grants the permissions on behalf of the organization. Without it, the application is created without
    consent, and the command shows the consent address for an administrator.

    .PARAMETER DelegatedPnP
    Registers a delegated PnP application. Use it when the customer refuses SharePoint extended access:
    each SharePoint read then opens a sign-in window. In a Browser project, that is all this command does:
    no certificate and no read-only application. In an Application project, it comes on top of them.

    .PARAMETER UseDeviceCode
    Signs in with a device code instead of a browser window.

    .PARAMETER Verify
    Only tests the connection to each service, tenant by tenant.

    .PARAMETER Service
    The services -Verify tests.

    .EXAMPLE
    Initialize-TcAccess -Project ./project.json -GrantAdminConsent

    Creates the application in every tenant and grants its read permissions.

    .EXAMPLE
    Initialize-TcAccess -Project ./project.json -ExtendedAccess SharePoint, PowerPlatform -GrantAdminConsent

    Adds the extended access the customer agreed to.

    .EXAMPLE
    Initialize-TcAccess -Project ./project.json -Verify

    Tests each connection and creates nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$Project,
        [ValidateSet('Target', 'S1', 'S2', 'S3')][string[]]$Tenant,
        [ValidateSet('SharePoint', 'PowerPlatform', 'Azure', 'None')][string[]]$ExtendedAccess,
        [ValidateRange(1, 24)][int]$CertificateMonths = 6,
        [switch]$GrantAdminConsent,
        [switch]$DelegatedPnP,
        [switch]$UseDeviceCode,
        [switch]$Verify,
        [ValidateSet('Graph', 'Exo', 'Ipps', 'Teams', 'Pnp')][string[]]$Service = @('Graph', 'Exo', 'Ipps', 'Teams', 'Pnp')
    )

    $projectPath = Resolve-TcPath -Path $Project
    $projectData = Read-TcProjectFile -Path $projectPath
    Initialize-TcSession -Project $projectData -Access (Read-TcAccessFile -ProjectPath $projectPath)
    $chosen = @(if ($Tenant) { $Tenant | Where-Object { $script:TcTenants.Contains($_) } } else { $script:TcTenants.Keys })
    if ($chosen.Count -eq 0) { throw 'No tenant of this project matches -Tenant.' }

    if ($Verify) {
        foreach ($role in $chosen) {
            $entry = $script:TcTenants[$role]
            if (-not $entry['tenantId']) { $entry['tenantId'] = Get-TcProperty $entry['access'] 'tenantId' }
            Test-TcTenantAccess -Tenant $entry -Service $Service
        }
        return
    }

    $requested = $null
    if ($PSBoundParameters.ContainsKey('ExtendedAccess')) { $requested = @($ExtendedAccess | Where-Object { $_ -ne 'None' }) }

    # A browser project wants no application of its own, only the PnP one that SharePoint needs.
    if ($DelegatedPnP -and (Get-TcProperty (Get-TcProperty $projectData 'access') 'mode') -ne 'Application') {
        Write-TcMessage -Message "Browser mode: only the delegated application '$script:TcPnpApplicationName' is registered, with no certificate and no read-only application."
        foreach ($role in $chosen) {
            $entry = $script:TcTenants[$role]
            if ($PSCmdlet.ShouldProcess("$($entry['displayName']) ($($entry['primaryDomain']))", "Register the application '$script:TcPnpApplicationName'")) {
                Initialize-TcDelegatedAccess -ProjectPath $projectPath -Role $role -Tenant $entry -UseDeviceCode:$UseDeviceCode
            }
        }
        return
    }

    $names = ($chosen | ForEach-Object { '{0} ({1})' -f $script:TcTenants[$_]['displayName'], $script:TcTenants[$_]['primaryDomain'] }) -join ', '
    Write-TcMessage -Message "Tenants: $names"
    Write-TcMessage -Message "Application: '$script:TcApplicationName', read-only, Global Reader role"
    Write-TcMessage -Message "Microsoft Graph (application): $((Get-TcApplicationPermission) -join ', ')"
    Write-TcMessage -Message 'Office 365 Exchange Online and Microsoft Exchange Online Protection: Exchange.ManageAsApp'

    $certificate = Get-TcReadCertificate -Months $CertificateMonths
    $succeeded = [System.Collections.Generic.List[string]]::new()

    foreach ($role in $chosen) {
        $entry = $script:TcTenants[$role]
        $label = "$($entry['displayName']) ($($entry['primaryDomain']))"
        if (-not $PSCmdlet.ShouldProcess($label, "Create or reuse the application '$script:TcApplicationName'")) { continue }

        try {
            $extended = if ($null -ne $requested) { $requested } else {
                @(Get-TcProperty $entry['access'] 'grants') | Where-Object { $_ -in 'SharePoint', 'PowerPlatform', 'Azure' }
            }
            $result = Initialize-TcTenantApplication -ProjectPath $projectPath -Role $role -Tenant $entry -Certificate $certificate -Extended @($extended) `
                -GrantAdminConsent:$GrantAdminConsent -UseDeviceCode:$UseDeviceCode
            $succeeded.Add($role)
            if ($DelegatedPnP) { Register-TcDelegatedPnP -ProjectPath $projectPath -Role $role -Tenant $entry }
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            $result
        }
        catch {
            Write-TcMessage -Message "$($entry['displayName']): $(Get-TcErrorText $_)" -Level Warning
            Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
            [pscustomobject][ordered]@{ Role = $role; Tenant = $entry['displayName']; ApplicationId = $null; Grants = @(); Consent = 'Failed' }
        }
    }

    if ($GrantAdminConsent -and $succeeded.Count -gt 0) {
        Write-TcMessage -Message 'Permissions take a few minutes to spread. Checking each service in a new session.'
        $exitCode = Invoke-TcAccessVerification -ProjectPath $projectPath -Role @($succeeded)
        if ($exitCode) { Write-TcMessage -Message "A service is not ready yet. Run Initialize-TcAccess -Project '$Project' -Verify in 15 minutes." -Level Warning }
    }
}

function Connect-TcGraphAdmin {
    <#
    .SYNOPSIS
    Delegated sign-in of a Global Administrator, limited to the scopes that register the application.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tenant,
        [Parameter(Mandatory)][string]$TenantId,
        [string[]]$Scope = @('Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All', 'RoleManagement.ReadWrite.Directory', 'Organization.Read.All'),
        [switch]$UseDeviceCode
    )

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Write-TcMessage -Message "Sign in to $($Tenant['displayName']) ($($Tenant['primaryDomain'])) with a Global Administrator account." -Level Warning
    Write-TcMessage -Message "The window can open behind this one. Do not tick 'Consent on behalf of your organization' in it: -GrantAdminConsent is how consent is given."

    $parameters = @{ TenantId = $TenantId; Scopes = $Scope; NoWelcome = $true; ContextScope = 'Process'; ErrorAction = 'Stop' }
    if ($UseDeviceCode) { $parameters['UseDeviceCode'] = $true }
    Connect-MgGraph @parameters

    $organization = @(Get-TcProperty (Invoke-TcAccessGraph -Uri 'v1.0/organization') 'value') | Select-Object -First 1
    if ([string](Get-TcProperty $organization 'id') -ne $TenantId) {
        throw "Connected to the wrong tenant: $(Get-TcProperty $organization 'id') instead of $TenantId."
    }

    $domains = @(Get-TcProperty $organization 'verifiedDomains')
    if ($Tenant['primaryDomain'] -notin @($domains | ForEach-Object { Get-TcProperty $_ 'name' })) {
        throw "$($Tenant['primaryDomain']) is not a verified domain of the connected tenant."
    }
    $initial = $domains | Where-Object { Get-TcProperty $_ 'isInitial' $false } | Select-Object -First 1
    if ($initial) { $Tenant['initialDomain'] = Get-TcProperty $initial 'name' }

    Write-TcMessage -Message "Connected: $(Get-TcProperty (Get-MgContext) 'Account')" -Level Success
}

function Invoke-TcAccessGraph {
    <#
    .SYNOPSIS
    The one Graph call of the application setup that may write.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [AllowNull()]$Body
    )

    $parameters = @{ Method = $Method; Uri = "https://graph.microsoft.com/$Uri"; OutputType = 'Hashtable'; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $parameters['Body'] = ConvertTo-Json -InputObject $Body -Depth 10
        $parameters['ContentType'] = 'application/json'
    }
    Invoke-MgGraphRequest @parameters
}

function Get-TcAccessGraphList {
    <#
    .SYNOPSIS
    Reads every page of a Graph collection during the application setup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $response = Invoke-TcAccessGraph -Uri $Uri
    while ($true) {
        foreach ($value in @(Get-TcProperty $response 'value')) {
            if ($null -ne $value) { $items.Add($value) }
        }
        $next = Get-TcProperty $response '@odata.nextLink'
        if (-not $next) { break }
        $response = Invoke-MgGraphRequest -Method GET -Uri $next -OutputType Hashtable -ErrorAction Stop
    }
    $items.ToArray()
}

function Get-TcAccessGraphFilter {
    <#
    .SYNOPSIS
    Reads a filtered Graph collection during the application setup.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Collection,
        [Parameter(Mandatory)][string]$Filter
    )

    @(Get-TcAccessGraphList -Uri ('v1.0/{0}?$filter={1}' -f $Collection, [uri]::EscapeDataString($Filter)))
}

function Test-TcCspCertificate {
    <#
    .SYNOPSIS
    Exchange Online only accepts keys from a CSP provider. A name ending in Key Storage Provider is a CNG key.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Certificate
    )

    try {
        $key = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
        $provider = if ($key -is [System.Security.Cryptography.RSACng]) { $key.Key.Provider.Provider }
        elseif ($key -is [System.Security.Cryptography.RSACryptoServiceProvider]) { $key.CspKeyContainerInfo.ProviderName }
        [bool]($provider -and $provider -notmatch 'Key Storage Provider')
    }
    catch { $false }
}

function Get-TcReadCertificate {
    <#
    .SYNOPSIS
    Returns a certificate valid for at least 30 more days, or creates one. Under -WhatIf it creates nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][int]$Months
    )

    $existing = Get-ChildItem Cert:\CurrentUser\My |
        Where-Object { $_.Subject -eq $script:TcCertificateSubject -and $_.HasPrivateKey -and $_.NotAfter -gt (Get-Date).AddDays(30) -and (Test-TcCspCertificate -Certificate $_) } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($existing) {
        Write-TcMessage -Message ('Existing certificate, expires {0:yyyy-MM-dd}.' -f $existing.NotAfter)
        return $existing
    }

    if (-not $PSCmdlet.ShouldProcess('Cert:\CurrentUser\My', "Create the certificate '$script:TcCertificateSubject' for $Months months")) { return }

    $certificate = New-SelfSignedCertificate -Subject $script:TcCertificateSubject -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 `
        -KeySpec KeyExchange -Provider 'Microsoft Enhanced RSA and AES Cryptographic Provider' -KeyExportPolicy NonExportable `
        -KeyUsage DigitalSignature, KeyEncipherment -NotAfter (Get-Date).AddMonths($Months) -FriendlyName $script:TcApplicationName
    if (-not (Test-TcCspCertificate -Certificate $certificate)) { throw 'The certificate is not in a CSP provider: Exchange Online would refuse it.' }
    Write-TcMessage -Message ('Certificate created, expires {0:yyyy-MM-dd}, key not exportable.' -f $certificate.NotAfter) -Level Success
    $certificate
}

function Get-TcResourcePrincipal {
    <#
    .SYNOPSIS
    Finds the service principal of a Microsoft resource, and creates it when the tenant has none yet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Resource
    )

    $principal = @(Get-TcAccessGraphFilter -Collection 'servicePrincipals' -Filter "appId eq '$($Resource['AppId'])'") | Select-Object -First 1
    if ($principal) { return $principal }

    # A Microsoft application can be missing from a tenant, often Exchange Online Protection.
    try { Invoke-TcAccessGraph -Method POST -Uri 'v1.0/servicePrincipals' -Body @{ appId = $Resource['AppId'] } }
    catch { Write-TcMessage -Message "$($Resource['Name']) was not found in this tenant: $(Get-TcErrorText $_)" -Level Warning }
}

function Get-TcApplicationRoleId {
    <#
    .SYNOPSIS
    Reads the IDs of application roles from a resource, so no ID is hard-coded.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowNull()]$Principal,
        [string[]]$Value,
        [string]$ResourceName
    )

    $roles = @{}
    foreach ($name in $Value) {
        $role = @(Get-TcProperty $Principal 'appRoles') |
            Where-Object { (Get-TcProperty $_ 'value') -eq $name -and @(Get-TcProperty $_ 'allowedMemberTypes') -contains 'Application' } |
            Select-Object -First 1
        if ($role) { $roles[$name] = Get-TcProperty $role 'id' }
        else { Write-TcMessage -Message "$ResourceName has no application permission $name. Skipped." -Level Warning }
    }
    $roles
}

function Invoke-TcAdminProcess {
    <#
    .SYNOPSIS
    Runs a Power Platform, Azure or PnP setup in its own process, which has its own sign-in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][hashtable]$Arguments
    )

    $file = Join-Path ([System.IO.Path]::GetTempPath()) ('tc-access-{0}.ps1' -f [guid]::NewGuid())
    $json = "$file.json"
    try {
        Set-Content -LiteralPath $file -Value $Code -Encoding UTF8
        $all = @('-NoProfile')
        if ($Executable -eq 'powershell.exe') { $all += @('-ExecutionPolicy', 'Bypass') }
        $all += @('-File', $file, '-OutFile', $json)
        foreach ($key in $Arguments.Keys) { $all += @("-$key", [string]$Arguments[$key]) }
        & $Executable @all | Out-Host
        if (-not (Test-Path -LiteralPath $json)) { throw 'No result: the sign-in was cancelled or the module failed.' }
        Read-TcJsonFile -Path $json
    }
    finally {
        Remove-Item -LiteralPath $file, $json -ErrorAction SilentlyContinue
    }
}

function Get-TcProjectApplication {
    <#
    .SYNOPSIS
    The read-only application this project created in a tenant, or nothing. Stops on one it cannot vouch for.

    .DESCRIPTION
    A name proves nothing. Anyone allowed to register an application can give one this name, and this
    command goes on to give it read access to the whole tenant. So only the ID in the access file counts,
    and a credential TenantConverge never adds stops the run too.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tenant
    )

    $named = @(Get-TcAccessGraphFilter -Collection 'applications' -Filter "displayName eq '$script:TcApplicationName'")
    if (-not $named.Count) { return }

    $known = [string](Get-TcProperty (Get-TcProperty $Tenant 'access') 'clientId')
    $application = @($named | Where-Object { $known -and $_['appId'] -eq $known }) | Select-Object -First 1
    if (-not $application) {
        $found = @($named | ForEach-Object { $_['appId'] }) -join ', '
        throw "An application named '$script:TcApplicationName' already exists ($found), and this project did not create it. Anyone can register that name, and this command would give it read access to the whole tenant, so nothing was changed. Find out who created it, delete it in Entra ID, then run this command again."
    }

    $details = Invoke-TcAccessGraph -Uri "v1.0/applications/$($application['id'])?`$select=keyCredentials,passwordCredentials"
    $foreign = @(Get-TcProperty $details 'keyCredentials' @()) | Where-Object { (Get-TcProperty $_ 'displayName') -ne $script:TcCertificateSubject }
    if (@(Get-TcProperty $details 'passwordCredentials' @()).Count -or @($foreign).Count) {
        throw "The application '$script:TcApplicationName' ($known) holds a credential TenantConverge did not add. Whoever has it can read what this application reads, so nothing was changed. Remove that credential in Entra ID, or delete the application, then run this command again."
    }

    $application
}

function Save-TcApplicationEntry {
    <#
    .SYNOPSIS
    Saves the read-only application of a tenant in the local access file, with what the file already holds for PnP.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tenant,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)]$Certificate,
        [AllowEmptyCollection()][string[]]$Grants = @()
    )

    $entry = [ordered]@{
        tenantId      = $TenantId
        initialDomain = $Tenant['initialDomain']
        clientId      = $ClientId
        thumbprint    = $Certificate.Thumbprint
        application   = $script:TcApplicationName
        grants        = @($Grants)
        expires       = $Certificate.NotAfter.ToString('yyyy-MM-dd')
        initialized   = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    }
    $previous = Get-TcProperty $Tenant 'access'
    foreach ($kept in 'pnpClientId', 'sharePointAdminUrl') {
        $value = Get-TcProperty $previous $kept
        if ($value) { $entry[$kept] = $value }
    }
    Write-TcAccessEntry -ProjectPath $ProjectPath -Role $Role -Entry $entry
    $Tenant['access'] = $entry
}

function Initialize-TcTenantApplication {
    <#
    .SYNOPSIS
    Creates or updates the application in one tenant and saves its identifiers.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tenant,
        [Parameter(Mandatory)]$Certificate,
        [AllowEmptyCollection()][string[]]$Extended = @(),
        [switch]$GrantAdminConsent,
        [switch]$UseDeviceCode
    )

    $resources = [ordered]@{
        Graph      = @{ AppId = '00000003-0000-0000-c000-000000000000'; Name = 'Microsoft Graph' }
        Exchange   = @{ AppId = '00000002-0000-0ff1-ce00-000000000000'; Name = 'Office 365 Exchange Online' }
        Protection = @{ AppId = '00000007-0000-0ff1-ce00-000000000000'; Name = 'Microsoft Exchange Online Protection' }
        SharePoint = @{ AppId = '00000003-0000-0ff1-ce00-000000000000'; Name = 'Office 365 SharePoint Online' }
    }
    $sitesPermission = 'Sites.FullControl.All'
    $globalReader = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'

    $tenantId = Resolve-TcTenantId -Tenant $Tenant
    Write-TcMessage -Message "Tenant: $($Tenant['displayName']) ($tenantId)"
    Connect-TcGraphAdmin -Tenant $Tenant -TenantId $tenantId -UseDeviceCode:$UseDeviceCode

    # 1. The application and its service principal.
    $application = Get-TcProjectApplication -Tenant $Tenant
    if ($application) {
        Write-TcMessage -Message "Existing application reused: $($application['appId'])"
    }
    else {
        $application = Invoke-TcAccessGraph -Method POST -Uri 'v1.0/applications' -Body @{
            displayName    = $script:TcApplicationName
            signInAudience = 'AzureADMyOrg'
            notes          = 'TenantConverge read-only assessment. Remove it at the end of the project with Remove-TcAccess.'
        }
        Write-TcMessage -Message "Application created: $($application['appId'])" -Level Success
        # Saved at once: the next run must know this application if a step below fails.
        Save-TcApplicationEntry -ProjectPath $ProjectPath -Role $Role -Tenant $Tenant -TenantId $tenantId -ClientId $application['appId'] -Certificate $Certificate -Grants @()
    }

    $principal = @(Get-TcAccessGraphFilter -Collection 'servicePrincipals' -Filter "appId eq '$($application['appId'])'") | Select-Object -First 1
    if (-not $principal) { $principal = Invoke-TcAccessGraph -Method POST -Uri 'v1.0/servicePrincipals' -Body @{ appId = $application['appId'] } }

    # 2. Requested permissions and certificate. Existing keys only come back on $select.
    $wanted = [ordered]@{ Graph = @(Get-TcApplicationPermission); Exchange = @('Exchange.ManageAsApp'); Protection = @('Exchange.ManageAsApp') }
    if ('SharePoint' -in $Extended) { $wanted['SharePoint'] = @($sitesPermission) }

    $principals = @{}
    $roles = @{}
    foreach ($key in @($wanted.Keys) + @('SharePoint') | Sort-Object -Unique) {
        $principals[$key] = Get-TcResourcePrincipal -Resource $resources[$key]
        $roles[$key] = if ($principals[$key]) {
            Get-TcApplicationRoleId -Principal $principals[$key] -Value @(Get-TcProperty $wanted $key) -ResourceName $resources[$key]['Name']
        }
        else { @{} }
    }

    $access = @(foreach ($key in $wanted.Keys) {
            if ($roles[$key].Count) {
                @{ resourceAppId = $resources[$key]['AppId']; resourceAccess = @($roles[$key].Values | ForEach-Object { @{ id = $_; type = 'Role' } }) }
            }
        })

    $keys = @(Get-TcProperty (Invoke-TcAccessGraph -Uri "v1.0/applications/$($application['id'])?`$select=keyCredentials") 'keyCredentials' @())
    $hash = [Convert]::ToBase64String($Certificate.GetCertHash())
    $raw = [Convert]::ToBase64String($Certificate.RawData)
    if (-not @($keys | Where-Object { (Get-TcProperty $_ 'customKeyIdentifier') -eq $hash -or (Get-TcProperty $_ 'key') -eq $raw }).Count) {
        $keys += @{ type = 'AsymmetricX509Cert'; usage = 'Verify'; key = $raw; displayName = $script:TcCertificateSubject }
        Write-TcMessage -Message 'Certificate added to the application.' -Level Success
    }
    Invoke-TcAccessGraph -Method PATCH -Uri "v1.0/applications/$($application['id'])" -Body @{ requiredResourceAccess = $access; keyCredentials = $keys } | Out-Null

    # 3. Admin consent, one assignment per application role, only when the administrator asks for it.
    $grants = [System.Collections.Generic.List[string]]::new()
    $consent = 'Pending'
    if ($GrantAdminConsent) {
        $existing = @(Get-TcAccessGraphList -Uri "v1.0/servicePrincipals/$($principal['id'])/appRoleAssignments")
        $granted = 0
        foreach ($key in $wanted.Keys) {
            foreach ($roleId in $roles[$key].Values) {
                if (@($existing | Where-Object { $_['appRoleId'] -eq $roleId -and $_['resourceId'] -eq $principals[$key]['id'] }).Count) { continue }
                Invoke-TcAccessGraph -Method POST -Uri "v1.0/servicePrincipals/$($principal['id'])/appRoleAssignments" `
                    -Body @{ principalId = $principal['id']; resourceId = $principals[$key]['id']; appRoleId = $roleId } | Out-Null
                $granted++
            }
        }
        Write-TcMessage -Message "Admin consent: $granted permissions granted, $($existing.Count) already in place." -Level Success

        if ('SharePoint' -notin $Extended -and $principals['SharePoint']) {
            $sitesRole = (Get-TcApplicationRoleId -Principal $principals['SharePoint'] -Value $sitesPermission -ResourceName 'SharePoint').Values
            foreach ($assignment in @($existing | Where-Object { $_['resourceId'] -eq $principals['SharePoint']['id'] -and $_['appRoleId'] -in $sitesRole })) {
                Invoke-TcAccessGraph -Method DELETE -Uri "v1.0/servicePrincipals/$($principal['id'])/appRoleAssignments/$($assignment['id'])" | Out-Null
                Write-TcMessage -Message "$sitesPermission removed: SharePoint extended access is not given." -Level Warning
            }
        }

        # 4. The Global Reader role.
        $assignments = @(Get-TcAccessGraphFilter -Collection 'roleManagement/directory/roleAssignments' -Filter "principalId eq '$($principal['id'])'" |
                Where-Object { $_['roleDefinitionId'] -eq $globalReader })
        if ($assignments.Count) {
            Write-TcMessage -Message 'Global Reader role already assigned.'
        }
        else {
            Invoke-TcAccessGraph -Method POST -Uri 'v1.0/roleManagement/directory/roleAssignments' -Body @{ principalId = $principal['id']; roleDefinitionId = $globalReader; directoryScopeId = '/' } | Out-Null
            Write-TcMessage -Message 'Global Reader role assigned to the application.' -Level Success
        }

        foreach ($name in 'Graph', 'Exchange', 'Purview', 'Teams') { $grants.Add($name) }
        if ('SharePoint' -in $Extended -and $roles['SharePoint'].Count) { $grants.Add('SharePoint') }
        $consent = 'Granted'

        # 5. Extended access, each in its own process with its own sign-in.
        if ('PowerPlatform' -in $Extended) {
            Write-TcMessage -Message 'Power Platform: sign in with Windows PowerShell 5.1, then the management application is registered.' -Level Warning
            try {
                [void](Invoke-TcAdminProcess -Code (Get-TcPowerPlatformSetupCode) -Executable 'powershell.exe' -Arguments @{ TenantId = $tenantId; AppId = $application['appId'] })
                $grants.Add('PowerPlatform')
                Write-TcMessage -Message 'Power Platform management application registered.' -Level Success
            }
            catch { Write-TcMessage -Message "Power Platform: $(Get-TcErrorText $_). This part keeps its sign-in window." -Level Warning }
        }

        if ('Azure' -in $Extended) {
            Write-TcMessage -Message 'Azure: sign in, then the Reader role is given on each subscription this account can see.' -Level Warning
            try {
                $azure = Invoke-TcAdminProcess -Code (Get-TcAzureSetupCode) -Executable 'pwsh' -Arguments @{ TenantId = $tenantId; ObjectId = $principal['id'] }
                foreach ($problem in @(Get-TcProperty $azure 'errors' @())) { Write-TcMessage -Message "Azure: $problem" -Level Warning }
                $subscriptions = @(Get-TcProperty $azure 'subscriptions' @())
                if ($subscriptions.Count) {
                    $grants.Add('Azure')
                    Write-TcMessage -Message "Reader role: $($subscriptions -join ', ')" -Level Success
                }
                else {
                    Write-TcMessage -Message "No subscription is visible to this account, so there is nothing to assign. Turn on 'Access management for Azure resources' if the tenant has any." -Level Warning
                }
            }
            catch { Write-TcMessage -Message "Azure: $(Get-TcErrorText $_)" -Level Warning }
        }
    }
    else {
        Write-TcMessage -Message "Consent not given. An administrator can give it at https://login.microsoftonline.com/$tenantId/adminconsent?client_id=$($application['appId']), or run this command with -GrantAdminConsent." -Level Warning
    }

    # 6. The local access file.
    Save-TcApplicationEntry -ProjectPath $ProjectPath -Role $Role -Tenant $Tenant -TenantId $tenantId -ClientId $application['appId'] -Certificate $Certificate -Grants @($grants)
    Write-TcMessage -Message "Saved in the local access file: application $($application['appId']), access $(@($grants) -join ', ')." -Level Success

    [pscustomobject][ordered]@{ Role = $Role; Tenant = $Tenant['displayName']; ApplicationId = $application['appId']; Grants = @($grants); Consent = $consent }
}

function Initialize-TcDelegatedAccess {
    <#
    .SYNOPSIS
    Registers the delegated PnP application of a tenant, and nothing else.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tenant,
        [switch]$UseDeviceCode
    )

    try {
        $Tenant['tenantId'] = Resolve-TcTenantId -Tenant $Tenant
        # This sign-in only finds the initial domain, which PnP needs. The registration signs in by itself.
        Connect-TcGraphAdmin -Tenant $Tenant -TenantId $Tenant['tenantId'] -Scope 'Organization.Read.All' -UseDeviceCode:$UseDeviceCode
        Register-TcDelegatedPnP -ProjectPath $ProjectPath -Role $Role -Tenant $Tenant
        $id = Get-TcProperty (Get-TcProperty $Tenant 'access') 'pnpClientId'
        [pscustomobject][ordered]@{ Role = $Role; Tenant = $Tenant['displayName']; ApplicationId = $id; Grants = @(); Consent = $(if ($id) { 'Delegated' } else { 'Not registered' }) }
    }
    catch {
        Write-TcMessage -Message "$($Tenant['displayName']): $(Get-TcErrorText $_)" -Level Warning
        [pscustomobject][ordered]@{ Role = $Role; Tenant = $Tenant['displayName']; ApplicationId = $null; Grants = @(); Consent = 'Failed' }
    }
    finally { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null }
}

function Register-TcDelegatedPnP {
    <#
    .SYNOPSIS
    Registers a delegated PnP application for a tenant and saves its ID. PnP runs in its own process.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string]$Role,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Tenant
    )

    $code = @'
param($Domain, $OutFile, $ApplicationName)
$ErrorActionPreference = 'Stop'
Import-Module PnP.PowerShell
$result = Register-PnPEntraIDAppForInteractiveLogin -ApplicationName $ApplicationName -Tenant $Domain `
    -SharePointDelegatePermissions 'AllSites.FullControl', 'TermStore.Read.All', 'User.Read.All' `
    -GraphDelegatePermissions 'Group.Read.All', 'User.Read.All', 'Sites.Read.All'
$id = $null
foreach ($item in @($result)) {
    if ($null -eq $item) { continue }
    foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -match 'ClientId|AppId' -and [string]$property.Value -match '^[0-9a-f\-]{36}$') { $id = [string]$property.Value }
    }
    if (-not $id -and [string]$item -match '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') { $id = $Matches[1] }
}
@{ clientId = $id } | ConvertTo-Json | Set-Content -LiteralPath $OutFile -Encoding UTF8
'@

    Write-TcMessage -Message "$($Tenant['displayName']): sign in, then accept the consent for the PnP application." -Level Warning
    $id = $null
    try {
        $id = Get-TcProperty (Invoke-TcAdminProcess -Code $code -Executable 'pwsh' -Arguments @{ Domain = $Tenant['initialDomain']; ApplicationName = $script:TcPnpApplicationName }) 'clientId'
    }
    catch { Write-TcMessage -Message "Registration failed: $(Get-TcErrorText $_)" -Level Warning }

    while (-not $id) {
        $answer = (Read-TcAnswer -Prompt "Client ID of the PnP application of $($Tenant['displayName']), or Enter to skip").Trim()
        if (-not $answer) { break }
        if ($answer -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { $id = $answer }
        else { Write-TcMessage -Message 'Expected format: 00000000-0000-0000-0000-000000000000' -Level Warning }
    }

    if (-not $id) {
        Write-TcMessage -Message "$($Tenant['displayName']): without a PnP application, SharePoint will not be collected for this tenant." -Level Warning
        return
    }

    $entry = [ordered]@{}
    $current = Get-TcProperty (Read-TcAccessFile -ProjectPath $ProjectPath) $Role
    if ($current) { foreach ($key in @($current.Keys)) { $entry[$key] = $current[$key] } }
    # Graph stays out of the process that reads SharePoint, so the run needs these two from here.
    foreach ($known in 'tenantId', 'initialDomain') {
        if (-not $entry.Contains($known) -and $Tenant[$known]) { $entry[$known] = $Tenant[$known] }
    }
    $entry['pnpClientId'] = $id
    Write-TcAccessEntry -ProjectPath $ProjectPath -Role $Role -Entry $entry
    $Tenant['access'] = $entry
    Write-TcMessage -Message "$($Tenant['displayName']): PnP application saved in the local access file." -Level Success
}

function Get-TcPowerPlatformSetupCode {
    <#
    .SYNOPSIS
    Registers the application for Power Platform management, in Windows PowerShell 5.1.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @'
param($TenantId, $AppId, $OutFile)
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerApps.Administration.PowerShell
Add-PowerAppsAccount -Endpoint prod -TenantID $TenantId | Out-Null
$existing = $null
try { $existing = Get-PowerAppManagementApp -ApplicationId $AppId } catch { $existing = $null }
if (-not $existing -or -not $existing.applicationId) { New-PowerAppManagementApp -ApplicationId $AppId | Out-Null }
@{ ok = $true; existing = [bool]($existing -and $existing.applicationId) } | ConvertTo-Json | Set-Content -LiteralPath $OutFile -Encoding UTF8
'@
}

function Get-TcAzureSetupCode {
    <#
    .SYNOPSIS
    Gives the application the Reader role on each subscription the account can see.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    @'
param($TenantId, $ObjectId, $OutFile)
$ErrorActionPreference = 'Stop'
Import-Module Az.Accounts, Az.Resources
Connect-AzAccount -Tenant $TenantId -WarningAction SilentlyContinue | Out-Null
$result = [ordered]@{ subscriptions = @(); errors = @() }
foreach ($subscription in @(Get-AzSubscription -TenantId $TenantId -WarningAction SilentlyContinue)) {
    $scope = "/subscriptions/$($subscription.Id)"
    try {
        if (-not @(Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName 'Reader' -Scope $scope -WarningAction SilentlyContinue).Count) {
            New-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName 'Reader' -Scope $scope -WarningAction SilentlyContinue | Out-Null
        }
        $result.subscriptions += $subscription.Name
    }
    catch { $result.errors += "$($subscription.Name): $($_.Exception.Message)" }
}
$result | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutFile -Encoding UTF8
'@
}

function Invoke-TcAccessVerification {
    <#
    .SYNOPSIS
    Tests each service in a new process, so the sign-ins of the setup are not reused. Returns its exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$ProjectPath,
        [Parameter(Mandatory)][string[]]$Role
    )

    Start-Sleep -Seconds 30
    $module = (Join-Path $PSScriptRoot '..' 'TenantConverge.psd1') -replace "'", "''"
    $project = $ProjectPath -replace "'", "''"
    $command = "Import-Module '$module'; `$rows = @(Initialize-TcAccess -Project '$project' -Tenant $($Role -join ',') -Verify); `$rows | Format-Table -AutoSize | Out-Host; if (@(`$rows | Where-Object Result -NotLike 'OK*').Count) { exit 1 }"
    & (Get-Process -Id $PID).Path -NoProfile -Command $command
    $LASTEXITCODE
}

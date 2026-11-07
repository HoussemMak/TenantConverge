function Remove-TcAccess {
    <#
    .SYNOPSIS
    Removes the applications of TenantConverge from the tenants of a project.

    .DESCRIPTION
    Deletes the TenantConverge Read-Only application and the delegated TenantConverge PnP application from
    each tenant, forgets their identifiers in the local access file, and removes the certificate from this
    computer when no tenant uses it any more. Entra ID keeps a deleted application for 30 days.

    An application is deleted only when it carries the name TenantConverge gave it and its ID is in the
    access file. Any other application stays in the tenant, and the command says so: one of the same
    name that this project did not create, and a PnP client ID that was typed in for another application.

    It writes to the tenant, as Initialize-TcAccess does, and as Invoke-TcRemediation and Undo-TcRemediation
    do with -Apply. It asks for confirmation. Use -WhatIf to see what it would do.

    .PARAMETER Project
    The project file.

    .PARAMETER Tenant
    The roles to clean up. The default is the target and every source.

    .PARAMETER UseDeviceCode
    Signs in with a device code instead of a browser window.

    .EXAMPLE
    Remove-TcAccess -Project ./project.json

    Removes the applications from every tenant of the project.

    .EXAMPLE
    Remove-TcAccess -Project ./project.json -Tenant S2 -WhatIf

    Shows what would be removed from S2, and changes nothing.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string]$Project,
        [ValidateSet('Target', 'S1', 'S2', 'S3')][string[]]$Tenant,
        [switch]$UseDeviceCode
    )

    $projectPath = Resolve-TcPath -Path $Project
    Initialize-TcSession -Project (Read-TcProjectFile -Path $projectPath) -Access (Read-TcAccessFile -ProjectPath $projectPath)
    $chosen = @(if ($Tenant) { $Tenant | Where-Object { $script:TcTenants.Contains($_) } } else { $script:TcTenants.Keys })
    if ($chosen.Count -eq 0) { throw 'No tenant of this project matches -Tenant.' }

    foreach ($role in $chosen) {
        $entry = $script:TcTenants[$role]
        $target = "$($entry['displayName']) ($($entry['primaryDomain']))"
        if (-not $PSCmdlet.ShouldProcess($target, "Delete the applications '$script:TcApplicationName' and '$script:TcPnpApplicationName'")) { continue }

        $tenantId = Resolve-TcTenantId -Tenant $entry
        Connect-TcGraphAdmin -Tenant $entry -TenantId $tenantId -UseDeviceCode:$UseDeviceCode
        $deleted = [System.Collections.Generic.List[string]]::new()
        $access = Get-TcProperty $entry 'access'
        $created = @((Get-TcProperty $access 'clientId'), (Get-TcProperty $access 'pnpClientId')) | Where-Object { $_ }
        foreach ($name in $script:TcApplicationName, $script:TcPnpApplicationName) {
            foreach ($application in @(Get-TcAccessGraphFilter -Collection 'applications' -Filter "displayName eq '$name'")) {
                if ([string]$application['appId'] -notin $created) {
                    Write-TcMessage -Message "The application '$name' ($($application['appId'])) is not one this project created, so it stays in this tenant." -Level Warning
                    continue
                }
                Invoke-TcAccessGraph -Method DELETE -Uri "v1.0/applications/$($application['id'])" | Out-Null
                $deleted.Add([string]$application['appId'])
                Write-TcMessage -Message "Application '$name' ($($application['appId'])) deleted. Entra ID keeps it for 30 days." -Level Success
            }
        }
        $pnpClientId = Get-TcProperty $access 'pnpClientId'
        if ($pnpClientId -and $pnpClientId -notin $deleted) {
            Write-TcMessage -Message "The PnP application $pnpClientId is not named '$script:TcPnpApplicationName', so it stays in this tenant. Delete it by hand if nothing else uses it." -Level Warning
        }
        Write-TcAccessEntry -ProjectPath $projectPath -Role $role -Entry $null
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }

    if (-not $WhatIfPreference -and (Read-TcAccessFile -ProjectPath $projectPath).Count -eq 0) { Remove-TcReadCertificate }
}

function Remove-TcReadCertificate {
    <#
    .SYNOPSIS
    Removes the read-only certificate from the certificate store of the current user.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param()

    foreach ($certificate in @(Get-ChildItem Cert:\CurrentUser\My | Where-Object Subject -EQ $script:TcCertificateSubject)) {
        if ($PSCmdlet.ShouldProcess($certificate.Thumbprint, 'Delete the certificate and its key')) {
            Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -DeleteKey
            Write-TcMessage -Message "Certificate $($certificate.Thumbprint) removed from this computer." -Level Success
        }
    }
}

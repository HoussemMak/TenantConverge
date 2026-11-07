# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Handles expired or nearly expired secrets and certificates, application by application (procedure ENT-SECRETS).

.DESCRIPTION
    Data read: the applications table of the snapshot. The threshold comes from the SecretExpiryDays setting.
    decisions\ENT-SECRETS.csv: one row per application.
      - Renew: the application stays in use in its tenant. The owner creates the new credential. The script never creates a secret: its
        value shows once and must not be in a file or a log;
      - Remove: the application is unused. The secrets are removed by the script, with no way back;
      - Leave: the application will be recreated in the target, or it manages its credentials itself.
    An application to recreate is not renewed in the source, unless its secret expires before its cutover.

    Sync applications and those of this module are never removed, whatever the decision.
    Limit: removing a certificate needs a proof of possession of its key (Graph removeKey), which an expired certificate no longer
    allows. This removal is done in the portal.
#>
$c = Open-TcRemediation

$Threshold = [int](Get-TcRemediationOption 'SecretExpiryDays')
$ProtectedApps = ('^ConnectSyncProvisioning|' + (Get-TcRemediationOption 'ProtectedApplicationPattern'))

function Test-ToExpire {
    param($Row)
    $days = "$($Row['Days to expiry'])"
    return [int]('0' + $Row['Expired']) -gt 0 -or ($days -ne '' -and [double]$days -le $Threshold)
}

function Get-CredentialList {
    param([string]$Tenant, [string]$AppId)
    return (Invoke-TcGraph -Tenant $Tenant -Uri ("v1.0/applications(appId='{0}')?`$select=id,displayName,passwordCredentials,keyCredentials" -f $AppId))
}

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t 'Secrets and certificates read'
    $rows = @(Get-TcRemediationTable $t 'applications' | Where-Object { Test-ToExpire $_ })
    $expectedOne = @(Get-TcRemediationPlanAction -Procedure 'ENT-SECRETS' -Tenant $t | ForEach-Object { (Get-TcMember $_ 'items') } | Where-Object { $_ }).Count
    Write-TcRemediationNote ("{0} application(s) with a secret or certificate that is expired or expires within {1} days" -f $rows.Count, $Threshold)
    if ($expectedOne -ne $rows.Count) { Write-TcRemediationAlert ("The plan has {0} application(s), the snapshot {1}: regenerate the plan?" -f $expectedOne, $rows.Count) }
    foreach ($l in $rows) {
        $days = "$($l['Days to expiry'])"
        [ordered]@{ Tenant = $t; Application = $l['Name']; AppId = $l['AppId']; SecretItems = $l['Secrets']; Certificates = $l['Certificates']; Expired = $l['Expired']; 'Days to expiry' = $days
                    Proposal = $(if ($l['Name'] -match $ProtectedApps -or $t -ne 'Target') { 'Leave' } elseif ($days) { 'Renew' } else { '' }) }
    }
}

$decisions = @(Get-TcDecision -Name 'ENT-SECRETS' -Proposal @($proposals | Where-Object { $_ }) -Key 'Tenant', 'AppId' -Choice 'Renew', 'Remove', 'Leave')

foreach ($d in $decisions) {
    $t = (Get-TcMember $d 'Tenant')
    if ((Get-TcMember $d 'Decision') -eq 'Renew') {
        Add-TcManualAction -Tenant $t -Object (Get-TcMember $d 'AppId') -Description ("Renew the credential of {0}" -f (Get-TcMember $d 'Application')) -Who 'Application owner' -Minutes 0 `
            -Instruction @(("{0}: create a new certificate or secret in Entra ID > App registrations > Certificates and secrets." -f (Get-TcMember $d 'Application')),
                        'Put the value in the customer''s vault, never in a report. Deploy, test, then remove the old one.') `
            -WaitUntil { param($a) $x = Get-CredentialList $a.tenant $a.object; $limit = (Get-TcRemediationNow).AddDays($Threshold); return @(@((Get-TcMember $x 'passwordCredentials')) + @((Get-TcMember $x 'keyCredentials')) | Where-Object { $_ -and (Get-TcMember $_ 'endDateTime') -and [datetime](Get-TcMember $_ 'endDateTime') -gt $limit }).Count -gt 0 }
    }
    elseif ((Get-TcMember $d 'Decision') -eq 'Remove') {
        if ((Get-TcMember $d 'Application') -match $ProtectedApps) { Write-TcRemediationAlert ("{0}: protected application, the Remove decision is ignored" -f (Get-TcMember $d 'Application')); continue }
        if ([int]('0' + (Get-TcMember $d 'SecretItems')) -gt 0) {
            Add-TcBlockAction -Tenant $t -Service Graph -Object (Get-TcMember $d 'Application') -Description ("Remove the secrets of {0}, unused application" -f (Get-TcMember $d 'Application')) -Data @{ AppId = (Get-TcMember $d 'AppId') } `
                -Reason 'A removed secret cannot be restored: a new one must be created.' `
                -Test { param($a) -not @((Get-TcMember (Get-CredentialList $a.tenant $a.data.AppId) 'passwordCredentials')).Count } `
                -Block {
                    param($a)
                    $x = Get-CredentialList $a.tenant $a.data.AppId
                    foreach ($s in @((Get-TcMember $x 'passwordCredentials'))) { Invoke-TcGraph -Tenant $a.tenant -Method POST -Uri "v1.0/applications/$((Get-TcMember $x 'id'))/removePassword" -Body @{ keyId = (Get-TcMember $s 'keyId') } }
                }
        }
        if ([int]('0' + (Get-TcMember $d 'Certificates')) -gt 0) {
            Add-TcManualAction -Tenant $t -Object (Get-TcMember $d 'Application') -Description ("Remove the certificate of {0} in the portal" -f (Get-TcMember $d 'Application')) -Who 'Team' `
                -Instruction @(("{0}: Entra ID > App registrations > Certificates and secrets > Certificates > Delete." -f (Get-TcMember $d 'Application')), 'Graph requires proof of possession of the key, impossible for an expired certificate.')
        }
    }
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $limit = (Get-TcRemediationNow).AddDays($Threshold)
    $decidedOnes = @($decisions | Where-Object { (Get-TcMember $_ 'Tenant') -eq $t } | ForEach-Object { (Get-TcMember $_ 'AppId') })
    $apps = @(Invoke-TcGraph -Tenant $t -Uri 'v1.0/applications?$select=appId,displayName,passwordCredentials,keyCredentials' -All)
    $noDecision = @($apps | Where-Object {
        $x = $_
        @(@((Get-TcMember $x 'passwordCredentials')) + @((Get-TcMember $x 'keyCredentials')) | Where-Object { $_ -and (Get-TcMember $_ 'endDateTime') -and [datetime](Get-TcMember $_ 'endDateTime') -lt $limit }).Count -gt 0 -and (Get-TcMember $x 'appId') -notin $decidedOnes })
    if ($noDecision.Count) { New-TcRemediationResult Warning ("{0} application(s) expired or close to expiry without a decision" -f $noDecision.Count) } else { New-TcRemediationResult OK 'all remaining cases are decided' }
}
Close-TcRemediation

# UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.
<#
.SYNOPSIS
    Deploys in the target the useful SharePoint customizations, before the sites are copied (procedure SPO-CUSTOMIZATIONS).

.DESCRIPTION
    Reads sharePointCustomizations. decisions\SPO-CUSTOMIZATIONS.csv says for each element: Deploy or Ignore.
    For an SPFx application, the Note column gives the path of the .sppkg package, supplied by the publisher: the script uploads and
    publishes it. An application is never deployed without its package. A row with no name in the snapshot is reported: the application
    stays to identify.
    The app catalog of the target is read during the -Apply run.
    Limits: the test on a pilot site, API approval and rebuilding a package that carries addresses of the source stay human.
    An asset library is declared after its site is copied. Site scripts and templates are not in the snapshot: the script reads them in
    the source in an -Apply run, and a person recreates them if useful.
#>
$c = Open-TcRemediation

$catalog = [string](Get-TcProperty (Get-TcRemediationTable 'Target' 'sharePointCustomizations' | Where-Object { $_['Type'] -eq "App catalog" } | Select-Object -First 1) 'Name' '')

$proposals = foreach ($t in $c.Tenants) {
    Write-TcRemediationTenant $t
    Write-TcRemediationNote ("App catalog of the target: {0}" -f $(if ($catalog) { $catalog } else { 'missing' }))
    if (-not $catalog) { Write-TcRemediationAlert 'Catalog missing from the target: create it before deploying (Register-PnPAppCatalogSite)' }
    $rows = @(Get-TcRemediationTable $t 'sharePointCustomizations' | Where-Object { $_['Type'] -ne "App catalog" })
    Write-TcRemediationNote ("{0} customization(s) read" -f $rows.Count)
    foreach ($l in $rows) {
        if (-not $l['Name']) { Write-TcRemediationAlert ("{0} with no name in the snapshot: identify them with Get-PnPApp -Scope Tenant in the source" -f $l['Type']); continue }
        $name = if ($l['Name'] -match 'DisplayName=([^;]+)') { $Matches[1] } else { [string]$l['Name'] }
        $library = if ($l['Name'] -match 'DecodedUrl=([^;]+)') { $Matches[1] } else { '' }
        [ordered]@{ Tenant = $t; Type = $l['Type']; Name = $name; 'Detail' = $(if ($library) { $library } else { [string]$l['Detail'] }); Proposal = '' }
    }
}
$decisions = @(Get-TcDecision -Name 'SPO-CUSTOMIZATIONS' -Proposal @($proposals) -Key 'Tenant', 'Type', 'Name' -Choice 'Deploy', 'Ignore')

foreach ($d in $decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Deploy' }) {
    if ((Get-TcMember $d 'Type') -eq 'SPFx app') {
        if ((Get-TcMember $d 'Note') -notmatch '\.sppkg$') { Write-TcRemediationAlert ("{0}: the Note column must give the path of the .sppkg package" -f (Get-TcMember $d 'Name')); continue }
        Add-TcBlockAction -Tenant 'Target' -Service Pnp -Object (Get-TcMember $d 'Name') -Description ("Upload and publish {0} in the catalog of the target" -f (Get-TcMember $d 'Name')) -Data @{ Name = (Get-TcMember $d 'Name'); Package = (Get-TcMember $d 'Note') } `
            -Test { param($a) [bool](@(Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Get-PnPApp' -Parameters @{ Scope = 'Tenant' }) | Where-Object { (Get-TcMember $_ 'Title') -eq $a.data.Name }) } `
            -Block {
                param($a)
                if (-not (Test-Path -LiteralPath $a.data.Package)) { throw "Package not found: $($a.data.Package)" }
                $r = Invoke-TcServiceCommand -Tenant $a.tenant -Service Pnp -Command 'Add-PnPApp' -Parameters @{ Path = $a.data.Package; Scope = 'Tenant'; Publish = $true }
                $a.undo = @{ command = 'Remove-PnPApp'; parameters = @{ Identity = (Get-TcText $r 'Id'); Scope = 'Tenant'; Force = $true } }
            }
    }
    else {
        Add-TcManualAction -Tenant 'Target' -Object (Get-TcMember $d 'Name') -Description ("Declare {0} after its site is copied" -f (Get-TcMember $d 'Name')) `
            -Instruction @(("Source: {0}. The site must be copied first." -f (Get-TcMember $d 'Details')), 'Add-PnPOrgAssetsLibrary -LibraryUrl <target address>/<library> -OrgAssetType OfficeTemplateLibrary')
    }
}
if (@($decisions | Where-Object { (Get-TcMember $_ 'Decision') -eq 'Deploy' -and (Get-TcMember $_ 'Type') -eq 'SPFx app' }).Count) {
    Add-TcManualAction -Tenant 'Target' -Object 'Pilot site' -Description "Install the applications on a pilot site and try them" `
        -Instruction @('Install-PnPApp -Identity <id>, then open a page that uses the component.', 'Approve the requested APIs. A package that carries addresses of the source must be rebuilt by its author.')
}

Invoke-TcRemediationPlan -Verify {
    param($t)
    $url = Invoke-TcServiceCommand -Tenant 'Target' -Service Pnp -Command 'Get-PnPTenantAppCatalogUrl'
    if ($url) { New-TcRemediationResult OK "catalog of the target: $url" } else { New-TcRemediationResult Blocking 'no app catalog in the target' }
    $scripts = @(Invoke-TcServiceCommand -Tenant $t -Service Pnp -Command 'Get-PnPSiteScript')
    $templates = @(Invoke-TcServiceCommand -Tenant $t -Service Pnp -Command 'Get-PnPSiteDesign')
    if ($scripts.Count -or $templates.Count) { New-TcRemediationResult Warning ("{0} site script(s) and {1} site template(s) in the source: decide which to recreate" -f $scripts.Count, $templates.Count) }
    else { New-TcRemediationResult OK 'no site script or template in the source' }
}
Close-TcRemediation

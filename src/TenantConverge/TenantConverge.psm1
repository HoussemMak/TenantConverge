Set-StrictMode -Version 3.0

# The single source of truth for the scenario limit: 1 to 3 sources into 1 target.
$script:TcMaxSources = 3
$script:TcSchemaVersion = 1

# The run log. Empty until Initialize-TcLog sets the run folder.
$script:TcLogFile = $null
$script:TcEventFile = $null

# Module versions found in this session.
$script:TcModuleVersions = @{}

# The neutral names of what the access commands create in a tenant.
$script:TcApplicationName = 'TenantConverge Read-Only'
$script:TcPnpApplicationName = 'TenantConverge PnP'
$script:TcCertificateSubject = 'CN=TenantConverge Read-Only'

# The tenants of the running project, by role, and what each service is connected to.
$script:TcTenants = [ordered]@{}
$script:TcUnattended = $false
$script:TcActive = @{ Graph = $null; Exo = $null }
$script:TcServiceConnections = @{ Ipps = $null; Teams = $null; Pnp = $null; Azure = $null }
$script:TcPnpConnection = $null

# The table dictionary, read once from Data\tables.json.
$script:TcTableDictionary = $null

# The workloads a tenant is scored on, in report order.
$script:TcWorkloads = @('Entra ID', 'Exchange Online', 'Domains and DNS', 'SharePoint and OneDrive', 'Teams', 'Teams Phone', 'Intune', 'Purview', 'Power Platform', 'Azure', 'Other services')

# The rule catalog, read once from Data\rules.json, and the state of the running rule set.
$script:TcRuleCatalog = $null
$script:TcRuleRun = $null

# The task templates and the procedures, read once from Data\tasks.json and Data\procedures.json.
$script:TcTaskCatalog = $null
$script:TcProcedureCatalog = $null

# The public product facts, read once from Data\products.json.
$script:TcProductCatalog = $null

# The remediations: the manifest, the scripts, the running one, and the notice every run must show.
$script:TcRemediationCatalog = $null
$script:TcRemediationRoot = Join-Path $PSScriptRoot 'Remediation'
$script:TcRemediationRun = $null
$script:TcUntestedNotice = 'UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.'
$script:TcPolicyUri = 'v1.0/identity/conditionalAccess/policies'
$script:TcReportOnlyState = 'enabledForReportingButNotEnforced'
$script:TcSyncRoleId = 'd29b2b05-8046-44ba-8758-1e26182fcf32'
$script:TcPolicyObservationDays = 3
# A POST of this kind has no DELETE that undoes it: an invitation, a partner, a link, a license, or an action on an account or a device.
$script:TcNoUndoPost = '(^|/)(invitations|partners)($|/|\?)|\$ref|/assignLicense|/(revoke|dismiss|confirm|verify|wipe|retire|sendMail)'

# The state of the running collection.
$script:TcDepth = 'Complete'
$script:TcProjectPath = ''
$script:TcCollectionSettings = @{}
$script:TcCollection = [ordered]@{}
$script:TcCurrentTenant = $null
$script:TcCurrentCollector = $null
$script:TcResume = @{}
$script:TcVerifiedServices = @{}
$script:TcRunInfo = @{}
$script:TcLastSave = Get-Date

# PnP.PowerShell stops PowerShell when it shares a process with the Graph and Exchange modules.
$script:TcIsolatedServices = @('Pnp')

# Microsoft's own tenants: an application they own is not a third-party one.
$script:TcMicrosoftTenantIds = @('f8cdef31-a31e-4b4a-93e4-5f571e91255a', '72f988bf-86f1-41af-91ab-2d7cd011db47', 'cdc5aeea-15c5-4db6-b079-fcadd2505dc2')

$privateFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue
$publicFiles = Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' -ErrorAction SilentlyContinue

foreach ($file in @($privateFiles) + @($publicFiles)) {
    if ($file) { . $file.FullName }
}

Export-ModuleMember -Function @($publicFiles | ForEach-Object BaseName)

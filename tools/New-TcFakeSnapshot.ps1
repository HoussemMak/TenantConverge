<#
.SYNOPSIS
Builds a snapshot of fictional tenants, for tests and demonstrations.

.DESCRIPTION
The data is fully invented, on reserved .example domains. It connects to nothing. The same source count
and seed always give the same bytes. The tenants carry the cases the assessment rules look for: inactive
accounts, weak settings, repeated names and addresses across tenants, a service that is not used, and a
workload that was not collected.

.PARAMETER SourceCount
The number of source tenants: 1, 2 or 3.

.PARAMETER Seed
The seed of the generator.

.PARAMETER Path
Where to write the snapshot. Without it, the snapshot is returned.

.EXAMPLE
./tools/New-TcFakeSnapshot.ps1 -SourceCount 3 -Seed 1 -Path ./output/fake/snapshot.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, 3)][int]$SourceCount,
    [int]$Seed = 1,
    [string]$Path
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..' 'src' 'TenantConverge' 'TenantConverge.psd1') -Force
$module = Get-Module TenantConverge
$dictionary = & $module { Get-TcTableDictionary }
$random = [System.Random]::new($Seed)
$today = [datetime]'2026-01-15'

function Get-FakeId {
    $bytes = [byte[]]::new(16)
    $random.NextBytes($bytes)
    ([guid]::new($bytes)).ToString()
}

function Get-FakeDate {
    param([int]$DaysAgo)
    $today.AddDays(-$DaysAgo).ToString('yyyy-MM-dd HH:mm')
}

function Get-FakeNumber {
    <# A number from 555-0100 to 555-0199, set aside for fiction: 25 for each tenant. #>
    param([int]$Rank, [int]$Slot)
    '+1202555{0:D4}' -f (100 + 25 * $Rank + $Slot)
}

function Get-FakeRow {
    <# A row with every column of the table. Columns not given stay empty. #>
    param([Parameter(Mandatory)][string]$Table, [hashtable]$Values = @{})

    $row = [ordered]@{}
    foreach ($column in $dictionary[$Table]['columns']) { $row[$column] = if ($Values.ContainsKey($column)) { $Values[$column] } else { $null } }
    foreach ($key in $Values.Keys) { if (-not $row.Contains($key)) { throw "$key is not a column of $Table." } }
    $row
}

function Get-FakeSetting {
    param([Parameter(Mandatory)][string]$Table, [Parameter(Mandatory)][System.Collections.IDictionary]$Settings)
    foreach ($key in $Settings.Keys) { Get-FakeRow $Table @{ Setting = $key; Value = $Settings[$key] } }
}

$tenantDefinitions = @(
    @{ Role = 'Target'; Name = 'Summit Holdings'; Slug = 'summit'; Rank = 0 }
    @{ Role = 'S1'; Name = 'Alpine Group'; Slug = 'alpine'; Rank = 1 }
    @{ Role = 'S2'; Name = 'Birch Partners'; Slug = 'birch'; Rank = 2 }
    @{ Role = 'S3'; Name = 'Cedar Services'; Slug = 'cedar'; Rank = 3 }
) | Select-Object -First ($SourceCount + 1)

foreach ($definition in $tenantDefinitions) { $definition['TenantId'] = Get-FakeId }

$sharedPeople = @(
    @('Ana', 'Silva'), @('Marc', 'Roy'), @('Nora', 'Haddad'), @('Theo', 'Nguyen'), @('Lea', 'Martin')
)
$otherFirst = 'Ines', 'Omar', 'Julie', 'Hugo', 'Sara', 'Yann', 'Maya', 'Paul', 'Elsa', 'Remi', 'Zoe', 'Karim'
$otherLast = 'Bouchard', 'Fortin', 'Gagnon', 'Lavoie', 'Morin', 'Pelletier', 'Caron', 'Ouellet'

function Get-FakeTenant {
    param([Parameter(Mandatory)][hashtable]$Definition)

    $slug = $Definition['Slug']
    $role = $Definition['Role']
    $domain = "$slug.example"
    # These two namespaces are real, so the name says what it is: no tenant should hold it.
    $tenantName = "fictional-$slug"
    $initial = "$tenantName.onmicrosoft.com"
    $isTarget = $role -eq 'Target'
    $partners = @($tenantDefinitions | Where-Object { $_['Role'] -ne $role })

    # S2 has no phone system and S3 has no Intune: both services exist and are simply not used.
    $hasPhone = $role -ne 'S2'
    $hasIntune = $role -ne 'S3'

    $tables = [ordered]@{}
    foreach ($key in $dictionary.Keys) { $tables[$key] = [System.Collections.Generic.List[object]]::new() }
    $add = { param([string]$Table, [hashtable]$Values = @{}) $tables[$Table].Add((Get-FakeRow $Table $Values)) }

    # Identity
    $people = [System.Collections.Generic.List[object]]::new()
    foreach ($person in $sharedPeople) { $people.Add($person) }
    $extra = 12 + $random.Next(0, 9)
    for ($i = 0; $i -lt $extra; $i++) { $people.Add(@($otherFirst[$random.Next(0, $otherFirst.Count)], "$($otherLast[$random.Next(0, $otherLast.Count)])-$slug$i")) }
    $people.Add(@("$([char]0xC9)lo$([char]0xEF)se", "C$([char]0xF4)t$([char]0xE9)-Tremblay"))
    $people.Add(@('Maximiliana-Alexandrina', 'Featherstonehaugh-Cholmondeley-Marjoribanks de la Tour'))

    $upns = [System.Collections.Generic.List[string]]::new()
    $index = 0
    foreach ($person in $people) {
        $alias = (($person[0] + '.' + ($person[1] -split ' ')[0]).Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '').ToLowerInvariant()
        $upn = "$alias@$domain"
        $upns.Add($upn)
        $inactive = switch ($index % 6) { 1 { 200 + $random.Next(0, 300) } 2 { -1 } default { $random.Next(0, 40) } }
        $disabled = $index % 7 -eq 3
        $lastSignIn = if ($inactive -lt 0) { $null } else { Get-FakeDate $inactive }
        & $add 'users' @{
            Id = Get-FakeId; UPN = $upn; Name = "$($person[0]) $($person[1])"; Type = 'Member'; Enabled = -not $disabled
            Created = Get-FakeDate (400 + $index); 'Days since creation' = 400 + $index; 'Last sign-in' = $lastSignIn; 'Days inactive' = $inactive
            Licenses = 'SPE_E3'; 'License count' = 1; Synced = $index % 5 -eq 0; Email = $upn; Department = 'Operations'; 'Job title' = 'Analyst'; Company = $Definition['Name']
            Country = $(if ($index % 9 -eq 4) { 'FR' } else { 'CA' }); 'Creation type' = $null; 'License errors' = $(if ($index -eq 4) { 1 } else { 0 }); 'Address count' = 2
            'First name' = $person[0]; 'Last name' = $person[1]; 'Employee ID' = "E$($Definition['Rank'])$index"; 'AD account' = $alias; 'AD anchor' = $index % 5 -eq 0
            'Sync errors' = $(if ($index -eq 5) { 1 } else { 0 }); Addresses = "$alias@$domain; $alias@$initial"; City = 'Montreal'; Office = 'Head office'
        }

        & $add 'mfaRegistrations' @{ UPN = $upn; Type = 'member'; 'MFA registered' = $index % 4 -ne 1; 'MFA capable' = $index % 4 -ne 1; Passwordless = $false; Methods = 'microsoftAuthenticatorPush'; 'Default method' = 'push'; Admin = $index -eq 0 }

        $mailboxType = if ($index -eq 6) { 'SharedMailbox' } else { 'UserMailbox' }
        & $add 'mailboxes' @{
            UPN = $upn; Name = "$($person[0]) $($person[1])"; Type = $mailboxType; 'Primary address' = $upn; Alias = $alias; 'Address count' = 2; Addresses = "$alias@$domain; $alias@$initial"
            Archive = $index % 6 -eq 0; 'Litigation hold' = $index -eq 2; Holds = 0; 'SMTP forwarding' = $(if ($index -eq 3) { 'smtp:outside@forward.example' } else { '' }); 'Internal forwarding' = ''; 'Deliver and forward' = $index -eq 3
            Hidden = $false; Created = Get-FakeDate 500; Quota = '99 GB'; 'MRM policy' = 'Default MRM Policy'; ObjectId = Get-FakeId
        }
        & $add 'mailboxUsage' @{ UPN = $upn; Name = "$($person[0]) $($person[1])"; Type = 'User'; Deleted = 'False'; 'Last activity' = $today.ToString('yyyy-MM-dd'); Items = 1000 + $random.Next(0, 90000); 'Size GB' = $(if ($index -eq 1) { 62.5 } else { [math]::Round(1 + $random.NextDouble() * 20, 2) }); 'Quota GB' = 99; Archive = 'False' }
        & $add 'mailboxProtocols' @{ Mailbox = $upn; POP = $index -eq 2; IMAP = $index -eq 3; ActiveSync = $true; EWS = $true; MAPI = $true; OWA = $true; 'Authenticated SMTP' = $(if ($index -eq 4) { $true } else { 'Per organization' }) }
        & $add 'userActivity' @{ UPN = $upn; Name = "$($person[0]) $($person[1])"; Exchange = $today.ToString('yyyy-MM-dd'); OneDrive = ''; SharePoint = ''; Teams = $today.ToString('yyyy-MM-dd'); 'Viva Engage' = ''; Products = 'MICROSOFT 365 E3' }
        & $add 'oneDrive' @{ Url = "https://$tenantName-my.sharepoint.com/personal/$($alias -replace '\.', '_')"; Owner = $upn; 'Storage MB' = $(if ($index -eq 1) { 204800 } else { 1 + $random.Next(0, 9000) }); 'Quota MB' = 1048576; 'Last modified' = Get-FakeDate 30; 'Days inactive' = 30; 'Lock state' = 'Unlock' }
        $voice = $hasPhone -and $index -lt 4
        & $add 'teamsUsers' @{ UPN = $upn; Name = "$($person[0]) $($person[1])"; Enabled = $true; 'Enterprise Voice' = $voice; Number = $(if ($voice) { (Get-FakeNumber $Definition['Rank'] $index) } else { '' }); Features = 'Teams'; 'Teams mode' = 'TeamsOnly'; Policies = ''; ObjectId = Get-FakeId }
        $index++
    }

    $guestAddress = "visitor@$($partners[0]['Slug']).example"
    & $add 'users' @{ Id = Get-FakeId; UPN = ($guestAddress -replace '@', '_') + "#EXT#@$initial"; Name = 'Visiting Partner'; Type = 'Guest'; Enabled = $true; Created = Get-FakeDate 300; 'Days since creation' = 300; 'Days inactive' = 120; Email = $guestAddress; 'Invitation state' = 'PendingAcceptance'; Licenses = ''; 'License count' = 0; 'License errors' = 0; 'Address count' = 1; 'Sync errors' = 0 }
    & $add 'users' @{ Id = Get-FakeId; UPN = "former@$domain"; Name = 'Former Employee'; Type = 'Member'; Enabled = $false; Created = Get-FakeDate 900; 'Days since creation' = 900; 'Days inactive' = 480; Licenses = 'SPE_E3'; 'License count' = 1; 'License errors' = 0; 'Address count' = 1; 'Sync errors' = 0 }

    $firstUpn = $upns[0]
    & $add 'mailboxes' @{ UPN = "room.one@$domain"; Name = 'Boardroom'; Type = 'RoomMailbox'; 'Primary address' = "room.one@$domain"; Alias = 'room.one'; 'Address count' = 1; Addresses = "room.one@$domain"; ObjectId = Get-FakeId }
    & $add 'mailboxes' @{ UPN = "projector@$domain"; Name = 'Projector'; Type = 'EquipmentMailbox'; 'Primary address' = "projector@$domain"; Alias = 'projector'; 'Address count' = 1; Addresses = "projector@$domain"; ObjectId = Get-FakeId }
    & $add 'mailboxes' @{ UPN = "info@$domain"; Name = 'Information'; Type = 'SharedMailbox'; 'Primary address' = "info@$domain"; Alias = 'info'; 'Address count' = 1; Addresses = "info@$domain"; ObjectId = Get-FakeId }
    & $add 'mailboxUsage' @{ UPN = "info@$domain"; Name = 'Information'; Type = 'Shared'; Deleted = 'False'; 'Last activity' = $today.ToString('yyyy-MM-dd'); Items = 400000; 'Size GB' = 47.5; 'Quota GB' = 50; Archive = 'False' }

    foreach ($setting in @(
            [ordered]@{ Setting = 'Name'; Value = $Definition['Name'] }
            [ordered]@{ Setting = 'Tenant ID'; Value = $Definition['TenantId'] }
            [ordered]@{ Setting = 'AD sync enabled'; Value = ($role -in 'S1', 'Target') }
            [ordered]@{ Setting = 'Days since last sync'; Value = $(switch ($role) { 'S1' { 2 } 'Target' { 3 } default { $null } }) }
            [ordered]@{ Setting = 'Country'; Value = 'CA' })) { $tables['organizationSettings'].Add($setting) }

    & $add 'domains' @{ Domain = $domain; Verified = $true; Default = $true; Initial = $false; Authentication = 'Managed'; Services = 'Email; OfficeCommunicationsOnline; Intune' }
    & $add 'domains' @{ Domain = $initial; Verified = $true; Default = $false; Initial = $true; Authentication = 'Managed'; Services = 'Email' }
    & $add 'administrativeUnits' @{ Name = 'Head office'; Description = 'Fictional unit'; Membership = 'Assigned' }

    $businessPlan = if ($role -eq 'S1') { @{ SKU = 'SPB'; Purchased = 300; Consumed = 288 } } else { @{ SKU = 'SPE_E3'; Purchased = 60; Consumed = 40 } }
    & $add 'licenses' @{ SKU = $businessPlan['SKU']; SkuId = Get-FakeId; State = 'Enabled'; Purchased = $businessPlan['Purchased']; Consumed = $businessPlan['Consumed']; Available = $businessPlan['Purchased'] - $businessPlan['Consumed']; Suspended = 0; 'In warning' = 0; Plans = 'EXCHANGE_S_ENTERPRISE, SHAREPOINTENTERPRISE, TEAMS1' }
    if ($isTarget) { & $add 'licenses' @{ SKU = 'O365_BUSINESS_PREMIUM'; SkuId = Get-FakeId; State = 'Enabled'; Purchased = 295; Consumed = 20; Available = 275; Suspended = 0; 'In warning' = 0; Plans = 'EXCHANGE_S_STANDARD, TEAMS1' } }
    $phoneUsed = if ($isTarget) { 8 } else { 4 }
    & $add 'licenses' @{ SKU = 'MCOEV'; SkuId = Get-FakeId; State = 'Enabled'; Purchased = 10; Consumed = $phoneUsed; Available = 10 - $phoneUsed; Suspended = 0; 'In warning' = 0; Plans = 'MCOEV' }
    & $add 'licenses' @{ SKU = 'Microsoft_365_Copilot'; SkuId = Get-FakeId; State = 'Enabled'; Purchased = 5; Consumed = 3; Available = 2; Suspended = 0; 'In warning' = 0; Plans = 'M365_COPILOT_APPS' }

    & $add 'groups' @{ Id = Get-FakeId; Name = 'Finance'; Type = 'Microsoft 365'; Team = $true; Dynamic = $false; Visibility = 'Private'; Synced = $false; 'Group licenses' = 0; Owners = 1; Email = "finance@$domain"; Alias = 'finance'; Created = Get-FakeDate 600; Members = 12 }
    & $add 'groups' @{ Id = Get-FakeId; Name = 'All Staff Dynamic'; Type = 'Security'; Team = $false; Dynamic = $true; Visibility = 'Private'; Synced = $false; 'Group licenses' = 1; Owners = 0; Alias = 'allstaff'; Created = Get-FakeDate 700; Members = 40 }
    & $add 'groupSettings' @{ Setting = 'Group.Unified.EnableGroupCreation'; Value = 'true' }
    foreach ($row in Get-FakeSetting 'securitySettings' ([ordered]@{ 'Security defaults enabled' = $false; 'Invitations allowed from' = 'everyone'; 'User permissions.allowedToCreateApps' = $true })) { $tables['securitySettings'].Add($row) }

    for ($i = 0; $i -lt 6; $i++) { & $add 'adminRoles' @{ Role = 'Global Administrator'; Principal = $upns[$i]; 'Principal type' = 'user'; Assignment = 'Active'; Scope = '/' } }
    & $add 'adminRoles' @{ Role = 'Global Administrator'; Principal = "vendor_partner.example#EXT#@$initial"; 'Principal type' = 'user'; Assignment = 'Active'; Scope = '/' }
    & $add 'adminRoles' @{ Role = 'Exchange Administrator'; Principal = $upns[1]; 'Principal type' = 'user'; Assignment = 'Eligible'; Scope = '/' }

    $mfaForAll = $role -eq 'S1'
    & $add 'conditionalAccess' @{ Name = 'Require MFA'; State = $(if ($mfaForAll) { 'enabled' } else { 'enabledForReportingButNotEnforced' }); Users = 'All'; Exclusions = 1; Applications = 'All'; 'Client apps' = 'all'; Controls = 'mfa (OR)'; 'MFA for all' = $mfaForAll; 'Blocks legacy authentication' = $false }
    & $add 'conditionalAccess' @{ Name = 'Report only sign-in risk'; State = 'enabledForReportingButNotEnforced'; Users = 'All'; Exclusions = 0; Applications = 'All'; 'Client apps' = 'all'; Controls = 'mfa (OR)'; 'MFA for all' = $false; 'Blocks legacy authentication' = $false }
    & $add 'namedLocations' @{ Name = 'Head office'; Type = 'ipNamedLocation'; Trusted = $true; 'Ranges or countries' = '192.0.2.0/24' }

    foreach ($row in Get-FakeSetting 'crossTenantSettings' ([ordered]@{ 'Default.inboundTrust' = $null; 'Multitenant organization' = 'none' })) { $tables['crossTenantSettings'].Add($row) }
    foreach ($partner in $partners) {
        if ($isTarget -and $partner['Role'] -eq 'S2') { continue }
        & $add 'crossTenantPartners' @{ Tenant = $partner['TenantId']; Name = $partner['Name']; Domain = "$($partner['Slug']).example"; 'MFA trusted' = $true; 'Compliant device trusted' = $false; 'Inbound collaboration' = 'allowed'; 'Outbound collaboration' = 'allowed'; 'Inbound auto-redeem' = $true; 'Outbound auto-redeem' = $true; 'Inbound sync' = $false }
    }

    & $add 'applications' @{ Name = 'Payroll connector'; AppId = Get-FakeId; Created = Get-FakeDate 800; Audience = 'AzureADMyOrg'; Secrets = 1; Certificates = 0; 'Days to expiry' = 20; Expired = 0 }
    & $add 'applications' @{ Name = 'Old intranet'; AppId = Get-FakeId; Created = Get-FakeDate 1500; Audience = 'AzureADMyOrg'; Secrets = 1; Certificates = 1; 'Days to expiry' = $null; Expired = 2 }
    $thirdParty = Get-FakeId
    & $add 'servicePrincipals' @{ Name = 'Vendor Sync'; AppId = Get-FakeId; Publisher = 'Fictional Vendor'; Origin = 'Third party'; Enabled = $true; Type = 'Application'; Id = $thirdParty }
    & $add 'servicePrincipals' @{ Name = 'Payroll connector'; AppId = Get-FakeId; Publisher = $Definition['Name']; Origin = 'Internal'; Enabled = $true; Type = 'Application'; Id = Get-FakeId }
    & $add 'servicePrincipals' @{ Name = 'Office 365 Exchange Online'; AppId = Get-FakeId; Publisher = 'Microsoft'; Origin = 'Microsoft'; Enabled = $true; Type = 'Application'; Id = Get-FakeId }
    & $add 'delegatedConsents' @{ Application = 'Vendor Sync'; 'Consent type' = 'Administrator (all)'; Scopes = 'Mail.Read User.Read'; User = $null }
    & $add 'delegatedConsents' @{ Application = 'Vendor Sync'; 'Consent type' = 'User'; Scopes = 'User.Read'; User = $firstUpn }
    & $add 'applicationPermissions' @{ Application = 'Vendor Sync'; Origin = 'Third party'; Resource = 'Microsoft Graph'; Permission = 'Mail.ReadWrite'; 'Granted on' = Get-FakeDate 500 }
    & $add 'devices' @{ Name = 'LAPTOP-01'; OS = 'Windows'; Version = '10.0.22631'; 'Join type' = 'Entra ID'; Compliant = $true; Managed = $true; Enabled = $true; 'Last sign-in' = Get-FakeDate 5; 'Days inactive' = 5 }
    & $add 'devices' @{ Name = 'LAPTOP-OLD'; OS = 'Windows'; Version = '10.0.19045'; 'Join type' = 'Hybrid'; Compliant = $false; Managed = $false; Enabled = $true; 'Last sign-in' = Get-FakeDate 240; 'Days inactive' = 240 }
    foreach ($n in 2..5) { & $add 'devices' @{ Name = "LAPTOP-OLD-$n"; OS = 'Windows'; Version = '10.0.19045'; 'Join type' = 'Hybrid'; Compliant = $false; Managed = $false; Enabled = $true; 'Last sign-in' = Get-FakeDate (100 * $n); 'Days inactive' = 100 * $n } }
    foreach ($row in @(
            @{ Dimension = 'Client app'; Value = 'Browser'; 'Sign-ins' = 900; Users = 20 }, @{ Dimension = 'Client app'; Value = 'IMAP4'; 'Sign-ins' = 12; Users = 2 }
            @{ Dimension = 'Country'; Value = 'CA'; 'Sign-ins' = 880; Users = 20 }, @{ Dimension = 'Country'; Value = 'FR'; 'Sign-ins' = 32; Users = 3 }
            @{ Dimension = 'Result'; Value = 'Success'; 'Sign-ins' = 890; Users = 20 }, @{ Dimension = 'Result'; Value = 'Failure'; 'Sign-ins' = 22; Users = 4 })) { & $add 'signInSummary' $row }
    & $add 'legacySignIns' @{ UPN = $firstUpn; Client = 'IMAP4'; 'Sign-ins' = 12; Last = Get-FakeDate 1 }
    & $add 'riskyUsers' @{ UPN = $upns[2]; Level = 'high'; State = 'atRisk'; Detail = 'none'; Updated = Get-FakeDate 3 }

    # Exchange
    foreach ($row in Get-FakeSetting 'exchangeSettings' ([ordered]@{ 'Organization.DisplayName' = $Definition['Name']; 'Unified audit log enabled' = ($role -ne 'S1'); 'Transport.SmtpClientAuthenticationDisabled' = $false })) { $tables['exchangeSettings'].Add($row) }
    & $add 'acceptedDomains' @{ Domain = $domain; Type = 'Authoritative'; Default = $true }
    & $add 'acceptedDomains' @{ Domain = $initial; Type = 'Authoritative'; Default = $false }
    & $add 'remoteDomains' @{ Name = 'Default'; Domain = '*'; 'Auto-forward' = $true; 'Automatic replies' = 'External' }
    & $add 'exchangeHybrid' @{ Item = 'Intra-organization connector'; Name = 'HybridIOC'; Detail = "$domain - enabled True" }
    & $add 'organizationRelationships' @{ Name = 'Partner free/busy'; Domains = "$($partners[0]['Slug']).example"; 'Free/busy' = $true; Level = 'LimitedDetails'; Enabled = $true }
    & $add 'sharingPolicies' @{ Name = 'Default Sharing Policy'; Domains = 'Anonymous:CalendarSharingFreeBusySimple'; Default = $true; Enabled = $true }
    & $add 'emailAddressPolicies' @{ Name = 'Default Policy'; Priority = 'Lowest'; Templates = "SMTP:@$domain"; Filter = 'Alias -ne $null' }
    & $add 'mrmPolicies' @{ Name = 'Default MRM Policy'; Default = $true; Tags = '1 Month Delete' }
    & $add 'archives' @{ UPN = $firstUpn; 'Size GB' = 12.4; Items = 25000 }
    & $add 'inactiveMailboxes' @{ Name = 'Departed User'; Address = "departed@$domain"; Type = 'UserMailbox' }
    & $add 'mailboxPermissions' @{ Mailbox = "info@$domain"; User = $firstUpn; Right = 'FullAccess' }
    & $add 'mailboxPermissions' @{ Mailbox = "info@$domain"; User = $upns[1]; Right = 'SendAs' }
    & $add 'distributionGroups' @{ Name = 'All Staff'; Address = "allstaff@$domain"; Alias = 'allstaff'; Type = 'MailUniversalDistributionGroup'; 'External senders allowed' = $true; Managers = $firstUpn; Hidden = $false; Members = 25 }
    & $add 'dynamicGroups' @{ Name = 'Montreal Staff'; Address = "montreal@$domain"; Filter = 'City -eq Montreal' }
    & $add 'microsoft365Groups' @{ Name = 'Finance'; Address = "finance@$domain"; Alias = 'finance'; Access = 'Private'; Team = $true; Members = 12; Guests = 1; Site = "https://$tenantName.sharepoint.com/sites/finance"; Created = Get-FakeDate 600 }
    & $add 'contacts' @{ Name = 'Outside Counsel'; 'External address' = 'counsel@law.example'; Type = 'Contact' }
    & $add 'contacts' @{ Name = 'Consultant'; 'External address' = 'consultant@advice.example'; Type = 'Mail user' }
    & $add 'transportRules' @{ Name = 'Disclaimer'; State = 'Enabled'; Priority = 0; Mode = 'Enforce'; Description = 'Adds a disclaimer' }
    & $add 'connectors' @{ Name = 'Gateway inbound'; Direction = 'Inbound'; Enabled = $true; Type = 'Partner'; Domains = '*'; 'Hosts or IPs' = '192.0.2.10'; TLS = 'True' }
    & $add 'journalRules' @{ Name = 'Archive journal'; Recipient = ''; 'Journal address' = 'journal@archive.example'; Scope = 'Global'; Enabled = $true }
    & $add 'dkim' @{ Domain = $domain; Enabled = $false; 'Selector 1' = "selector1-$slug._domainkey.$initial"; 'Selector 2' = "selector2-$slug._domainkey.$initial" }
    & $add 'protectionPolicies' @{ Type = 'Inbound anti-spam'; Name = 'Default'; Default = $true; Enabled = $true }
    & $add 'mobileDevices' @{ User = 'Ana Silva'; Model = 'Phone 12'; System = 'iOS 17'; Type = 'iPhone'; Client = 'EAS'; Access = 'Allowed'; 'First sync' = Get-FakeDate 300 }
    & $add 'inboxRules' @{ Mailbox = $upns[1]; Rule = 'Forward to personal'; Enabled = $true; To = 'personal@mail.example'; External = $true }
    & $add 'roomsAndEquipment' @{ Resource = 'Boardroom'; Address = "room.one@$domain"; Type = 'RoomMailbox'; Processing = 'AutoAccept'; 'Open to all' = $true; 'Booking window (days)' = 180; 'Max duration (min)' = 1440; Delegates = 0; 'External accepted' = $false }
    & $add 'publicFolders' @{ Path = '\Archive'; Name = 'Archive'; Email = $false; 'Content mailbox' = 'PF1'; Subfolders = $false }

    # SharePoint and OneDrive
    $sharing = if ($isTarget) { 'ExternalUserSharingOnly' } else { 'ExternalUserAndGuestSharing' }
    foreach ($row in Get-FakeSetting 'sharePointSettings' ([ordered]@{ SharingCapability = $sharing; StorageQuota = $(if ($isTarget) { 358400 } else { 1048576 + 1024 * $Definition['Rank'] }) })) { $tables['sharePointSettings'].Add($row) }
    $hub = Get-FakeId
    foreach ($site in @(
            @{ Url = "https://$tenantName.sharepoint.com/sites/finance"; Title = 'Finance'; Template = 'GROUP#0'; Storage = 2048; Days = 10; Group = Get-FakeId; Teams = $true }
            @{ Url = "https://$tenantName.sharepoint.com/sites/projects"; Title = 'Projects'; Template = 'SITEPAGEPUBLISHING#0'; Storage = 153600; Days = 3; Group = $null; Teams = $false }
            @{ Url = "https://$tenantName.sharepoint.com/sites/old-$slug"; Title = 'Old intranet'; Template = 'STS#0'; Storage = 1; Days = 720; Group = $null; Teams = $false }
            @{ Url = "https://$tenantName.sharepoint.com/"; Title = 'Home'; Template = 'SITEPAGEPUBLISHING#0'; Storage = 300; Days = 2; Group = $null; Teams = $false }
            @($tenantDefinitions | Where-Object { $isTarget -and $_['Rank'] -eq 1 } | ForEach-Object { @{ Url = "https://$tenantName.sharepoint.com/sites/$($_['Slug'])-finance"; Title = 'Prefixed finance'; Template = 'GROUP#0'; Storage = 40; Days = 4; Group = Get-FakeId; Teams = $false } }))) {
        & $add 'sites' @{
            Url = $site['Url']; Path = ([uri]$site['Url']).AbsolutePath.TrimEnd('/').ToLowerInvariant(); Title = $site['Title']; Template = $site['Template']; 'Storage MB' = [double]$site['Storage']; 'Quota MB' = 1048576.0
            'Last modified' = Get-FakeDate $site['Days']; 'Days inactive' = $site['Days']; Sharing = $sharing; 'Lock state' = 'Unlock'; Owner = $firstUpn; Group = $site['Group']; Teams = $site['Teams']; Hub = $site['Title'] -eq 'Home'
            'Hub association' = $(if ($site['Title'] -eq 'Projects') { $hub }); Label = $(if (-not $isTarget -and $site['Title'] -eq 'Finance') { 'Confidential' } else { '' }); 'Custom scripts' = $site['Template'] -eq 'STS#0'; Language = 1033
        }
        & $add 'siteUsage' @{ Url = $site['Url']; Owner = $firstUpn; Template = $site['Template']; Files = 1000; 'Active files' = 10; 'Storage GB' = [math]::Round($site['Storage'] / 1024, 2); 'Page views' = 25; 'Last activity' = $today.ToString('yyyy-MM-dd') }
        & $add 'libraries' @{ Site = $site['Url']; List = 'Documents'; Template = 'documentLibrary'; 'Size MB' = [double]$site['Storage']; 'Last modified' = Get-FakeDate $site['Days'] }
    }
    & $add 'hubSites' @{ Title = 'Home'; Url = "https://$tenantName.sharepoint.com/"; 'Associated sites' = 1 }
    & $add 'sharePointCustomizations' @{ Type = 'App catalog'; Name = "https://$tenantName.sharepoint.com/sites/appcatalog"; Detail = '' }
    & $add 'sharePointCustomizations' @{ Type = 'SPFx app'; Name = 'Fictional web part'; Detail = 'deployed True - version 1.0.0.0' }
    & $add 'termStore' @{ Group = 'Departments'; 'Term set' = 'Offices'; Terms = 4; 'System or collection' = $false }
    & $add 'oneDriveUsage' @{ Url = "https://$tenantName-my.sharepoint.com/personal/ana_silva"; Owner = $firstUpn; Files = 300; 'Active files' = 12; 'Storage GB' = 3.2; 'Last activity' = $today.ToString('yyyy-MM-dd') }
    & $add 'sharePointExternalUsers' @{ Name = 'Outside Reviewer'; Email = 'reviewer@agency.example'; 'Accepted as' = 'reviewer@agency.example'; 'Invited by' = $firstUpn; Created = Get-FakeDate 90 }

    # Teams
    foreach ($team in @(@{ Name = 'Finance'; Owners = 1; Private = 1; Shared = 0; Archived = $false }, @{ Name = "Site $($Definition['Name'])"; Owners = 2; Private = 0; Shared = 1; Archived = $true })) {
        & $add 'teams' @{ Id = Get-FakeId; Name = $team['Name']; Visibility = 'Private'; Archived = $team['Archived']; Alias = ($team['Name'] -replace '\s', '').ToLowerInvariant(); Description = 'Fictional team' }
        & $add 'teamActivity' @{ Team = $team['Name']; Type = 'Private'; 'Last activity' = $today.ToString('yyyy-MM-dd'); 'Active users' = 5; Guests = 1; 'Channel messages' = 120; Meetings = 4 }
        & $add 'teamComposition' @{ Team = $team['Name']; Owners = $team['Owners']; Members = 8; Guests = 1; 'Standard channels' = 3; 'Private channels' = $team['Private']; 'Shared channels' = $team['Shared'] }
        & $add 'channels' @{ Team = $team['Name']; Channel = 'General'; Type = 'Standard' }
    }
    if ($isTarget) { & $add 'teams' @{ Id = Get-FakeId; Name = "$($partners[0]['Slug']) - Site $($partners[0]['Name'])"; Visibility = 'Private'; Archived = $false; Alias = 'prefixedsite'; Description = 'Fictional team' } }
    foreach ($row in Get-FakeSetting 'teamsSettings' ([ordered]@{ 'External access.AllowFederatedUsers' = ($role -ne 'S2'); 'External access.AllowedDomains' = $(if ($isTarget) { "$($partners[0]['Slug']).example" } else { 'AllowAllKnownDomains' }) })) { $tables['teamsSettings'].Add($row) }
    & $add 'teamsPolicies' @{ Type = 'TeamsMeetingPolicy'; Identity = 'Global'; Custom = $false; Description = '' }
    & $add 'teamsPolicies' @{ Type = 'TeamsMeetingPolicy'; Identity = "Tag:$slug-Executives"; Custom = $true; Description = 'Fictional policy' }
    & $add 'teamsApps' @{ Name = 'Fictional line-of-business app'; Version = '1.2.0'; Publishing = 'published'; Distribution = 'organization' }
    & $add 'teamsDevices' @{ Type = 'ipPhone'; Model = 'Fictional Phone 100'; User = 'Boardroom'; State = 'healthy'; Activity = 'active' }

    # Teams Phone
    if ($hasPhone) {
        & $add 'phoneNumbers' @{ Number = (Get-FakeNumber $Definition['Rank'] 22); Type = 'DirectRouting'; Activation = 'Activated'; Assignment = 'UserAssigned'; 'Assigned to' = $firstUpn; Capabilities = 'UserAssignment'; City = 'Montreal'; Country = 'CA'; Partner = 'Fictional Carrier'; Porting = ''; Source = 'OnPremises'; 'Emergency address' = '' }
        & $add 'resourceAccounts' @{ UPN = "attendant@$domain"; Name = 'Main line'; Number = (Get-FakeNumber $Definition['Rank'] 24); Usage = 'Auto attendant'; ObjectId = Get-FakeId }
        & $add 'autoAttendants' @{ Name = 'Main line'; Language = 'en-US'; 'Time zone' = 'Eastern Standard Time'; 'Resource accounts' = 'Main line'; 'Call flows' = 2; Schedules = 1; Operator = 'User'; 'Directory lookup' = 'All'; Identity = Get-FakeId }
        & $add 'callQueues' @{ Name = 'Reception'; Routing = 'Attendant'; Agents = 3; Lists = 0; 'Teams channel' = $false; Overflow = 'DisconnectWithBusy after 50'; Expiration = 'Disconnect after 1200 s'; 'Resource accounts' = 'Main line'; Presence = $true }
        & $add 'pstnGateways' @{ FQDN = $(if ($role -eq 'S3') { 'sbc.carrier.example' } else { "sbc.$domain" }); Port = 5061; Enabled = $true; 'Max sessions' = 100 }
        & $add 'voiceRoutes' @{ Name = 'Local'; Pattern = '^\+1'; Gateways = "sbc.$domain"; Usages = 'Local'; Priority = 1 }
        & $add 'voiceRoutingPolicies' @{ Name = 'Tag:Local'; 'PSTN usages' = 'Local' }
        & $add 'dialPlans' @{ Name = 'Tag:Montreal'; Rules = 3; Description = 'Fictional plan' }
        & $add 'translationRules' @{ Name = 'AddPlusOne'; Pattern = '^(\d{10})$'; Translation = '+1$1' }
        & $add 'emergencyAddresses' @{ Description = 'Head office'; Company = $Definition['Name']; Address = '100 Example Street'; City = 'Montreal'; 'State or province' = 'QC'; 'Postal code' = 'H0H 0H0'; Country = 'CA'; Validation = 'Validated'; Locations = 1 }
        & $add 'conferenceBridges' @{ Name = 'Conference Bridge'; 'Default number' = (Get-FakeNumber $Definition['Rank'] 23); Numbers = (Get-FakeNumber $Definition['Rank'] 23) }
        & $add 'userCallingSettings' @{ UPN = $firstUpn; Forwarding = 'Immediate to voicemail'; Unanswered = 'Voicemail after 00:00:20'; Delegates = ''; 'Call group' = '' }
        & $add 'phoneSchedules' @{ Name = 'Business hours'; Type = 'Weekly (business hours)'; 'Used by' = 1 }
        & $add 'phoneNetworkTopology' @{ Type = 'Network site'; Name = 'Head office'; Detail = 'Fictional site' }
    }

    # Intune
    if ($hasIntune) {
        & $add 'managedDevices' @{ Name = 'LAPTOP-01'; OS = 'Windows'; Version = '10.0.22631'; Compliance = 'compliant'; Ownership = 'company'; Enrollment = 'windowsAzureADJoin'; 'Last sync' = Get-FakeDate 2; 'Days inactive' = 2; Model = 'Fictional 14'; Manufacturer = 'Example Devices'; 'Serial number' = "SN$($Definition['Rank'])01"; User = $firstUpn; Encrypted = $true }
        & $add 'managedDevices' @{ Name = 'LAPTOP-02'; OS = 'Windows'; Version = '10.0.19045'; Compliance = 'noncompliant'; Ownership = 'company'; Enrollment = 'windowsAzureADJoin'; 'Last sync' = Get-FakeDate 45; 'Days inactive' = 45; Model = 'Fictional 14'; Manufacturer = 'Example Devices'; 'Serial number' = "SN$($Definition['Rank'])02"; User = $upns[1]; Encrypted = $false }
        & $add 'managedDevices' @{ Name = 'LAPTOP-03'; OS = 'Windows'; Version = '10.0.19045'; Compliance = 'compliant'; Ownership = 'company'; Enrollment = 'windowsAzureADJoin'; 'Last sync' = Get-FakeDate 120; 'Days inactive' = 120; Model = 'Fictional 14'; Manufacturer = 'Example Devices'; 'Serial number' = "SN$($Definition['Rank'])03"; User = $firstUpn; Encrypted = $true }
        & $add 'autopilotDevices' @{ 'Serial number' = "SN$($Definition['Rank'])01"; Model = 'Fictional 14'; Manufacturer = 'Example Devices'; 'Group tag' = 'Standard'; 'Enrollment state' = 'enrolled'; 'Last contact' = Get-FakeDate 2 }
        if (-not $isTarget) { & $add 'autopilotProfiles' @{ Name = 'Standard'; Type = 'azureADWindowsAutopilotDeploymentProfile'; 'Device name template' = 'LAPTOP-%RAND:4%'; Created = Get-FakeDate 400 } }
        & $add 'intunePolicies' @{ Category = 'Compliance'; Name = 'Windows baseline'; Platform = 'windows10'; Assignments = 1; Modified = Get-FakeDate 100 }
        & $add 'intunePolicies' @{ Category = 'Configuration'; Name = 'Unassigned profile'; Platform = 'windows10'; Assignments = 0; Modified = Get-FakeDate 200 }
        & $add 'intuneApps' @{ Name = 'Fictional client'; Type = 'win32LobApp'; Publisher = 'Example Software'; Assigned = $true; Created = Get-FakeDate 300 }
        & $add 'appProtectionPolicies' @{ Name = 'Mobile protection'; Type = 'iosManagedAppProtection'; Modified = Get-FakeDate 150 }
        & $add 'intuneConnectors' @{ Type = 'Apple MDM certificate (APNs)'; Name = 'com.apple.mgmt.External'; Account = "admin@$domain"; Expiration = Get-FakeDate -20; 'Days remaining' = 20 }
    }

    # Purview
    & $add 'sensitivityLabels' @{ Name = 'Confidential'; 'Display name' = 'Confidential'; Parent = ''; Priority = 1; Scope = 'File, Email'; Encryption = $true; Marking = $true; Disabled = $false }
    if (-not $isTarget) { & $add 'sensitivityLabels' @{ Name = "$slug-internal"; 'Display name' = "$($Definition['Name']) internal"; Parent = ''; Priority = 2; Scope = 'File'; Encryption = $false; Marking = $true; Disabled = $false } }
    & $add 'labelPolicies' @{ Name = 'Default labels'; Labels = 'Confidential'; Locations = 'All'; Status = 'Success' }
    & $add 'retentionPolicies' @{ Name = 'Keep seven years'; Enabled = $true; Mode = 'Enforce'; Locations = 'Exchange: All'; Status = 'Success' }
    & $add 'retentionLabels' @{ Name = 'Records'; Action = 'Keep'; Duration = '2555'; Record = $true }
    & $add 'dlpPolicies' @{ Name = 'Personal data'; Mode = 'Enable'; Enabled = $true; Workloads = 'Exchange, SharePoint' }
    & $add 'ediscoveryCases' @{ Name = 'Fictional case'; Status = 'Active'; Type = 'eDiscovery'; Holds = 1; Created = Get-FakeDate 100 }

    # Power Platform and Azure
    & $add 'powerEnvironments' @{ Name = 'Default'; Type = 'Default'; Region = 'canada'; Default = $true; Dataverse = $false; Created = '2020-01-01' }
    & $add 'powerEnvironments' @{ Name = 'Production'; Type = 'Production'; Region = 'canada'; Default = $false; Dataverse = ($role -ne 'S2'); Created = '2022-01-01' }
    & $add 'powerApps' @{ Name = 'Expense claims'; Environment = 'Production'; Owner = $firstUpn; Modified = '2025-06-01' }
    & $add 'powerFlows' @{ Name = 'Invoice approval'; Environment = 'Production'; Owner = $firstUpn; Enabled = $true; Modified = '2025-06-01' }
    & $add 'powerDlpPolicies' @{ Name = 'Tenant policy'; Scope = 'AllEnvironments'; Environments = '' }
    if (-not $isTarget) {
        & $add 'azureSubscriptions' @{ Name = 'Fictional subscription'; Id = Get-FakeId; State = 'Enabled'; 'RBAC assignments' = 4 }
        & $add 'azureResources' @{ Subscription = 'Fictional subscription'; Type = 'Microsoft.DesktopVirtualization/hostPools'; Count = 1; Regions = 'canadacentral' }
    }

    # Other services
    foreach ($row in Get-FakeSetting 'reportSettings' ([ordered]@{ 'Names concealed in reports' = $true })) { $tables['reportSettings'].Add($row) }
    foreach ($row in Get-FakeSetting 'secureScore' ([ordered]@{ 'Current score' = 30 + $Definition['Rank'] * 5; 'Maximum score' = 100; Percentage = 30 + $Definition['Rank'] * 5; Date = Get-FakeDate 1 })) { $tables['secureScore'].Add($row) }
    & $add 'secureScoreActions' @{ Control = 'Require MFA for administrators'; Category = 'Identity'; Score = 0; Maximum = 10; 'Possible gain' = 10; Cost = 'Low'; 'User impact' = 'Low'; Service = 'Azure AD' }
    & $add 'plannerPlans' @{ Group = 'Finance'; Plan = 'Quarter close'; Created = Get-FakeDate 200 }
    & $add 'bookings' @{ Name = 'Front desk'; Email = "frontdesk@$domain"; Type = 'Company'; Published = $true }
    & $add 'vivaCommunities' @{ Name = 'All Company'; Privacy = 'Public'; Description = 'Fictional community' }
    foreach ($product in 'Microsoft Forms', 'Loop', 'Whiteboard') { & $add 'manualProducts' @{ Product = $product; Inventory = 'No administration API'; Migration = 'Not covered by the usual copy tools'; 'To do' = 'List what is in use' } }

    # Domains and DNS
    $thirdPartyMail = $role -eq 'S1'
    & $add 'publicDns' @{ Domain = $domain; Record = $domain; Type = 'NS'; Value = 'ns1.dnshost.example'; TTL = 3600 }
    & $add 'publicDns' @{ Domain = $domain; Record = $domain; Type = 'MX'; Value = "10 mx.$domain"; TTL = 86400 }
    & $add 'dnsSummary' @{
        Domain = $domain; 'DNS host' = $(if ($isTarget) { 'Azure DNS' } else { 'Fictional DNS host' }); MX = "mx.$domain"; 'Inbound mail flow' = $(if ($thirdPartyMail) { 'Third-party gateway' } else { 'Exchange Online direct' })
        'MX TTL' = 86400; SPF = $(if ($thirdPartyMail) { 'Missing' } else { 'Multiple (invalid)' }); 'Microsoft SPF' = -not $thirdPartyMail; DMARC = $(if ($thirdPartyMail) { 'Missing' } else { 'none' }); 'DKIM published' = $false
        Autodiscover = "autodiscover.$domain"; 'Teams or legacy Skype' = $true; 'Intune enrollment' = $hasIntune
    }

    [ordered]@{ displayName = $Definition['Name']; primaryDomain = $domain; tenantId = $Definition['TenantId']; tables = $tables }
}

$tenants = [ordered]@{}
foreach ($definition in $tenantDefinitions) { $tenants[$definition['Role']] = Get-FakeTenant -Definition $definition }

# Coverage: one line per collector of each tenant. S1 shows the three kinds of gap, S2 has no Entra ID P2,
# and S3 lost one collector of a workload that was otherwise read.
$missingLicense = $dictionary['riskyUsers']['collectors'][0]
$lostPart = $dictionary['teamActivity']['collectors'][0]
$collectorRows = [ordered]@{}
foreach ($key in $dictionary.Keys) {
    foreach ($id in $dictionary[$key]['collectors']) {
        if (-not $collectorRows.Contains($id)) { $collectorRows[$id] = [ordered]@{ workload = $dictionary[$key]['workload']; tables = [System.Collections.Generic.List[string]]::new() } }
        $collectorRows[$id]['tables'].Add($key)
    }
}

$coverage = foreach ($definition in $tenantDefinitions) {
    $role = $definition['Role']
    foreach ($id in $collectorRows.Keys) {
        $status = 'OK'
        $message = ''
        $remedy = ''
        if ($role -eq 'S1' -and $id -eq 'POW-01') {
            $status = 'Insufficient access'
            $message = 'Forbidden'
            $remedy = 'Give the account the Power Platform Administrator role.'
            foreach ($table in $collectorRows[$id]['tables']) { $tenants[$role]['tables'].Remove($table) }
        }
        if ($role -eq 'S1' -and $id -eq 'ENT-05') {
            $status = 'Partial'
            $message = 'Eligible roles (PIM, Entra ID P2 license): License or service missing'
            $remedy = 'The service or license is not in this tenant.'
        }
        if ($role -eq 'S2' -and $id -eq $missingLicense) {
            $status = 'License or service missing'
            $message = 'This tenant has no Entra ID P2 license.'
            $remedy = 'The service or license is not in this tenant.'
            foreach ($table in $collectorRows[$id]['tables']) { $tenants[$role]['tables'].Remove($table) }
        }
        if ($role -eq 'S3' -and $id -eq $lostPart) {
            $status = 'Module missing'
            $message = 'The module is not installed.'
            $remedy = 'Install the module.'
            foreach ($table in $collectorRows[$id]['tables']) { $tenants[$role]['tables'].Remove($table) }
        }
        $tables = @($collectorRows[$id]['tables'] | Where-Object { $tenants[$role]['tables'].Contains($_) })
        [ordered]@{
            role = $role; tenant = $definition['Name']; id = $id; workload = $collectorRows[$id]['workload']; title = "Fictional collector $id"; service = 'Fictional'
            status = $status; message = $message; remedy = $remedy; duration = 1.5; rows = (@($tables | ForEach-Object { $tenants[$role]['tables'][$_].Count }) | Measure-Object -Sum).Sum; tables = $tables
        }
    }
}

$snapshot = [ordered]@{
    schemaVersion = 1
    meta          = [ordered]@{ project = 'Summit consolidation'; started = '2026-01-15T08:00:00'; finished = '2026-01-15T09:00:00'; moduleVersion = [string]$module.Version; depth = 'Complete' }
    coverage      = @($coverage)
    tenants       = $tenants
}

if ($Path) {
    $folder = Split-Path -Path $Path -Parent
    if ($folder) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    & $module { param($Path, $Snapshot) Write-TcSnapshot -Path $Path -Snapshot $Snapshot } $Path $snapshot
}
else {
    $snapshot
}

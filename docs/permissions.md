# Permissions

The assessment only reads. This page lists what it asks for, in each sign-in mode, and how remediations differ. None of this has been tried on a real tenant: see [limitations](limitations.md).

## Browser sign-in

Each service opens a sign-in window for each tenant. You sign in with your own account, and TenantConverge checks that the session is on the right tenant before it reads anything. It refuses a session on another tenant.

| Service | Role the account needs | Used for |
|---|---|---|
| Microsoft Graph | Global Administrator or Global Reader, and consent to the permissions below, once per tenant | Identities, domains, Intune, reports |
| Exchange Online | Exchange Administrator, Global Reader or Global Administrator | Mailboxes, mail flow |
| Purview | Compliance Administrator, Global Reader or Global Administrator | Labels, retention, data loss prevention, eDiscovery |
| Teams | Teams Administrator or Teams Communications Administrator, Global Reader or Global Administrator | Teams and Teams Phone |
| SharePoint | SharePoint Administrator or Global Administrator, and a PnP application in the tenant | Sites, OneDrive |
| Power Platform | Power Platform Administrator or Global Administrator | Environments, apps, flows |
| Azure | Reader on the subscriptions. A Global Administrator must first turn on `Access management for Azure resources` in Entra ID | Subscriptions, resources |

Delegated Microsoft Graph permissions of the assessment:

`AppCatalog.Read.All`, `Application.Read.All`, `AuditLog.Read.All`, `Bookings.Read.All`, `Channel.ReadBasic.All`, `Community.Read.All`, `CrossTenantInformation.ReadBasic.All`, `Device.Read.All`, `DeviceManagementApps.Read.All`, `DeviceManagementConfiguration.Read.All`, `DeviceManagementManagedDevices.Read.All`, `DeviceManagementRBAC.Read.All`, `DeviceManagementScripts.Read.All`, `DeviceManagementServiceConfig.Read.All`, `Directory.Read.All`, `Domain.Read.All`, `Group.Read.All`, `GroupMember.Read.All`, `IdentityRiskyUser.Read.All`, `MultiTenantOrganization.Read.All`, `OnPremDirectorySynchronization.Read.All`, `Organization.Read.All`, `Policy.Read.All`, `Reports.Read.All`, `ReportSettings.Read.All`, `RoleEligibilitySchedule.Read.Directory`, `RoleManagement.Read.Directory`, `SecurityEvents.Read.All`, `Sites.Read.All`, `Tasks.Read`, `Team.ReadBasic.All`, `TeamSettings.Read.All`, `TeamworkDevice.Read.All`, `User.Read.All`, `UserAuthenticationMethod.Read.All`

When that consent is refused, TenantConverge tries again with a smaller set, and the coverage shows what it could not read:

`AuditLog.Read.All`, `DeviceManagementServiceConfig.Read.All`, `Directory.Read.All`, `Domain.Read.All`, `Group.Read.All`, `Organization.Read.All`, `Policy.Read.All`, `Reports.Read.All`, `RoleManagement.Read.Directory`, `User.Read.All`, `UserAuthenticationMethod.Read.All`

### The PnP application

SharePoint has no shared sign-in application, so each tenant needs its own. `Initialize-TcAccess -DelegatedPnP` registers `TenantConverge PnP`, with these delegated permissions:

- SharePoint: `AllSites.FullControl`, `TermStore.Read.All`, `User.Read.All`
- Microsoft Graph: `Group.Read.All`, `User.Read.All`, `Sites.Read.All`

`AllSites.FullControl` is a broad permission. The collectors only read, and each sign-in is limited to what the account signing in may do.

In a browser project, that application is all the command creates: no certificate and no read-only application. It signs in once with `Organization.Read.All` to find the initial domain of the tenant, and the registration then opens its own sign-in. In an application project, it comes on top of the read-only application.

## Application sign-in

`Initialize-TcAccess` needs a Global Administrator, once per tenant. It signs in with these delegated permissions, for that command only: `Application.ReadWrite.All`, `AppRoleAssignment.ReadWrite.All`, `RoleManagement.ReadWrite.Directory` and `Organization.Read.All`. It then:

1. creates a self-signed certificate in the store of the current user, with a key that cannot be exported;
2. creates the `TenantConverge Read-Only` application, or reuses the one this project created, and adds the certificate;
3. requests the permissions below;
4. with `-GrantAdminConsent` only, grants them and assigns the Global Reader role;
5. saves the identifiers in `<project>.access.local.json`.

Anyone allowed to register an application can give one that name. So the command stops, and changes nothing in that tenant, when an application of that name exists that this project did not create, or when the application holds a credential TenantConverge did not add. `Remove-TcAccess` deletes only the applications whose ID is in the access file, and tells you about any other of the same name.

Application permissions on Microsoft Graph:

`AppCatalog.Read.All`, `Application.Read.All`, `AuditLog.Read.All`, `Bookings.Read.All`, `Channel.ReadBasic.All`, `ChannelMember.Read.All`, `ChannelSettings.Read.All`, `Community.Read.All`, `CrossTenantInformation.ReadBasic.All`, `Device.Read.All`, `DeviceManagementApps.Read.All`, `DeviceManagementConfiguration.Read.All`, `DeviceManagementManagedDevices.Read.All`, `DeviceManagementRBAC.Read.All`, `DeviceManagementScripts.Read.All`, `DeviceManagementServiceConfig.Read.All`, `Directory.Read.All`, `Domain.Read.All`, `Group.Read.All`, `GroupMember.Read.All`, `IdentityRiskyUser.Read.All`, `MultiTenantOrganization.Read.All`, `OnPremDirectorySynchronization.Read.All`, `Organization.Read.All`, `Policy.Read.All`, `Reports.Read.All`, `ReportSettings.Read.All`, `RoleEligibilitySchedule.Read.Directory`, `RoleManagement.Read.Directory`, `SecurityEvents.Read.All`, `Sites.Read.All`, `Tasks.Read.All`, `Team.ReadBasic.All`, `TeamMember.Read.All`, `TeamSettings.Read.All`, `TeamworkDevice.Read.All`, `User.Read.All`, `UserAuthenticationMethod.Read.All`

Exchange Online and Purview take `Exchange.ManageAsApp`, on `Office 365 Exchange Online` and on `Microsoft Exchange Online Protection`. The Global Reader role limits what that permission reaches. Microsoft does not support eDiscovery cases in application mode: read them in the Purview portal.

The certificate lasts 6 months by default. `-CertificateMonths` changes that, from 1 to 24.

### Extended access

Three parts are left out unless you ask for them, because they go beyond plain reading of the tenant configuration, or need one more sign-in. Each needs the written agreement of the customer.

| `-ExtendedAccess` | What it grants | Why |
|---|---|---|
| `SharePoint` | `Sites.FullControl.All` | The only application permission that opens SharePoint administration. TenantConverge only reads with it |
| `PowerPlatform` | Registers the application for Power Platform management | One more sign-in per tenant |
| `Azure` | The Reader role on each subscription the account can see | One more sign-in per tenant |

```powershell
Initialize-TcAccess -Project ./project.json -ExtendedAccess SharePoint, PowerPlatform -GrantAdminConsent
```

Use `-DelegatedPnP` instead when the customer refuses SharePoint extended access.

## What writes to a tenant

| Command | Writes | When |
|---|---|---|
| `Start-TenantConverge`, `Invoke-TcAssessment` | Nothing | Never |
| `Invoke-TcRuleSet`, `Get-TcReadiness`, `New-TcPlan`, `New-TcReport`, `New-TcWorkbook` | Nothing, and they connect to nothing | Never |
| `Initialize-TcAccess`, `Remove-TcAccess` | The applications, their certificate, permissions and role | When you run them. Both support `-WhatIf` |
| `Invoke-TcRemediation`, `Undo-TcRemediation` | What the script or the undo plans | Only with `-Apply`, after the confirmations |

## Remediations are different

A remediation never uses the read-only application, and it does not share the permissions of the assessment:

- A person signs in, in a window, with delegated permissions. There is no unattended sign-in.
- The Microsoft Graph sign-in asks for the permissions of that script alone. A script with none signs in with `Organization.Read.All`.
- Each script names its permissions and the administrator roles it needs in the manifest. Read them before you run it:

```powershell
Get-TcRemediation ENT-AUTHORIZATION | Format-List Id, Risk, Reversible, RemovesObjects, Permissions, AdminRoles
```

For instance, `ENT-AUTHORIZATION` asks only for `Policy.ReadWrite.Authorization`, and `AUT-CONCEALED-REPORTS` only for `ReportSettings.ReadWrite.All`. A few ask for much more, so read the list each time. `ENT-STALE-DEVICES` asks for `Directory.AccessAsUser.All`, because Microsoft offers nothing narrower for changing a device in a delegated sign-in.

The list of permissions comes from the code of each script, compared with the delegated column of the Microsoft Graph permissions reference. No sign-in has ever confirmed it. A script for SharePoint also needs the client ID of a PnP application, in the `PnpClientId` setting.

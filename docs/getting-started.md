# Getting started

This page takes you through a first run, from an empty computer to a report. TenantConverge [has never run against a real tenant](limitations.md), so use test tenants, and compare what you get with the admin centers.

## 1. Check the computer

You need Windows, PowerShell 7.4 or later, and for Power Platform, Windows PowerShell 5.1. Install TenantConverge as the [README](../README.md#install) says, then:

```powershell
Test-TcPrerequisite
```

It lists each module with its version, and installs nothing. To install what is missing, for the current user:

```powershell
Test-TcPrerequisite -Install
```

| Module | Minimum version | Used for |
|---|---|---|
| Microsoft.Graph.Authentication | 2.10.0 | Identities, domains, Intune, reports. Required |
| ExchangeOnlineManagement | 3.7.0 | Exchange Online and Purview |
| MicrosoftTeams | 6.0.0 | Teams and Teams Phone |
| PnP.PowerShell | 2.12.0 | SharePoint and OneDrive |
| Az.Accounts | 3.0.0 | Azure sign-in |
| Az.Resources | 7.0.0 | Azure subscriptions, resources and role assignments |
| Microsoft.PowerApps.Administration.PowerShell | 2.0.0 | Power Platform, in Windows PowerShell 5.1 |
| ImportExcel | 7.8.10 | The workbook, written without Excel |

Only Microsoft Graph stops a run. Without one of the others, that part is not collected and the coverage says so. Without ImportExcel, there is no workbook.

## 2. Describe the project

A project names the target tenant, 1 to 3 source tenants, the sign-in mode and the output folder. `Start-TenantConverge` asks for all of it and saves `project.json`. You can also write the project from a script:

```powershell
$sources = @(
    @{ DisplayName = 'Alpine Group'; PrimaryDomain = 'alpine.example'; Wave = 1 }
    @{ DisplayName = 'Birch Partners'; PrimaryDomain = 'birch.example'; Wave = 2 }
)
New-TcProject -Name 'Summit consolidation' -TargetDomain summit.example -TargetDisplayName 'Summit Holdings' -TargetState Production -Source $sources -Path ./project.json
```

`-TargetState` is `Production`, or `New` for a target that is still empty. A wave is a group of sources that move together. Waves start at 1 with no gaps, and two sources can share a wave. The first source of the list becomes `S1`, the second `S2`, the third `S3`.

To check a project file, for instance after editing it by hand:

```powershell
Test-TcProject -Path ./project.json -Detailed
```

It prints nothing when the project is valid, and one record per problem when it is not. The [examples](../examples) folder has a project for 1, 2 and 3 sources.

Choose an output folder on a local disk, not in OneDrive, Dropbox, Google Drive or iCloud: it will hold personal data. TenantConverge warns you when it sees a synced folder, and refuses one in an unattended run.

## 3. Decide how to sign in

| Mode | How it signs in | What it needs first |
|---|---|---|
| Browser | One sign-in window per service and per tenant, with your own account | A PnP application for SharePoint |
| Application | The `TenantConverge Read-Only` application and a certificate, with no window | The application, created once per tenant by a Global Administrator |

[Permissions](permissions.md) lists what each mode asks for. `Initialize-TcAccess` and `Remove-TcAccess` are the only part of the assessment side that writes to a tenant, and only when you run them. Both support `-WhatIf`.

In browser mode, without a PnP application, SharePoint is not collected. To register one in each tenant, with a Global Administrator:

```powershell
Initialize-TcAccess -Project ./project.json -DelegatedPnP
```

In application mode, create the application, grant its permissions, then test each service:

```powershell
Initialize-TcAccess -Project ./project.json -WhatIf
Initialize-TcAccess -Project ./project.json -GrantAdminConsent
Initialize-TcAccess -Project ./project.json -Verify
```

Permissions take a few minutes to spread. The application IDs and certificate thumbprints go to `project.access.local.json`, next to the project and never in it. Git ignores that file.

Extended access to SharePoint, Power Platform and Azure is a separate choice that needs the written agreement of the customer. See [Permissions](permissions.md#extended-access).

## 4. Collect

```powershell
Start-TenantConverge -Project ./project.json
```

This checks the prerequisites, collects every tenant, writes the report and the workbook, and opens the report. Add `-NoOpen` to leave it closed, and `-Install` to install what is missing first.

To collect only, or only a part:

```powershell
Invoke-TcAssessment -Project ./project.json
Invoke-TcAssessment -Project ./project.json -Tenant S2 -Workload Intune -Depth Standard
Invoke-TcAssessment -Project ./project.json -Unattended
```

`-Depth Standard` skips the collectors that read each site, team or mailbox. `-Unattended` never opens a sign-in window: a service that would need one is not collected.

A stopped run leaves `snapshot.partial.json`, and the next run picks up where it stopped. Use `-Fresh` to start over.

## 5. Read the coverage first

The coverage says, for each of the 56 collectors, what was read:

| Status | Meaning |
|---|---|
| OK | Read in full |
| Partial | Read in part. The message says what is missing |
| Insufficient access | The account or the application was refused, or the access for that service was not set up |
| Module missing | The module of that service is not installed |
| License or service missing | The tenant does not have the service: nothing to move |
| Failed | The collector stopped. The details are in `journal.log` |

An empty table means the service is not used, unless its collector was partial. A missing table means it was not collected. A refused service never reads as an empty one.

## 6. Read the findings and the score

The rules read the snapshot, with no connection. The most severe finding sets the state of a workload:

| Finding | State | Weight |
|---|---|---|
| Critical | Blocking | 0 |
| High | To address | 0.35 |
| Medium | Secondary | 0.7 |
| Low, Info or none | Passed | 1 |

A workload with nothing against it reads `Not collected` when none of its collectors worked.

- `Score` counts every workload of the tenant, and a workload earns its weight only if the rules read everything they needed for it. What was not read could hide a blocker, so losing a service never raises `Score`. A service the tenant does not have leaves the count.
- `CollectedScore` averages the workloads that were read. It says how the collected part looks, and the gap between the two shows how much of the picture is missing.

You can compute both again from a snapshot, with no connection:

```powershell
$snapshot = Get-Content ./snapshot.json -Raw | ConvertFrom-Json -AsHashtable
$ruleSet = Invoke-TcRuleSet -Snapshot $snapshot
Get-TcReadiness -Snapshot $snapshot -RuleSet $ruleSet | Format-Table Role, Tenant, Score, CollectedScore
```

## 7. Work from the plan

`plan.json` holds:

- **Actions:** one per finding, plus the identity matrix and the go/no-go of each source. A critical finding blocks the cutover.
- **Target configurations:** the settings to put in place, with their current and target values.
- **Tasks:** the steps of the project. A task applies to the project, the target, each source or each wave, so the plan fits 1, 2 or 3 sources.
- **Decisions:** the questions to settle with the customer.
- **Procedures:** the steps, settings, checks and risks behind the actions and tasks, with links to Microsoft Learn.

A task that depends on a service leaves the plan when the tenant does not have that service or does not use it. When the service could not be collected, the task stays, marked `Unconfirmed`, and its `reason` says what is missing.

Task identifiers such as `ID-02.S1` stay the same from one run to the next. A wave task takes the roles of its members, as in `CUT-01.S1-S2`: when the members of a wave change, its tasks get new identifiers, and the old tracking rows show as orphans.

To compute the plan, the report or the workbook again from a snapshot:

```powershell
$snapshot = Get-Content ./snapshot.json -Raw | ConvertFrom-Json -AsHashtable
$plan = New-TcPlan -Project ./project.json -Snapshot $snapshot
New-TcReport -Project ./project.json -Snapshot ./snapshot.json
New-TcWorkbook -Project ./project.json -Snapshot $snapshot
```

Writing a new workbook keeps the old one in the same folder, as `consolidation-workbook-previous-<date>.xlsx`, and says so. What was typed in the yellow columns does not carry over, except what the tracking file holds. Do not delete the old file.

## 8. Track the work

The report needs no server. In Edge or Chrome you can link it to `team-tracking.csv`, next to the report, and it reads and writes that file. Another browser cannot write to a file. A row the report cannot read stays in the file and shows in the report as not recognised, and counts for nothing. A row whose item left the plan stays too, as an orphan. Generating the report again never writes to the file once it exists.

## 9. Finish

When the project ends, remove the read-only application and any PnP application:

```powershell
Remove-TcAccess -Project ./project.json -WhatIf
Remove-TcAccess -Project ./project.json
```

It asks for confirmation. Entra ID keeps a deleted application for 30 days. Then delete the output folder and `project.access.local.json`, as your agreement with the customer requires.

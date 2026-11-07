# TenantConverge

TenantConverge is a free PowerShell module for merging Microsoft 365 tenants. Before 1, 2 or 3 source tenants move into 1 target tenant, someone has to find out what each tenant holds, what will collide, and what must happen in which order. TenantConverge reads each tenant without changing it, then gives you a report, a planning workbook and the decisions to take. It is an independent project, not affiliated with Microsoft.

**Status: beta, version 0.9.0-beta1. TenantConverge has never run against a real tenant, from a real sign-in onward.** Its tests use fictional data and stand-ins for the Microsoft services. The first real run is yours to do: use test tenants, and read [what has never been run](docs/limitations.md) first.

![TenantConverge runs on your computer and reads 1 to 3 source tenants and 1 target tenant without changing them. It writes a report, a workbook and a tracking file. Its 111 remediation scripts are separate, and write to a tenant only if you run one and confirm.](docs/images/overview.png)

To see what it produces, open the [demonstration report](docs/demo/consolidation-report.html) and the [demonstration workbook](docs/demo/consolidation-workbook.xlsx), written from fictional tenants. Download the report and open it in a browser: GitHub shows HTML as source.

## Requirements

- Windows.
- PowerShell 7.4 or later.
- Windows PowerShell 5.1, for Power Platform only.
- The Microsoft modules of each workload. `Test-TcPrerequisite` shows what is missing, and `Test-TcPrerequisite -Install` installs it for the current user.
- ImportExcel, for the workbook. Excel itself is not needed.

TenantConverge needs Windows because it reads public DNS with `Resolve-DnsName`, keeps the certificate of its read-only application in the Windows certificate store, reads Power Platform through a module that runs only in Windows PowerShell, and protects any secret a remediation creates with Windows data protection.

## Install

From the PowerShell Gallery:

```powershell
Install-Module TenantConverge -AllowPrerelease -Scope CurrentUser
```

From a clone of this repository:

```powershell
git clone https://github.com/HoussemMak/TenantConverge.git
cd TenantConverge
Import-Module ./src/TenantConverge/TenantConverge.psd1
```

From a ZIP download, Windows marks every file as coming from the internet. In the extracted folder, clear that mark before importing the module:

```powershell
Get-ChildItem -Path . -Recurse -File | Unblock-File
Import-Module ./src/TenantConverge/TenantConverge.psd1
```

Then check what this computer has:

```powershell
Test-TcPrerequisite
```

## Usage

### Try it without a tenant

From a clone, this writes a report and a workbook from fictional tenants. It connects to nothing, and needs ImportExcel:

```powershell
./tools/New-TcDemo.ps1 -OutputPath ./demo
```

Open `demo/consolidation-report.html` in a browser.

### Run it on your tenants

Use test tenants first. Start the setup and answer the questions:

```powershell
Start-TenantConverge
```

TenantConverge asks how many source tenants you have, then for the target, each source, the sign-in mode and the output folder. A wave is a group of sources that move together: wave 1 moves first, and two sources can share a wave. It saves your answers to `project.json`, checks the prerequisites, collects every tenant, then writes the report and the workbook and opens the report.

To run an existing project without any question:

```powershell
Start-TenantConverge -Project ./project.json
```

To collect again without the setup, use `Invoke-TcAssessment`. SharePoint needs a PnP application in each tenant, or it is not collected. `Initialize-TcAccess` creates it, or a read-only application for runs with no sign-in window, and `Remove-TcAccess` removes them at the end. Those two commands write to a tenant, only when you run them. [Getting started](docs/getting-started.md) goes through the whole first run, including sign-in.

## What a run produces

![A run goes through five steps. Each step saves a file that the next step reads: project.json, snapshot.json, findings.json and plan.json, then the report and the workbook. When a read fails, nothing stops: the coverage says why, the rules say what they could not read, the task stays marked Unconfirmed, and the report shows a gap, never a zero.](docs/images/how-a-run-works.png)

Each run writes a dated folder in the output folder of the project, such as `20270115-091500-assessment`:

| File | Content |
|---|---|
| `snapshot.json` | Every table, by tenant, and the coverage of each collector |
| `findings.json` | What the rules found, the indicators, the setting gaps, and what the rules could not read |
| `plan.json` | The migration plan: actions, target configurations, tasks and decisions |
| `exports\*.csv` | One file per table and per tenant |
| `identity-matrix-*.csv` | A draft of the identity matrix of each source, with likely duplicates |
| `journal.log`, `events.jsonl` | What happened, with secrets masked |

The output folder itself receives:

| File | Content |
|---|---|
| `consolidation-report.html` | The whole assessment and plan in one file, which works offline |
| `consolidation-workbook.xlsx` | The working file of the project: dashboard, action plan, steps, identity matrix, decisions |
| `team-tracking.csv` | What the team records from the report: statuses, assignees, notes and answers |

The assessment only reads. A missing module or a refused access does not stop it: the coverage says what was not collected, why, and what to do. Something not read shows as a gap, never as a zero.

These files hold personal data and the configuration of the tenants. Read [privacy](docs/privacy.md) and keep them out of synced folders.

## Remediations: untested

TenantConverge also ships 111 remediation scripts, kept apart from the assessment. **None of them has ever run on a real tenant.** Each one says so, in its first line and at each run:

> UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.

They run only when you call them: `Start-TenantConverge` never does. A script shows a preview unless you add `-Apply`, and a preview connects to nothing. With `-Apply` it asks you to type the word `UNTESTED`, then the primary domain of each tenant it writes to, then `REMOVE` if it removes objects. Most scripts act only on rows a person decided in a decisions file.

![A remediation script shows a preview by default, which connects to nothing and proposes a decisions file. With -Apply it asks for the word UNTESTED, shows its plan, asks for the primary domain of each tenant it touches, and asks for the word REMOVE if it removes objects. Any other answer stops it with nothing changed. A person then signs in with only the permissions of the script, each action is tested and logged, and the journal lets you undo the run.](docs/images/remediation-gates.png)

Tests on stand-ins prove less than you may think: only 26 of the 76 scripts that reach a service ever recorded a write, even on a stand-in. Read [remediations](docs/remediations.md) before you run one.

## Documentation

- [Getting started](docs/getting-started.md): the first run from start to finish.
- [How it works](docs/how-it-works.md): diagrams of a run, the remediation gates, what leaves the computer, and how a team tracks the work.
- [Permissions](docs/permissions.md): what each service needs, and how remediations differ.
- [Privacy](docs/privacy.md): what the output files hold, and what leaves the computer.
- [Remediations](docs/remediations.md): preview, `-Apply`, confirmations, decisions, undo, and what "untested" means.
- [Limitations](docs/limitations.md): what has never been run, and what only a real tenant can settle.
- [Glossary](docs/glossary.md): the words this project uses.
- [Changelog](CHANGELOG.md).

`Get-Help` works on every command, for instance `Get-Help Invoke-TcAssessment -Full`.

## Support

This is a free project with no support commitment. Open an issue for a defect or a question, and expect an answer when someone has time. Never put real tenant data in an issue.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

Apache-2.0. See [LICENSE](LICENSE). The software comes without warranty of any kind. The fonts in the report keep their own license: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

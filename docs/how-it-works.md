# How it works

TenantConverge runs on your computer. It reads your tenants, works out what must happen, and writes files you keep. These diagrams show how the parts fit together. Their sources are in `docs/images/source`, and `tools/New-TcDiagram.ps1` renders them.

## The whole picture

![TenantConverge runs on your computer and reads 1 to 3 source tenants and 1 target tenant without changing them. It writes a report, a workbook and a tracking file. Its 111 remediation scripts are separate, and write to a tenant only if you run one and confirm.](images/overview.png)

The assessment and the remediations are two separate paths. The assessment only reads. A remediation writes, and only when a person runs it and confirms.

Two other commands write to a tenant: `Initialize-TcAccess` creates the applications TenantConverge can sign in with, and `Remove-TcAccess` removes them. Both run only when you call them. See [permissions](permissions.md).

TenantConverge moves no mail, no files and no sites. It tells you what to do, in which order, and what could go wrong.

## One run

![A run goes through five steps. Each step saves a file that the next step reads: project.json, snapshot.json, findings.json and plan.json, then the report and the workbook. When a read fails, nothing stops: the coverage says why, the rules say what they could not read, the task stays marked Unconfirmed, and the report shows a gap, never a zero.](images/how-a-run-works.png)

`Start-TenantConverge` chains the steps. You can also run them one at a time:

| Step | Command | Saves |
|---|---|---|
| Describe | `Start-TenantConverge` or `New-TcProject` | `project.json` |
| Collect | `Invoke-TcAssessment` | `snapshot.json` and one CSV file per table |
| Analyse | `Invoke-TcRuleSet`, called by `Invoke-TcAssessment` | `findings.json` |
| Plan | `New-TcPlan`, called by `Invoke-TcAssessment` | `plan.json` |
| Deliver | `New-TcReport`, `New-TcWorkbook` | The report, the workbook and the tracking file |

Each step reads files, not tenants, so you can compute the plan, the report or the workbook again without connecting to anything. A run that stops halfway keeps what it read in `snapshot.partial.json`.

## When a read fails

The lower row of that diagram is the most important part of it. A migration plan is dangerous when it says a tenant holds nothing because nobody could read it.

So a refused access, a missing module or a failing service stops nothing, and never turns into an empty table. The coverage records what was not read and why. The rules list what they could not check. The plan keeps the task and marks it `Unconfirmed`. The report shows a gap.

A task leaves the plan only when the tenant does not have the service or does not use it. When an error is unclear, it stays a failure, which shows as a gap. See the [statuses](getting-started.md).

## A remediation

![A remediation script shows a preview by default, which connects to nothing and proposes a decisions file. With -Apply it asks for the word UNTESTED, shows its plan, asks for the primary domain of each tenant it touches, and asks for the word REMOVE if it removes objects. Any other answer stops it with nothing changed. A person then signs in with only the permissions of the script, each action is tested and logged, and the journal lets you undo the run.](images/remediation-gates.png)

**None of the 111 scripts has run on a real tenant.** The gates above are tested on stand-ins only. Read [remediations](remediations.md) before you run one.

## What leaves your computer

![The output files stay on your computer. Five things cross its boundary: your sign-in and read requests go to your tenants; the primary domain goes to login.microsoftonline.com to find the tenant ID; your customer's domain names go to a public DNS server, 1.1.1.1 by default; a request for each missing module goes to the PowerShell Gallery, only with -Install; and a zone and a record go to Cloudflare, only for a remediation with -Apply. There is no telemetry and no update check, and the report connects to nothing.](images/what-leaves-the-computer.png)

The DNS queries are the line people do not expect: whoever runs that server sees which domains were looked up. [Privacy](privacy.md) gives the details, and how to change the server for a remediation.

## Working as a team

![The team shares one file, team-tracking.csv, next to the report. In Edge or Chrome, each person links the report to that file, and the report reads and writes it. Other browsers cannot write to a file. A new workbook reads what the file holds. Generating the report again never overwrites the file once it exists.](images/team-tracking.png)

The tracking file is what survives from one run to the next. Keep it in a folder the team shares and that only the project team can read, since it holds names and notes. Linking the report to the file has been tested with a stand-in, not yet with two people on one file: see [limitations](limitations.md).

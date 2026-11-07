# Remediations

> UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.

TenantConverge ships 111 remediation scripts, by workload, in `src/TenantConverge/Remediation`. They are kept apart from the assessment: `Start-TenantConverge` never runs one, and each one runs only when you call it. Each script answers one finding or one task of the plan, and the report and the workbook show the matching scripts with an `Untested` badge.

The license comes without warranty. A script can damage a production tenant. Read the script, then try it on a test tenant.

## Find a script

```powershell
Get-TcRemediation | Format-Table Id, Nature, Risk, Reversible, Workload
Get-TcRemediation -Workload 'Entra ID' -Nature Decision
Get-TcRemediation ENT-AUTHORIZATION | Format-List *
```

The entry gives the title, the rules it answers, the [permissions and roles](permissions.md#remediations-are-different) it asks for, its risk, and whether it can be undone.

Risk and reversibility were deduced from the code, and never observed on a tenant:

- High risk: 44. Medium risk: 35. Low risk: 32.
- 83 are marked reversible, and 28 are not.
- 35 scripts can remove objects.

## Natures

| Nature | Scripts | What it does |
|---|---|---|
| Decision | 62 | Acts only on the rows a person decided in its decisions file. With no decision, it changes nothing |
| Partial | 27 | Does what an API allows, and gives a person the rest as instructions |
| Report | 19 | Writes reports, often the decisions another script reads. It changes nothing in a tenant |
| Automated | 3 | With `-Apply`, it goes ahead once confirmed, with no decisions file |

Six scripts can write with no decisions file: `POC-TEST-SET` and `UNIFIED-AUDIT-LOG`, of nature Automated, and `DNS-HOST`, `DNS-TTL`, `EXO-ROOMS` and `TEL-CALLING-SETTINGS`, of nature Partial. `EXO-ROOMS` follows the rows of the identity matrix. The others write what their plan shows, once you confirm.

## Preview

Without `-Apply`, a script is a preview:

```powershell
Invoke-TcRemediation ENT-AUTHORIZATION -Project ./project.json
```

A preview connects to nothing and writes nothing to a tenant. It reads the latest snapshot of the output folder and the plan, then:

- shows what it would do, tenant by tenant;
- writes or updates `<output>\decisions\<id>.csv`, when the script reads decisions;
- leaves a folder `<output>\remediations\<date>-<id>-Preview`, with `journal.log`, `events.jsonl`, `plan.json` and `summary.json`, plus `plan.csv` when something is planned, and its reports in `exports\`.

Use `-Tenant S1` to limit a run to some tenants.

## Decisions files

A script asks nothing while it runs. What a person must settle lives in `<output>\decisions\<id>.csv`, which opens in Excel. Each file lists one row per object, then `Proposal`, `Allowed values`, `Decision`, `Decision maker`, `Date` and `Note`.

- Copy a value of `Allowed values` to `Decision`. The value is compared exactly, case included: anything else leaves the row pending.
- A row with no decision is never applied. A file that is missing or empty changes nothing, and the script says so.
- A row acts only when its key matches a proposal of this run, so a damaged key acts on nothing.
- A decided row that the tenant no longer proposes stays as a trace, and is never applied.
- A file with an unknown column, or without its key or `Decision`, stops the script and stays as it is.
- A cell that starts with `=`, `+`, `-` or `@` and did not come from this module sets its row aside, with an alert.

**A decision goes back to pending when its row changes.** A decision is taken on what the row said. When the next run finds another value in any column of the row, status columns included, it clears `Decision`, `Decision maker` and `Date`, keeps `Note`, and raises an alert that says what changed. A number or a date that Excel only rewrote its own way does not count. Run the preview again after each new snapshot, and read the alerts.

## Settings

`<output>\decisions\settings.json` holds the settings that stay from one run to the next, and `-Setting` replaces them for one run. An unknown name stops the run.

```powershell
Invoke-TcRemediation CMP-LICENSES -Project ./project.json -Setting @{ LicenseSku = 'YOUR_SKU' }
```

| Setting | Default | Used for |
|---|---|---|
| `LicenseSku` | empty | The license migrated accounts get |
| `ObjectPrefix` | `TenantConverge` | The name of the objects a script creates |
| `PnpClientId` | empty | The PnP application of a SharePoint script |
| `SharePointAdminUrl` | none | The admin address, by tenant, when the usual one does not apply |
| `EmergencyAccountPrefix`, `EmergencyAccountCount`, `EmergencyAccountDomain` | `emergency`, 2, empty | Emergency accounts |
| `ProtectedAccountPattern`, `KeptAccounts` | `^(emergency\|breakglass\|rescue)`, none | Accounts a script must leave alone |
| `MigrationAccountPattern` | empty | The accounts of a migration tool, which a script must leave alone |
| `ProtectedApplicationPattern` | `^TenantConverge ` | Applications a script must leave alone |
| `InactiveDays`, `StaleDeviceDays` | 90, 90 | When an account or a device counts as inactive |
| `LargeMailboxGb`, `LargeSiteGb`, `StorageMarginPercent` | 45, 100, 20 | Size thresholds |
| `SecretExpiryDays` | 60 | When a secret counts as close to expiry |
| `UsageLocation`, `UsualCountries` | `US`, `US` | The country of an account a script creates, and the sign-in countries `ENT-COUNTRIES` treats as usual |
| `DeviceNamePattern` | `DEV-%RAND:4%` | The name template of a device |
| `DomainRemovalMinutes` | 1440 | The time `GO-NOGO` allows for removing a domain |
| `SourceGroups` | none | Groups, by source, that some scripts propose |
| `TestRecipients`, `TestSender` | none, empty | Mail flow tests |
| `DnsServer`, `DnsTtl`, `DnsWaitMinutes`, `DnsPollSeconds` | `1.1.1.1`, 300, 120, 30 | DNS reads and waits |
| `DnsHosts`, `DnsApiTokenVariable` | none, `CF_API_TOKEN` | The DNS host of a zone, and the variable that holds a Cloudflare token |
| `MaxSnapshotAgeDays` | 14 | The oldest snapshot `-Apply` accepts |

Four scripts stop without `LicenseSku`, in a preview too, because a guessed license would be worse than a question: `CMP-LICENSES`, `CON-LICENSES`, `IDENTITY-MATRIX` and `LICENSE-CHECK`.

DNS records are written through the API for a zone at Cloudflare. For any other host, the script shows a person what to publish, then watches the public DNS.

## -Apply and the three confirmations

```powershell
Invoke-TcRemediation ENT-AUTHORIZATION -Project ./project.json -Tenant Target -Apply
```

The script refuses a snapshot older than 14 days. Otherwise, it goes through these steps, in this order:

1. **It asks for the word `UNTESTED`.** `-AcknowledgeUntested` replaces this word, for a run from a script. It replaces nothing else.
2. **It shows its plan.** Some scripts must read a tenant to build it, so a person signs in at this step, with the permissions of the script. Nothing is written yet. If the plan is empty, the script stops here.
3. **It asks for the primary domain of each tenant the plan touches.** Nothing replaces this.
4. **It asks for the word `REMOVE`, when the script removes objects.** Nothing replaces this either.

Any other answer stops the run, with nothing changed. To read a plan without answering anything, run the preview.

![A remediation script shows a preview by default, which connects to nothing and proposes a decisions file. With -Apply it asks for the word UNTESTED, shows its plan, asks for the primary domain of each tenant it touches, and asks for the word REMOVE if it removes objects. Any other answer stops it with nothing changed. A person then signs in with only the permissions of the script, each action is tested and logged, and the journal lets you undo the run.](images/remediation-gates.png)

Each domain you type opens writes to that tenant only. A write to a tenant nobody confirmed is refused. An action that writes to a second tenant declares it, so its domain is asked too.

Then a person signs in, if nobody has yet, with [only the permissions of the script](permissions.md#remediations-are-different). The session is checked, and a session on another tenant is refused. Each action is tested on the tenant just before it runs, is skipped when it is already in place, and is written to `operations.jsonl` before and after. A failed action does not stop the others, unless the script marks it as critical. Most scripts then check each tenant.

| Code | Result |
|---|---|
| 0 | Done |
| 1 | Done, with points left open: alerts, pending decisions, or work for a person |
| 2 | Failed |
| 3 | Stopped at a confirmation, nothing changed |

Run a script again after a fix: what is in place is skipped. Exchange, Teams and PnP cannot share a PowerShell process, so a script may ask you to open a new window.

## Undo

```powershell
Undo-TcRemediation -Path ./output/remediations/20270115-091500-ENT-MFA-Apply -Project ./project.json
Undo-TcRemediation -Path ./output/remediations/20270115-091500-ENT-MFA-Apply -Project ./project.json -Apply
```

Give the folder of one run: a folder that holds several is refused. Without `-Apply`, it shows what it would do, with no connection. With `-Apply`, it asks the same confirmations, for the tenants the undos write to, and asks `REMOVE` when an undo deletes what the run created.

The undo replays the operations of the journal, the most recent first:

- A Microsoft Graph `PATCH` gets back the values read just before it, and a creation is deleted.
- A DNS change puts back each value read before it, and removes only what the action published.
- What was undone is marked in the journal, so a second undo finds nothing to do. An undo that fails stays to undo.
- An operation with no way back is listed with its reason, and stays for a person.
- An operation cut short shows as `status unknown`, and is not replayed: check the tenant.

Undo goes back on what the journal holds, and on nothing else.

## What "untested" really means

**None of the 111 scripts has run on a real tenant.** Each entry of the manifest says `testedOnRealTenant: false`, and a test fails if one says true with no evidence.

What has run is the test suite, with stand-ins. A stand-in replaces the functions that leave the computer, and records each call. It answers with invented objects, written by hand, so it can only show that a script behaves as its author expected.

On stand-ins, all 111 scripts ran in preview and with `-Apply`, at 1, 2 and 3 source tenants, with the decisions of the proposals and with other allowed values:

- No preview recorded a write or a sign-in.
- No decisions file left empty led to a write.
- A wrong domain or a missing confirmation stopped each script that would have written.

Those runs prove less than they seem to. **76 of the 111 scripts hold an action that reaches a service with `-Apply`** (a few of those only read). **Only 26 of the 76 recorded a write, even on a stand-in**: 24 in the runs over all scripts, and 2 in tests of their own. For the other 50, a check answered "already in place", the action only read, or the fictional tenants gave the script nothing to do. Their write code has been read by static checks, and has never been executed by anyone.

Even for the 26, nothing shows that:

- Microsoft accepts the call, with that body or those parameters;
- the service answers in the shape the script reads;
- the permissions listed are enough;
- the undo restores what was there;
- the delays and limits of a real tenant leave the script standing.

Treat each script as a detailed draft of what to do, and read it as you would read a colleague's first attempt.

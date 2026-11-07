# Limitations

TenantConverge has never run against a real tenant, from a real sign-in onward. No sign-in window has opened, no Microsoft service has answered, and no collector, application setup or remediation has touched a tenant. The version number says so: 0.9.0-beta1.

The tests in this repository use fictional tenants, and stand-ins that replace the Microsoft services. They show that the code does what its author expected. They cannot show that Microsoft answers as expected. Whoever runs it first will find what those tests could not.

Run it on test tenants first, and compare the report with the admin centers.

## What only a real tenant can settle

| Subject | What nobody knows yet | Where to look |
|---|---|---|
| Answers of the services | Whether each cmdlet and each Microsoft Graph call returns the shape the code expects. The stand-ins were written by hand | `journal.log`, coverage |
| Throttling | What happens on a 429. A small test tenant shows little of it | `journal.log`, `events.jsonl` |
| Report delays | Whether the Microsoft Graph usage reports answer, and how long they take | Durations by collector |
| The separate PnP process | Whether it starts, signs in and hands its data back | SharePoint workload, messages |
| Certificates | Whether Exchange Online accepts the key, whether Microsoft Graph, Exchange, Purview, Teams and PnP all connect with it | `Initialize-TcAccess -Verify` |
| `Initialize-TcAccess` from start to end | Whether the application, the certificate, the permissions, the consent and the role are created and then removed, and the extended access to SharePoint, Power Platform and Azure | Entra ID, `-Verify` |
| Purview sign-in | Whether `TenantID` is filled in `Get-ConnectionInformation` after a browser sign-in. If it is empty, TenantConverge refuses the session and Purview is not collected | `Get-ConnectionInformation \| Format-List` |
| Purview eDiscovery cases | Whether `Get-ComplianceCase` answers with ExchangeOnlineManagement 3.7.0 | Coverage of the eDiscovery collector |
| Setting names | Whether the names of the settings a service returns match the ones the rules look for | Setting gaps in the report |
| Statuses | Whether a 403, a missing license and a missing module are classified as they should be. The classification decides `Score` | Coverage |
| DNS | Whether `1.1.1.1` is reachable from your network, whether DNS hosts are recognized, how long records take to appear and to leave, and the Cloudflare API with a real token | Public DNS tables |
| Remediation sign-in | One window per script, only the permissions of the manifest, the right tenant, and consent on a strict tenant | [Remediations](remediations.md) |
| What each script writes | Whether each of the 111 scripts does what its plan says, and whether its undo does too | One test per script |

## The results themselves

- **Nothing has been compared with an admin center.** A collector error shows only there. Compare the counts of accounts, guests, licenses, administrators, mailboxes, sites, teams and devices.
- **`Score` can look severe.** One partial collector with an empty table costs a whole workload, because what was not read could hide a blocker. Read it next to `CollectedScore`, and read the message of the collector.
- **A blocker in the plan comes from a critical finding or from the identity matrix.** Some real cutover conditions are not raised as blockers, such as freeing a domain or having emergency access. They stay as tasks, and as checks of the `GO-NOGO` script.
- **An account counts as active on its latest sign-in of any kind.** An abandoned account whose device still renews a token reads as active. The identity matrix is a proposal: a person validates each row.
- **Accounts you mean to keep in a source still appear in the identity matrix.** `KeptAccounts` is a setting of the remediations, not of the matrix. Settle them when you validate it.
- **A count from a partly read tenant is a minimum.** Totals that leave out a tenant say so, but a number found in a partly read tenant shows bare.

## The report and the workbook

- The report ran only in Edge without a window, never in Chrome, and never on paper. Linking the report to the tracking file was tested with a stand-in for the file, not with the real file picker, and not with two people on one file.
- The tests write and read the workbook without Excel, and read its formulas from their stored values. The demonstration workbook was then opened once, in Excel 16 in French: no repair message, no cell in error, and all 8,454 formulas gave the same values after a full recalculation. `-AddSlicers` also ran once there. Workbooks from real tenants, other versions and other languages of Excel are not proved.
- `New-TcWorkbook -AddSlicers` starts a hidden Excel with no time limit. A dialog in that instance stops the run with nothing on the screen. Open Excel once by hand first.
- Volume is unknown. Tables in the report show 50 rows a page, and behaviour on a very large tenant has not been measured.

## What the module does not do

- It moves no mail, no files and no sites. There is no cutover engine: it assesses, plans, and offers remediation scripts for the settings and objects around the move.
- It handles 1, 2 or 3 sources into 1 target, and refuses more.
- It is in English only.
- It runs on Windows only.

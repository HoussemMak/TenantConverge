# Privacy

TenantConverge writes personal data and the configuration of your customer's tenants to your computer. You decide where those files go, and you answer for them.

## What the output files hold

| File | Holds |
|---|---|
| `snapshot.json`, `snapshot.partial.json` | Every table read from every tenant |
| `exports\*.csv` | The same tables, one file per table and per tenant |
| `identity-matrix-*.csv` | One row per account of a source, with its proposed decision |
| `findings.json`, `plan.json` | What the rules found, with names of accounts, mailboxes, sites and groups |
| `consolidation-report.html` | The assessment and the plan, in one file |
| `consolidation-workbook.xlsx` | The plan, the identity matrix and the decisions |
| `team-tracking.csv` | Statuses, assignees, notes and answers, with the names of the people who typed them |
| `journal.log`, `events.jsonl` | What happened, with names of tenants and services. Passwords, tokens and thumbprints are masked |
| `decisions\*.csv` | What a person decided for a remediation, row by row |
| `remediations\<run>\` | The plan, the journal and the reports of a remediation run, with names of the objects it touched |
| `remediations\<run>\secrets\*.xml` | Secrets a remediation created. See below |

The tables include, for each account: display name, first and last name, sign-in name, addresses, phone and mobile numbers, office, city, department, job title, company, employee ID, licenses and last sign-in date. They also hold mailbox and OneDrive sizes, group and team membership, administrator roles, devices and their owners, inbox rules that forward mail and where they forward it, and guests with their outside addresses.

TenantConverge reads no mail, no files and no chat messages. It reads their counts, sizes and settings, not their content. Check this yourself: the [permissions](permissions.md) hold no permission for mail or for chats, and the code calls no message or file read. `Sites.Read.All` and the SharePoint permissions would allow reading files, and the collectors do not use them for that.

## Where to keep the files

- On an encrypted local disk, in a folder only your account can read.
- Not in OneDrive, Dropbox, Google Drive or iCloud. TenantConverge warns about those folders, and an unattended run refuses them. It recognises them by their path, so another sync tool goes unnoticed.
- Not in a git repository, even a private one. The `.gitignore` of this project leaves out `output/`, `*.log`, `*.access.local.json` and certificates, and no other folder.
- Share the report and the workbook only with people who need them, and delete them when the project ends, as your agreement with the customer requires.

`<project>.access.local.json` holds application IDs and certificate thumbprints, not secrets, but keep it with the output. The private key of the certificate stays in the Windows certificate store and cannot be exported.

A remediation that creates a secret, such as the password of an emergency account, saves it with Windows data protection. Only the same Windows account on the same computer can read that file. It is not in the logs, and the journal masks it.

The report also keeps data in the browser that opened it: a copy of the tracking entries, the name you gave, the link to the tracking file, and a copy of that file when rows were removed from it. Clear the site data of the browser on a shared computer.

## What leaves the computer

![The output files stay on your computer. Five things cross its boundary: your sign-in and read requests go to your tenants; the primary domain goes to login.microsoftonline.com to find the tenant ID; your customer's domain names go to a public DNS server, 1.1.1.1 by default; a request for each missing module goes to the PowerShell Gallery, only with -Install; and a zone and a record go to Cloudflare, only for a remediation with -Apply. There is no telemetry and no update check, and the report connects to nothing.](images/what-leaves-the-computer.png)

| Where it goes | What goes | When |
|---|---|---|
| Your tenants, through Microsoft sign-in, Microsoft Graph, Exchange Online, Teams, SharePoint, Power Platform and Azure | Your sign-in, and the read requests | During a collection, and during a remediation with `-Apply` |
| `login.microsoftonline.com` | The primary domain of each tenant, to find its tenant ID in the public sign-in metadata | When a collection, `Initialize-TcAccess` or `Remove-TcAccess` starts on a tenant. This request needs no sign-in |
| A public DNS server, `1.1.1.1` by default | **The domain names of your customer**, in plain DNS queries, with the IP address of your network | During a collection, and during a remediation that reads or waits for a DNS record |
| Your usual DNS resolver | The same queries, when `1.1.1.1` does not answer | During a collection |
| The PowerShell Gallery | A request for each missing module | Only with `-Install` |
| The Cloudflare API | The zone, the record and your token | Only for a remediation with `-Apply`, on a zone hosted at Cloudflare, with a token you put in an environment variable. Any other DNS host gets instructions for a person |

Whoever runs the DNS server sees which domains were looked up, and when. That can reveal who is merging with whom before it is public. A remediation can use another server, through the `DnsServer` setting, and `DNS-TTL` also asks the name server of each domain. A collection always starts with `1.1.1.1`, and when that server does not answer, it goes to your usual resolver.

Nothing else leaves the computer. **TenantConverge has no telemetry.** It counts nothing, reports nothing to anyone, and checks for no update.

The report sends nothing. Its content security policy blocks every outbound connection, and its fonts, data and code are inside the file. The links to Microsoft Learn and to product pages open only when you click them, and the browser then reaches that site as for any link.

The Microsoft and third-party modules that TenantConverge calls have their own behaviour, which this project does not control. Check them against your policy.

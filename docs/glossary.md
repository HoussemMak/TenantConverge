# Glossary

**Action.** One line of the plan, tied to a finding, the identity matrix or the go/no-go of a source. In a remediation, an action is one step of its plan, with its own test and journal line.

**Application mode.** Sign-in with the `TenantConverge Read-Only` application and a certificate, with no window. See [Permissions](permissions.md).

**Assessment.** A read-only collection of the tenants of a project, followed by the rules and the plan.

**Browser mode.** Sign-in with your own account, in one window per service.

**Collector.** One piece of code that reads one part of a tenant into one or more tables. There are 56.

**`CollectedScore`.** The average of the workloads that were read. See `Score`.

**Confirmation.** What `-Apply` asks you to type before the first write: `UNTESTED`, the primary domain of each tenant, and `REMOVE` when objects go away.

**Consolidation.** Moving 1, 2 or 3 source tenants into 1 target tenant.

**Coverage.** The record of each collector: what it read, its status, and what to do when it could not read.

**Cutover.** The moment a source stops being used and its users work in the target.

**Decision.** A value a person writes in a decisions file for a remediation. The plan also lists decisions: questions to settle with the customer.

**Decisions file.** `<output>\decisions\<id>.csv`, which a remediation proposes and a person fills in.

**Extended access.** Access to SharePoint, Power Platform or Azure for the read-only application, granted only on request.

**Finding.** What a rule reports about a tenant, with a severity: Critical, High, Medium, Low or Info.

**Global Reader.** A Microsoft Entra role that can read settings and administrative information, and change nothing. The read-only application holds it.

**Go/no-go.** The check before the cutover of a source.

**Identity matrix.** One row per account of a source, with what to do with it: create it in the target, treat it as a duplicate, or review it. A person validates each row.

**Manifest.** `Data\remediations.json`: one entry per remediation script, with its nature, risk and permissions.

**Moment.** When an action or a task falls: Now, Preparation, Before cutover, Cutover, After cutover or Closure.

**Nature.** What a remediation does: Decision, Partial, Report or Automated. See [Remediations](remediations.md#natures).

**Orphan.** A tracking row whose item left the plan. It stays visible.

**Output folder.** The folder a project names for everything it writes.

**Plan.** `plan.json`: actions, target configurations, tasks, decisions and procedures, computed from the project and a snapshot.

**PnP application.** The application SharePoint needs in each tenant, for a sign-in with PnP.PowerShell.

**Preview.** A run of a remediation without `-Apply`. It connects to nothing and writes nothing to a tenant.

**Primary domain.** The domain a project uses to name a tenant, and the one you type to confirm a write.

**Procedure.** The detailed steps, settings, checks and risks behind an action or a task.

**Project.** `project.json`: the target, the sources, their waves, the sign-in mode and the output folder.

**Readiness.** How ready a tenant looks, by workload: Blocking, To address, Secondary, Passed or Not collected.

**Remediation.** A script that changes a tenant to answer a finding or a task. All of them are untested.

**Role.** The name of a tenant in a project: `Target`, `S1`, `S2` or `S3`.

**Rule.** A check on a snapshot that gives findings. There are 117.

**Run folder.** The dated folder of one assessment or one remediation run.

**`Score`.** The readiness of a tenant, counting every workload it has. A workload earns its weight only if the rules read everything they needed for it.

**Snapshot.** `snapshot.json`: every table read from every tenant, with the coverage. The rules, the plan, the report and the workbook all work from it, with no connection.

**Source.** A tenant that moves into the target.

**Stand-in.** A replacement for a Microsoft service, used in tests. It records each call and answers with invented objects.

**Table.** One list of rows in a snapshot, such as `users` or `mailboxes`. There are 111.

**Target.** The tenant that remains.

**Target configuration.** A setting to put in place in the target, with its current and target values.

**Task.** A step of the project, from a template. It applies to the project, the target, each source or each wave.

**Tracking file.** `team-tracking.csv`, next to the report: what the team records.

**Undo.** Replaying the journal of a remediation run backwards, with `Undo-TcRemediation`.

**Unconfirmed.** A task that stays in the plan although a service it depends on could not be read.

**Untested.** Never run on a real tenant. See [what it really means](remediations.md#what-untested-really-means).

**Wave.** A group of sources that move together. Wave 1 moves first, and two sources can share a wave.

**Workload.** A family of services, such as Entra ID, Exchange Online or Teams. There are 11.

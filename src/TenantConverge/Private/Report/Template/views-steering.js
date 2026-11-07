/* ---------- steering: team, tasks, decisions, remediations, log ---------- */
const FD = { t: '', s: 'open' }, FS = { q: '', nature: '' }, FJ = { q: '' }, FP = { who: '' }, FT = { tq: '', ts: '' };
const steeringTabs = () => {
  const open = D.decisions.filter(d => (P.decisions[d.id] || {}).status !== 'decided').length, l = [['team', 'Team', 'people']];
  if (D.tasks.length) l.push(['tasks', 'Tasks', 'flag', D.tasks.length]);
  if (D.decisions.length) l.push(['decisions', 'Decisions', 'scale', open]);
  if (D.remediations.length) l.push(['remediations', 'Remediations', 'terminal', D.remediations.length]);
  if (D.log.length) l.push(['log', 'Collection log', 'note', D.log.length]);
  return l;
};
VIEWS.steering = p => {
  const l = steeringTabs(), s = l.some(x => x[0] === R.sub) ? R.sub : 'team'; R.sub = s;
  p.innerHTML = `<h1 class="page-title">Steering</h1><p class="lede">Who carries what in the team, the tasks of the plan, the answers to get, and what the assessment recorded.</p>
  ${subnav(l, s)}<div id="view"></div>`;
  ({ team: teamView, tasks: allTasksView, decisions: decisionsView, remediations: remediationsView, log: logView })[s]($('#view'));
};
/* team: who carries what, what moved, how to exchange */
function activity() {
  const l = [], label = s => statusLabel(s);
  for (const [g, name] of [['a', 'actions'], ['k', 'tasks']]) for (const [id, r] of Object.entries(P[name])) {
    const item = PLAN_ITEM[g][id]; if (!item) continue;
    const t = r.t || {};
    if ((t.status || {}).at) l.push({ at: t.status.at, by: t.status.by, a: item, what: `set to "${label(r.status)}"` });
    if ((t.assignee || {}).at) l.push({ at: t.assignee.at, by: t.assignee.by, a: item, what: `gave it to ${r.assignee}` });
    for (const [n, x] of Object.entries(r.notes || {})) if (x.at && x.text) l.push({ at: x.at, by: n, a: item, what: 'wrote a note' });
  }
  return l.sort((x, y) => y.at.localeCompare(x.at)).slice(0, 15);
}
function lastActivity() {
  const m = {}, seen = (n, d) => { if (n && d && (!m[n] || d > m[n])) m[n] = d; };
  for (const r of [...Object.values(P.actions), ...Object.values(P.tasks), ...Object.values(P.decisions)]) { for (const t of Object.values(r.t || {})) seen(t.by, t.at); for (const [n, x] of Object.entries(r.notes || {})) seen(n, x.at); }
  for (const v of Object.values(P.config)) seen(v.by, v.at);
  return m;
}
function linkBlock() {
  const e = LINK.state, name = esc(LINK.h ? LINK.h.name : D.tracking.fileName), plain = `<code>${esc(D.tracking.fileName)}</code>`;
  const fallback = `<div class="filters"><button class="btn" data-do="import-tracking">${ic('up', 'p')}Import a tracking file</button><button class="btn" data-do="export-tracking">${ic('down', 'p')}Download a copy</button>${e === 'linked' || e === 'busy' ? '<button class="btn" data-do="change-file">Choose another file</button>' : ''}</div>`;
  const msg = {
    linked: `<div class="box ok">${ic('check', 'p')} <b>Linked to ${name}.</b> Up to date at ${esc(LINK.time)}. This file is authoritative: your changes are written to it at once, and what changes there arrives here within 15 seconds.</div>`,
    unreadable: `<div class="box q">${ic('alert', 'p')} <b>File unreadable.</b> It lost its columns. The report does not overwrite it and keeps your updates. Put the first line back, or restore the copy.</div>`,
    busy: `<div class="box q">${ic('alert', 'p')} <b>File busy.</b> It is probably open in Excel: close it. Your updates are kept and leave by themselves.</div>`,
    resume: `<div class="box q">${ic('info', 'p')} <b>A permission is asked at each session.</b> The browser requires it before writing to a file. For now you work on the local copy.</div><div class="filters"><button class="btn active" data-do="link">Resume tracking</button></div>`,
    none: `<div class="box note-info">${ic('info', 'p')} <b>Report not linked yet.</b> You see the tracking known at generation. Click Link, choose ${plain} in the folder of this report, then accept the permission.</div><div class="filters"><button class="btn active" data-do="link">Link tracking</button></div>`,
    nofile: `<div class="box q">${ic('alert', 'p')} <b>This browser cannot write to a file.</b> Open the report in Edge or Chrome to work with the team.</div>`
  }[e];
  const c = readJson(KEY_COPY), copy = c && LINK.h ? `<div class="box" style="margin-top:10px"><b>Safety copy.</b> ${plur(c.n, 'row')} before the last removal, on ${esc(when(c.date))}.<div class="filters" style="margin-bottom:0"><button class="btn" data-do="restore">${ic('up', 'p')}Restore</button><button class="btn" data-do="forget-copy">Keep the current file</button></div></div>` : '';
  return `<div id="link-state">${msg}${fallback}${copy}</div>`;
}
const allItems = () => [...D.actions, ...D.tasks];
function teamView(v) {
  const people = uniq([...TEAM, ...allItems().map(assigneeOf).filter(Boolean)]), who = FP.who || ME, dm = lastActivity(), anyUpdate = people.some(n => dm[n]);
  const rows = people.map(n => { const l = allItems().filter(a => assigneeOf(a) === n), c = s => l.filter(a => statusOf(a.id) === s).length, f = l.filter(closedItem).length, d = dm[n] ? when(dm[n]) : ''; return `<tr class="${n === who ? 'chosen' : ''}"><td><button class="link" data-do="person" data-n="${esc(n)}" title="See what ${esc(n)} carries">${esc(n)}</button>${n === ME ? ' <span class="chip info">you</span>' : ''}</td><td class="num">${l.length}</td><td class="num">${c('todo')}</td><td class="num">${c('doing')}</td><td class="num">${c('blocked')}</td><td class="num">${f}</td><td style="min-width:120px"><div class="gauge"><i style="width:${pct(f, l.length)}%"></i></div></td>${anyUpdate ? `<td>${esc(d)}</td>` : ''}</tr>`; }).join('');
  const none = allItems().filter(a => !assigneeOf(a)).length, ac = activity(), arb = P.conflicts, show = (k, x) => (k === 'status' ? statusLabel(x) : x);
  const mine = who ? allItems().filter(a => assigneeOf(a) === who && !closedItem(a)) : [], lost = orphans();
  v.innerHTML = `<p class="intro">Assignees are set in each action or task. Click a name to see what that person carries.</p>
  ${ME ? '' : `<div class="box q identity"><span>${ic('info', 'p')} <b>You have not given your name.</b> Your updates carry no name and the tracking file stays closed.</span><button class="btn active" data-do="who">Give my name</button></div>`}
  ${people.length ? `<div class="frame"><table class="t"><thead><tr><th>Assignee</th><th class="num">Items</th><th class="num">To do</th><th class="num">In progress</th><th class="num">Blocked</th><th class="num">Finished</th><th>Progress</th>${anyUpdate ? '<th>Last update</th>' : ''}</tr></thead><tbody>${rows}</tbody></table></div>` : '<p class="empty">Nobody is assigned yet. Names come from the project, or from what the team types.</p>'}${none ? `<p class="muted small" style="margin-top:5px">${plur(none, 'item')} with no assignee.</p>` : ''}
  ${lost.length ? `<h2 class="sec">Tracking rows with no item in this plan</h2><p class="intro">These rows of ${esc(D.tracking.fileName)} match nothing in this plan, for example after a service was found to be absent. They stay in the file, and nothing here removes them.</p><div class="frame"><table class="t orphans"><thead><tr><th>Type</th><th>Id</th><th>Label</th><th>What it holds</th></tr></thead><tbody>${lost.map(x => `<tr><td>${esc(x.type)}</td><td>${esc(x.id)}</td><td>${esc(x.label)}</td><td>${esc(x.text)}</td></tr>`).join('')}</tbody></table></div>` : ''}
  ${P.unknown.length ? `<h2 class="sec">Tracking rows the report does not recognise</h2><p class="intro">Someone typed these rows in ${esc(D.tracking.fileName)}, and the report cannot read them, so they count for nothing here. They stay in the file exactly as they are: correct them or delete them there.</p><div class="frame"><table class="t unrecognised"><thead><tr><th>Type</th><th>Id</th><th>Field</th><th>Value</th><th>Author</th><th>Why</th></tr></thead><tbody>${P.unknown.map(x => `<tr>${[0, 1, 3, 4, 5].map(i => `<td>${esc(x.cells[i])}</td>`).join('')}<td>${esc(x.why)}</td></tr>`).join('')}</tbody></table></div>` : ''}
  <div class="two"><section><h2 class="sec">Tracking file</h2>${linkBlock()}
    ${arb.length ? `<h3 class="ssec">${ic('scale', 'p')}Conflicts to check (${arb.length})</h3><p class="muted small">Two people entered a different value: the latest was kept.</p><ul class="rows">${arb.slice(0, 8).map(x => { const a = D.actions.find(y => y.id === x.id); return `<li>${a ? `<a href="#" data-do="open-action" data-t="${esc(tabOf(a.role))}" data-id="${esc(a.id)}">${esc(a.title)}</a>` : esc(x.id)}<div class="sub-line"><span>Kept: ${esc(show(x.field, x.kept.v))}, ${esc(x.kept.by)}</span><span>Set aside: ${esc(show(x.field, x.dropped.v))}, ${esc(x.dropped.by)}</span></div></li>`; }).join('')}</ul>` : ''}</section>
  <section><h2 class="sec">Recent activity</h2>${ac.length ? `<ul class="rows">${ac.map(x => `<li><span><b>${esc(x.a.title)}</b></span><div class="sub-line">${chipT(x.a.role)}<span>${esc(x.by || 'No name')} ${esc(x.what)}</span><span>${esc(when(x.at))}</span></div></li>`).join('')}</ul>` : '<p class="empty">No update yet.</p>'}</section></div>
  <h2 class="sec">${who ? `To do for ${esc(who)}` : 'Items by person'}</h2>${mine.length ? MOMENTS.filter(m => mine.some(a => a.moment === m)).map(m => `<section class="moment"><header style="--c:var(--ink)"><div><h2>${esc(m)}</h2></div></header>${mine.filter(a => a.moment === m).map(a => (a.severity ? actionRow(a) : taskRow(a))).join('')}</section>`).join('') : `<p class="empty">${who ? 'Nothing open.' : 'Click a name in the table to see what that person carries.'}</p>`}`;
}
const closedItem = a => ['done', 'na'].includes(statusOf(a.id));
DO.person = el => { FP.who = el.dataset.n; teamView($('#view')); };

function allTasksView(v) { v.innerHTML = `${unconfirmedNote(D.tasks)}${taskFilters(FT, 'all-tasks')}<div id="task-list"></div>`; $('#task-list').innerHTML = taskList(filterTasks(D.tasks, FT)); }
CHANGE['all-tasks'] = t => { FT.ts = t.value; $('#task-list').innerHTML = taskList(filterTasks(D.tasks, FT)); };
INPUT['all-tasks-q'] = t => { FT.tq = t.value; $('#task-list').innerHTML = taskList(filterTasks(D.tasks, FT)); };

function decisionsView(v) {
  const scope = uniq(D.decisions.map(d => d.role));
  v.innerHTML = `<p class="intro">The questions to settle. An answer entered here goes to the tracking file once it is linked. Otherwise it stays in this browser: export it to keep it.</p><div class="filters">${scope.length > 1 ? `<select data-ch="fd" data-k="t" aria-label="Tenant"><option value="">All tenants</option>${scope.map(c => `<option value="${esc(c)}" ${FD.t === c ? 'selected' : ''}>${esc(nameOf(c))}</option>`).join('')}</select>` : ''}
  <select data-ch="fd" data-k="s" aria-label="Status"><option value="open" ${FD.s === 'open' ? 'selected' : ''}>Open</option><option value="decided" ${FD.s === 'decided' ? 'selected' : ''}>Decided</option><option value="" ${FD.s === '' ? 'selected' : ''}>All</option></select><span class="right"><button class="btn" data-do="csv-decisions">${ic('down', 'p')}Export</button></span></div><div id="decision-list"></div>`;
  decisionList();
}
function decisionList() {
  const l = D.decisions.filter(d => (!FD.t || d.role === FD.t) && (!FD.s || ((P.decisions[d.id] || {}).status || 'open') === FD.s));
  $('#decision-list').innerHTML = l.length ? l.map(d => { const x = P.decisions[d.id] || {}; return `<article class="action"><div style="padding:9px 12px"><div class="meta" style="margin-bottom:3px">${chipT(d.role)}<span>${esc(d.moment)}</span><span>${esc(d.owner)}</span></div><b>${esc(d.question)}</b><div class="muted small">From ${esc(String(d.origin).toLowerCase())} ${esc(d.reference)}</div><textarea class="note" style="margin-top:6px" data-in="answer" data-id="${esc(d.id)}" placeholder="The answer" aria-label="The answer">${esc(x.answer || '')}</textarea><label class="check" style="margin-top:4px"><input type="checkbox" data-ch="decided" data-id="${esc(d.id)}" ${x.status === 'decided' ? 'checked' : ''}> Decided</label></div></article>`; }).join('') : '<p class="empty">No decision for this filter.</p>';
}
CHANGE.fd = t => { FD[t.dataset.k] = t.value; decisionList(); };
CHANGE.decided = t => { write(record('d', t.dataset.id), 'status', t.checked ? 'decided' : 'open'); if (FD.s) decisionList(); };
INPUT.answer = t => write(record('d', t.dataset.id), 'answer', t.value);
DO['csv-decisions'] = () => csv('decisions.csv', ['Tenant', 'Question', 'Moment', 'Owner', 'Answer', 'Decided'], D.decisions.map(d => { const x = P.decisions[d.id] || {}; return [nameOf(d.role), d.question, d.moment, d.owner, x.answer, x.status === 'decided' ? 'Yes' : '']; }));

const NATURE = { Decision: 'Applies a decision', Partial: 'Partly automatic', Report: 'Produces a report', Automated: 'Fully automatic' };
function filterRemediations() { const q = FS.q.toLowerCase(); return D.remediations.filter(s => (!FS.nature || s.nature === FS.nature) && (!q || [s.title, s.id, s.workload, ...(s.ruleIds || [])].join(' ').toLowerCase().includes(q))); }
function remediationsView(v) {
  const natures = uniq(D.remediations.map(s => s.nature));
  v.innerHTML = `${D.remediations.some(untested) ? `<div class="box alert" style="margin-bottom:12px">${ic('alert', 'p')} <b>${esc(UNTESTED)}</b></div>` : ''}<p class="intro">Separate scripts: nothing here runs on its own, and the assessment never starts one. Each shows a preview by default and acts only on the decisions file of the project.</p>
  <div class="counters">${natures.map(n => `<button class="counter" data-do="nature" data-v="${esc(n)}" aria-pressed="${FS.nature === n}"><b>${D.remediations.filter(s => s.nature === n).length}</b><span>${esc(NATURE[n] || n)}</span></button>`).join('')}</div>
  <div class="filters"><input type="search" data-in="fs-q" placeholder="Filter the remediations" aria-label="Filter the remediations" value="${esc(FS.q)}"><span class="right"><button class="btn" data-do="csv-remediations">${ic('down', 'p')}Export</button></span></div><div id="remediation-list"></div>`;
  updateRemediations();
}
function updateRemediations() {
  const l = filterRemediations();
  $('#remediation-list').innerHTML = l.length ? `<div class="frame" style="max-height:70vh"><table class="t"><thead><tr><th>Remediation</th><th>Workload</th><th>Nature</th><th>Risk</th><th>Reversible</th><th>Permissions</th><th>Tested</th></tr></thead><tbody>${l.map(s => `<tr><td><b>${esc(s.title)}</b><div class="muted small" style="font-family:var(--mono)">${esc(s.id)}</div></td><td>${esc(s.workload)}</td><td>${esc(s.nature)}</td><td>${esc(s.risk)}</td><td>${s.reversible ? 'Yes' : 'No'}</td><td>${esc((s.permissions || []).join(', '))}</td><td>${untested(s) ? '<span class="chip warn">Untested</span>' : `<span class="chip ok" data-tip="${esc(s.testedEvidence || '')}">Tested</span>`}</td></tr>`).join('')}</tbody></table></div>` : '<p class="empty">No remediation for these filters.</p>';
}
Object.assign(DO, {
  nature(el) { FS.nature = FS.nature === el.dataset.v ? '' : el.dataset.v; remediationsView($('#view')); },
  'csv-remediations'() { csv('remediations.csv', ['Id', 'Title', 'Workload', 'Nature', 'Risk', 'Reversible', 'Permissions', 'Tested on a real tenant', 'Evidence'], filterRemediations().map(s => [s.id, s.title, s.workload, s.nature, s.risk, s.reversible ? 'Yes' : 'No', (s.permissions || []).join(' '), s.testedOnRealTenant ? 'Yes' : 'No', s.testedEvidence])); }
});
INPUT['fs-q'] = t => { FS.q = t.value; updateRemediations(); };

function logView(v) {
  v.innerHTML = `<p class="intro">The log of the collection, from ${esc(D.report.snapshotStarted)} to ${esc(D.report.snapshotFinished)}.</p><div class="filters"><input type="search" data-in="fj-q" placeholder="Filter the log" aria-label="Filter the log" value="${esc(FJ.q)}"></div><div id="log-list"></div>`;
  updateLog();
}
function updateLog() { const q = FJ.q.toLowerCase(), l = D.log.filter(x => !q || x.toLowerCase().includes(q)); $('#log-list').innerHTML = l.length ? `<div class="frame" style="max-height:72vh;padding:8px 10px;font:400 12.5px/1.5 var(--mono);white-space:pre-wrap;overflow-wrap:anywhere">${esc(l.slice(0, 1500).join('\n'))}</div><p class="muted small" style="margin-top:5px">${plur(l.length, 'line')}</p>` : '<p class="empty">No line for this filter.</p>'; }
INPUT['fj-q'] = t => { FJ.q = t.value; updateLog(); };

/* ---------- guide ---------- */
VIEWS.guide = p => {
  const parts = [['purpose', 'What this report is for'], ['start', 'Where to start'], ['tabs', 'The tabs'], ['action', 'Reading an action'], ['product', 'Reading a product sheet'], ['gaps', 'Gaps and zeros'], ['legend', 'Legend'], ['team', 'Working together'], ['present', 'Presenting'], ['keys', 'Shortcuts'], ['sources', 'Where the data comes from'], ['privacy', 'Privacy']];
  const line = (l, d) => `<tr><td><b>${esc(l)}</b></td><td>${esc(d)}</td></tr>`;
  p.innerHTML = `<h1 class="page-title">Report guide</h1><p class="lede">This file holds the assessment, the migration plan and the solutions to use.</p>
  <div class="guide" style="margin-top:20px"><nav aria-label="Guide contents">${parts.map(x => `<a href="#" data-do="anchor" data-id="g-${x[0]}">${esc(x[1])}</a>`).join('')}</nav><div>
  <section id="g-purpose"><h2>What this report is for</h2><p>It is the reference document of the migration. It serves the team that does the work, the customer who decides, and anyone who wants to understand the state of the tenants.</p></section>
  <section id="g-start"><h2>Where to start</h2><ol><li>Open the <b>Summary</b>: the ledger shows what arrives in the target.</li><li>Read <b>Solutions and products</b> to see which tool does what.</li><li>Choose a tenant and follow its <b>Action plan</b>, moment by moment.</li><li>Record the answers in <b>Steering</b>.</li></ol></section>
  <section id="g-tabs"><h2>The tabs</h2><div class="frame"><table class="t"><tbody>${line('Summary', 'The consolidation ledger, progress, what blocks, and the readiness of each tenant.')}${line(SOURCES.map(nameOf).join(', '), 'One migration per tab: action plan, tasks, portrait, configurations, identities, DNS and data.')}${line(nameOf('Target'), 'What must be ready in the target before the first cutover.')}${line('Solutions and products', 'The copy tool matrix, the EWS retirement and the product sheets.')}${line('Analysis', 'Consolidation, workloads, findings, compared settings, coverage and method.')}${line('Steering', 'Team, tasks, decisions, remediations and the collection log, when there are any.')}</tbody></table></div></section>
  <section id="g-action"><h2>Reading an action</h2><p>Click an action to expand it. It holds what was found, the goal, the steps with their commands, the configuration, the verification, what to watch, the items concerned and any linked remediation.</p></section>
  <section id="g-product"><h2>Reading a product sheet</h2><p>Each sheet says what the product does, what to do before, during and after the migration, its limits with their source and the day they were checked, and its traces in your tenants. Traces are the rows of the snapshot that cite the product, outside the tables about people. Finding nothing proves little if tables could not be read: the sheet says so.</p></section>
  <section id="g-gaps"><h2>Gaps and zeros</h2><p>A zero means the table was read and holds nothing: the service is not used. <b>Not collected</b> means the table could not be read. <b>Not fully read</b> means it came back empty from a partial read, so its rows may be in what was missed. Both are gaps: they never count as zero. <b>At least</b> marks a total that leaves out a tenant that was not read. <b>Unconfirmed</b> marks a task the plan keeps because what it depends on could not be read.</p></section>
  <section id="g-legend"><h2>Legend</h2><div class="legend"><span class="chip blocking">Critical</span><span>Fix before any copy.</span><span class="chip warn">High</span><span>Handle before the cutover.</span><span class="chip">Medium, Low</span><span>To schedule.</span><span class="chip info">Info</span><span>For information.</span><span class="chip blocking">${ic('alert', 'p')}Blocks the cutover</span><span>The cutover waits until the action is done.</span>${[...SOURCES, 'Target'].map(c => `${chipT(c)}<span>${c === 'Target' ? 'Target' : `Source, wave ${esc(T[c].wave)}`}</span>`).join('')}</div></section>
  <section id="g-team"><h2>Working together</h2><p>Team tracking lives in one file, <code>${esc(D.tracking.fileName)}</code>, next to the report. Statuses, assignees, notes, ticks and decisions are stored there.</p><ol><li>Open the report in Edge or Chrome, from the team folder.</li><li>The first time, the report asks who you are. The menu of the top bar changes it later. Clicking a name in <b>Steering, Team</b> shows what that person carries, without changing who you are.</li><li>Click <b>Link tracking</b> and choose the file. Next time, click <b>Resume tracking</b>: the browser asks this permission at each session.</li><li>Work as usual. Each change is written to the file, and those of your colleagues arrive every 15 seconds.</li></ol><p style="margin-top:6px"><b>The file is authoritative.</b> A row removed or changed by hand shows in everyone's report, and a safety copy lets you go back from <b>Steering, Team</b>. A new version of the report loses nothing: it reads the file when it is generated, and generating never writes to it. If two people enter a different value at the same time, the latest is kept and the gap stays visible in <b>Steering, Team</b>. Each person has their own note. A row whose item left the plan stays visible there too. So does a row the report cannot read, such as a status it does not know: it counts for nothing, and it stays in the file as it is until someone corrects or deletes it.</p><p style="margin-top:6px">Close Excel after looking at the file: while it is open, Excel locks it. The report says so, keeps your updates and writes them as soon as the file is free.</p></section>
  <section id="g-present"><h2>Presenting</h2><p>The screen button, or the <kbd>P</kbd> key, starts a series of ${PRESENTATION.length} views for a meeting. The arrows change view, <kbd>Esc</kbd> leaves.</p></section>
  <section id="g-keys"><h2>Shortcuts</h2><div class="legend"><kbd>/</kbd><span>Go to the search.</span><kbd>P</kbd><span>Start the presentation.</span><kbd>?</kbd><span>Open this guide.</span><kbd>Esc</kbd><span>Close the search or the presentation.</span></div></section>
  <section id="g-sources"><h2>Where the data comes from</h2><p>Snapshot of ${esc(D.report.snapshotFinished)}, read by TenantConverge ${esc(D.report.moduleVersion)}. Report generated on ${esc(D.report.generated)}. Product facts checked on ${esc(SOL.checkedOn)}.</p><h3 class="ssec">Outside sources</h3><ul class="list">${Object.values(SOL.sources).filter(s => safeUrl(s.url)).map(s => `<li>${esc(s.publisher)}: ${extLink(s.url, s.title)}</li>`).join('')}</ul></section>
  <section id="g-privacy"><h2>Privacy</h2><p>This file holds personal data and the configuration of the tenants. It works offline and sends nothing to the Internet. Do not put it in a shared space without the agreement of the customer.</p></section>
  </div></div>`;
};
DO.anchor = (el, e) => { e.preventDefault(); document.getElementById(el.dataset.id).scrollIntoView({ block: 'start' }); };

/* ---------- analysis: what the assessment showed ---------- */
const FC = { q: '', severity: '', workload: '', moment: '', owner: '', t: '' };
const FE = { q: '', workload: '', important: false };
const WORKLOAD_HELP = {
  'Entra ID': 'Accounts, groups, roles, access rules and applications.',
  'Exchange Online': 'Mailboxes, addresses, mail flow and retention.',
  'Domains and DNS': 'The domains that move, and what they publish.',
  'SharePoint and OneDrive': 'Sites, personal storage and sharing.',
  Teams: 'Teams, channels, settings and apps.',
  'Teams Phone': 'Numbers, routing, auto attendants and call queues.',
  Intune: 'Devices, policies and applications.',
  Purview: 'Labels, retention and data loss prevention.',
  'Power Platform': 'Environments, apps and flows.',
  Azure: 'Subscriptions and resources.',
  'Other services': 'Planner, Bookings, Viva Engage and the rest.'
};
VIEWS.analysis = p => {
  const list = [['consolidation', 'Consolidation', 'merge'], ['workloads', 'Workloads', 'grid', WORKLOADS.length], ['findings', 'Findings', 'list', D.findings.length]];
  if (D.settingGaps.length) list.push(['gaps', 'Compared settings', 'settings', D.settingGaps.length]);
  list.push(['coverage', 'Coverage and method', 'database']);
  const s = list.some(x => x[0] === R.sub) ? R.sub : 'consolidation'; R.sub = s;
  const y = D.summary;
  p.innerHTML = `<h1 class="page-title">${presIndex >= 0 ? `What ${esc(nameOf('Target'))} will take in` : `Analysis of ${esc(plur(ROLES.length, 'tenant'))}`}</h1><p class="lede no-pres">Everything the assessment showed, tenant by tenant and put together. ${plur(y.findings, 'finding')}, ${plur(y.rows, 'row')} of data, ${plur(y.gaps, 'setting')} that differ.</p>
  ${subnav(list, s)}<div id="view"></div>`;
  ({ consolidation: consolidationView, workloads: workloadsView, findings: findingsView, gaps: gapsView, coverage: coverageView })[s]($('#view'));
};
function measureTable(ms, title = 'Indicator') {
  const roles = ['Target', ...SOURCES]; let last = '';
  return `<div class="frame"><table class="t"><thead><tr><th>${esc(title)}</th>${roles.map(c => `<th class="num">${esc(nameOf(c))}</th>`).join('')}<th class="num">After</th><th>Split</th></tr></thead><tbody>${ms.map(m => {
    const v = m.values || {}, total = roles.reduce((a, c) => a + (typeof v[c] === 'number' ? v[c] : 0), 0);
    const bar = m.additive && total > 0 ? `<div class="split" role="img" aria-label="${esc(roles.map(c => `${nameOf(c)} ${pct(v[c] || 0, total)} %`).join(', '))}">${roles.filter(c => (v[c] || 0) > 0).map(c => `<span style="--c:${colorOf(c)};flex:${v[c]}" data-tip="${esc(nameOf(c))}: ${esc(nb(v[c]))} (${pct(v[c], total)} %)"></span>`).join('')}</div>` : m.additive ? '' : '<span class="muted small">does not add up</span>';
    let g = ''; if (title === 'Indicator' && m.workload !== last && ms.length > 12) { last = m.workload; g = `<tr class="group"><td colspan="${roles.length + 3}">${esc(m.workload)}</td></tr>`; }
    const after = !m.additive ? '' : m.after === null || m.after === undefined ? (typeof m.sources === 'number' ? `<span class="minimum">at least ${esc(nb(m.sources))}</span>` : '<span class="chip warn gap">Not read</span>') : totalCell(m.after, m);
    return `${g}<tr><td>${esc(m.label)}</td>${roles.map(c => `<td class="num">${measureCell(m, c)}</td>`).join('')}<td class="num"><b>${after}</b></td><td>${bar}</td></tr>`;
  }).join('')}</tbody></table></div>`;
}
const findingBlock = (t, x) => (x ? `<h4>${esc(t)}</h4><p>${esc(x)}</p>` : '');
function findingItem(c, open) {
  return `<details class="item" id="c${c.index}" ${open ? 'open' : ''}><summary><span class="chip ${SEVERITY_CLASS[c.severity] || ''}">${esc(c.severity)}</span><b>${esc(c.title)}</b>${chipT(c.code)}</summary><div class="item-body">${findingBlock('Finding', c.finding)}${findingBlock('Why it matters', c.why)}${findingBlock('Recommended action', c.action)}${c.question ? findingBlock('Question to settle', c.question) : ''}
  <div class="small muted" style="display:flex;flex-wrap:wrap;gap:4px 14px;margin-top:7px"><span>Workload: ${esc(c.workload)}</span><span>Owner: ${esc(c.owner)}</span><span>Effort: ${esc(c.effort)}</span><span>Moment: ${esc(c.moment)}</span><span>Rule ${esc(c.id)}</span></div>
  ${(c.items || []).length ? `<h4>Items concerned (${nb(c.itemCount || c.items.length)})</h4><div class="items">${c.items.map(x => `<div>${esc(x)}</div>`).join('')}</div>` : ''}</div></details>`;
}
const findingList = (l, o) => (l.length ? l.map(c => findingItem(c, o === c.index)).join('') : '<p class="empty">No finding for these filters.</p>');
function consolidationView(v) {
  const cons = D.findings.filter(c => c.code === 'Consolidation').sort(sortFindings);
  v.innerHTML = `<h2 class="sec" style="margin-top:8px">What ${esc(nameOf('Target'))} will take in</h2><p class="intro">"After" adds the target and every source, before cleanup. "At least" means a tenant could not be read. Indicators that do not add up compare tenant by tenant.</p>${measureTable(D.measures)}
  <h2 class="sec">Consolidation findings</h2><p class="intro">What only shows when all the tenants are read together: duplicates, name collisions, capacity.</p>${findingList(cons)}`;
}
function workloadsView(v) {
  const current = WORKLOADS.find(x => slug(x) === R.arg), roles = ['Target', ...SOURCES];
  if (!current) { v.innerHTML = `<p class="intro">One line per workload, one column per tenant. Click a cell to open the workload.</p>${heatMap(roles, WORKLOADS)}`; return; }
  const ms = D.measures.filter(m => m.workload === current), ec = D.settingGaps.filter(e => e.workload === current), tabs = Object.keys(D.tableLabels).filter(k => D.tableLabels[k].workload === current);
  v.innerHTML = `<p><a href="#/analysis/workloads">All workloads</a></p><h2 class="sec" style="margin-top:6px">${esc(current)}</h2><p class="intro">${esc(WORKLOAD_HELP[current] || '')}</p>${heatMap(roles, [current])}
  ${ms.length ? `<h3 class="ssec">Indicators</h3>${measureTable(ms, 'Measure')}` : ''}${ec.length ? `<h3 class="ssec">Settings that differ</h3><p class="intro">Highlighted values differ from the target: the target imposes its value after the cutover.</p>${gapTable(ec)}` : ''}
  <h3 class="ssec">Findings</h3>${findingList(D.findings.filter(c => c.workload === current).sort(sortFindings))}
  ${tabs.length ? `<h3 class="ssec">Collected data</h3><div style="display:flex;flex-wrap:wrap;gap:4px">${tabs.map(k => `<button class="chip" data-do="go-table" data-t="Target" data-k="${esc(k)}" data-q="">${esc(D.tableLabels[k].label)}</button>`).join('')}</div>` : ''}`;
}
function filterFindings() { const q = FC.q.toLowerCase(); return D.findings.filter(c => (!FC.severity || c.severity === FC.severity) && (!FC.workload || c.workload === FC.workload) && (!FC.moment || c.moment === FC.moment) && (!FC.owner || c.owner === FC.owner) && (!FC.t || c.code === FC.t) && (!q || [c.title, c.finding, c.action, c.id, (c.items || []).join(' ')].join(' ').toLowerCase().includes(q))).sort(sortFindings); }
function findingsView(v) {
  const o = R.arg !== '' && !isNaN(+R.arg) ? +R.arg : null;
  if (o != null) Object.assign(FC, { q: '', severity: '', workload: '', moment: '', owner: '', t: '' });
  const sel = (k, label, l) => `<select data-ch="fc" data-k="${k}" aria-label="${esc(label)}"><option value="">${esc(label)}</option>${l.map(x => `<option value="${esc(x[0])}" ${FC[k] === x[0] ? 'selected' : ''}>${esc(x[1])}</option>`).join('')}</select>`;
  const pairs = l => l.map(x => [x, x]);
  v.innerHTML = `<p class="intro">Each finding says what was seen, why it matters, what to do, who does it and when.</p><div class="filters"><input type="search" data-in="fc-q" placeholder="Search a word, an account, a site" aria-label="Search the findings" value="${esc(FC.q)}">
  ${sel('t', 'All tenants', [...['Target', ...SOURCES].map(c => [c, nameOf(c)]), ...(D.findings.some(c => c.code === 'Consolidation') ? [['Consolidation', 'Consolidation']] : [])])}${sel('severity', 'All severities', pairs(SEVERITIES))}${sel('workload', 'All workloads', pairs(uniq(D.findings.map(c => c.workload)).sort()))}${sel('moment', 'All moments', pairs(MOMENTS))}${sel('owner', 'All owners', pairs(uniq(D.findings.map(c => c.owner)).sort()))}
  <span class="right"><button class="btn" data-do="csv-findings">${ic('down', 'p')}Export</button></span></div><p class="muted small" id="finding-count"></p><div id="finding-list"></div>`;
  updateFindings(o);
  if (o != null) { const n = document.getElementById('c' + o); if (n) n.scrollIntoView({ block: 'center' }); }
}
function updateFindings(o) { const l = filterFindings(); $('#finding-count').textContent = plur(l.length, 'finding'); $('#finding-list').innerHTML = findingList(l, o); }
CHANGE.fc = t => { FC[t.dataset.k] = t.value; updateFindings(); };
INPUT['fc-q'] = t => { FC.q = t.value; updateFindings(); };
DO['csv-findings'] = () => csv('findings.csv', ['Tenant', 'Severity', 'Workload', 'Title', 'Finding', 'Action', 'Owner', 'Moment', 'Effort'], filterFindings().map(c => [nameOf(c.code), c.severity, c.workload, c.title, c.finding, c.action, c.owner, c.moment, c.effort]));

const gapValue = x => (x === null || x === undefined ? '' : (typeof x === 'object' ? JSON.stringify(x) : String(x)));
function gapTable(ec) {
  const roles = ['Target', ...SOURCES], any = ec.some(e => e.important);
  return `<div class="frame" style="max-height:70vh"><table class="t"><thead><tr><th>Setting</th>${roles.map(c => `<th>${chipT(c)}</th>`).join('')}${any ? '<th>Important</th>' : ''}</tr></thead><tbody>${ec.map(e => { const v = e.values || {}, dif = e.different || [], label = D.tableLabels[e.table] || {}; return `<tr><td><b>${esc(e.setting)}</b><div class="muted small">${esc(label.label || e.table)}</div></td>${roles.map(c => `<td class="${dif.includes(c) ? 'diff' : ''}">${esc(gapValue(v[c]))}</td>`).join('')}${any ? `<td>${e.important ? '<span class="chip warn">Important</span>' : ''}</td>` : ''}</tr>`; }).join('')}</tbody></table></div>`;
}
function filterGaps() { const q = FE.q.toLowerCase(); return D.settingGaps.filter(e => (!FE.important || e.important) && (!FE.workload || e.workload === FE.workload) && (!q || (e.setting + ' ' + e.table).toLowerCase().includes(q))); }
function gapsView(v) {
  const vs = uniq(D.settingGaps.map(e => e.workload));
  v.innerHTML = `<p class="intro">The settings of each source compared with those of the target. After the cutover, migrated users live with the settings of the target: each highlighted gap is a change of behavior to announce or align.</p>
  <div class="filters"><input type="search" data-in="fe-q" placeholder="Search a setting" aria-label="Search a setting" value="${esc(FE.q)}"><select data-ch="fe-workload" aria-label="Workload"><option value="">All workloads</option>${vs.map(x => `<option ${FE.workload === x ? 'selected' : ''}>${esc(x)}</option>`).join('')}</select><label class="check"><input type="checkbox" data-ch="fe-important" ${FE.important ? 'checked' : ''}> Important gaps only</label><span class="right"><button class="btn" data-do="csv-gaps">${ic('down', 'p')}Export</button></span></div><div id="gap-list"></div>`;
  updateGaps();
}
function updateGaps() { const l = filterGaps(); $('#gap-list').innerHTML = l.length ? `<p class="muted small" style="margin-bottom:5px">${plur(l.length, 'setting')}</p>${gapTable(l)}` : '<p class="empty">No gap for these filters.</p>'; }
Object.assign(CHANGE, { 'fe-workload'(t) { FE.workload = t.value; updateGaps(); }, 'fe-important'(t) { FE.important = t.checked; updateGaps(); } });
INPUT['fe-q'] = t => { FE.q = t.value; updateGaps(); };
DO['csv-gaps'] = () => { const roles = ['Target', ...SOURCES]; csv('compared-settings.csv', ['Workload', 'Table', 'Setting', 'Important', ...roles.map(nameOf)], filterGaps().map(e => [e.workload, e.table, e.setting, e.important ? 'Yes' : '', ...roles.map(r => gapValue(e.values[r]))])); };
DO['go-gap'] = el => { closeSearch(); Object.assign(FE, { q: el.dataset.q, workload: '', important: false }); go('analysis', 'gaps'); };

function coverageView(v) {
  const cv = D.coverage, ids = []; cv.forEach(c => { if (!ids.find(x => x.id === c.id)) ids.push({ id: c.id, title: c.title, workload: c.workload, service: c.service }); });
  const issues = cv.filter(c => c.status !== 'OK'), roles = ['Target', ...SOURCES], s = D.summary, stopped = D.errors || [], missed = D.unread || [];
  const cell = (role, id) => { const c = cv.find(x => x.role === role && x.id === id); if (!c) return T[role].collection === 'Absent' ? '<span class="chip warn">Not reached</span>' : '<span class="muted">Not run</span>'; return `<span class="chip ${c.status === 'OK' ? 'ok' : c.status === 'Partial' ? 'warn' : c.status === 'License or service missing' ? '' : 'blocking'}" data-tip="${esc(c.message || c.status)}">${c.status === 'OK' ? 'Collected' : esc(c.status)}</span>`; };
  let last = '';
  v.innerHTML = `<p class="intro">What the assessment could read, what is missing and how conclusions are drawn.</p>
  <div class="counters"><div class="counter"><b>${nb(s.collectors)}</b><span>collectors run</span></div><div class="counter"><b>${nb(s.collected)}</b><span>clean</span></div><div class="counter"><b>${nb(s.partial)}</b><span>partial</span></div><div class="counter"><b>${nb(s.missing)}</b><span>missing</span></div><div class="counter"><b>${nb(s.tables)}</b><span>tables</span></div><div class="counter"><b>${nb(s.rows)}</b><span>rows</span></div></div>
  <h2 class="sec">What is missing</h2>${issues.length ? `<ul class="rows">${issues.map(c => `<li><b>${esc(c.id)} ${esc(c.title)}</b><div class="sub-line">${chipT(c.role)}<span class="chip ${c.status === 'Partial' ? 'warn' : 'blocking'}">${esc(c.status)}</span></div><div class="muted">${esc(c.message)}</div>${c.remedy ? `<div><b>To fix:</b> ${esc(c.remedy)}</div>` : ''}</li>`).join('')}</ul>` : `<p class="empty">${cv.length ? 'Every collector finished clean.' : 'No collector ran.'}</p>`}
  ${missed.length ? `<h3 class="ssec">Tables the rules needed and could not read</h3><ul class="list">${uniq(missed.map(u => `${nameOf(u.tenantRole || u.role)}: ${(D.tableLabels[u.table] || { label: u.table }).label}`)).map(x => `<li>${esc(x)}</li>`).join('')}</ul>` : ''}
  ${stopped.length ? `<h3 class="ssec">Rules that stopped</h3><p class="intro">A rule that stopped counts as not read: its workload earns no credit.</p><ul class="list">${stopped.map(e => `<li>${esc(e.workload || '')} ${esc(e.role || '')}: ${esc(e.message || e.error || '')}</li>`).join('')}</ul>` : ''}
  <h2 class="sec">Method</h2><div style="max-width:82ch"><p><b>Read-only.</b> The assessment only calls read commands. It changes no tenant, and the analysis runs offline, from the collected tables.</p>
  <p style="margin-top:6px"><b>Not collected and not used.</b> A table that was read and is empty means the service is not used. A table that was not read, or that came back empty from a partial read, says nothing: the report shows it as a gap, never as zero.</p>
  <p style="margin-top:6px"><b>Workload states.</b> Each workload of a tenant takes the state of its most severe finding: Blocking for Critical, To address for High, Secondary for Medium, Passed otherwise. A workload with nothing against it and no data is Not collected.</p>
  <p style="margin-top:6px"><b>Score.</b> Counts every workload the tenant has: Passed is worth 100, Secondary 70, To address 35, Blocking 0. A workload earns its value only if everything it needs was read, so losing a service never raises the score. <b>Score of what was read</b> averages the workloads that were read, with no penalty for the others. The gap between the two shows how much of the picture is missing.</p>
  <p style="margin-top:6px"><b>Consolidation.</b> The rules read all the tenants together: people in several tenants, colliding addresses and aliases, sites and teams of the same name, storage and license capacity of the target after every source.</p>
  <p style="margin-top:6px"><b>What this report cannot see.</b> Products with no administration interface are in the list below, for their owners to validate.</p></div>
  ${(D.manualProducts || []).length ? `<h2 class="sec">Products to validate by hand</h2><div class="frame"><table class="t"><thead><tr><th>Product</th><th>Inventory</th><th>Migration</th><th>To do</th></tr></thead><tbody>${D.manualProducts.map(p => `<tr><td><b>${esc(p.Product)}</b></td><td>${esc(p.Inventory)}</td><td>${esc(p.Migration)}</td><td>${esc(p['To do'])}</td></tr>`).join('')}</tbody></table></div>` : ''}
  ${ids.length ? `<h2 class="sec">Collectors by tenant</h2><p class="intro">Hover a cell to read the message of the collection.</p><div class="frame" style="max-height:72vh"><table class="t"><thead><tr><th>Collector</th>${roles.map(c => `<th>${chipT(c)}</th>`).join('')}</tr></thead><tbody>${ids.map(x => { let g = ''; if (x.workload !== last) { last = x.workload; g = `<tr class="group"><td colspan="${roles.length + 1}">${esc(x.workload)}</td></tr>`; } return `${g}<tr><td><b>${esc(x.id)}</b> ${esc(x.title)}<div class="muted small">${esc(x.service)}</div></td>${roles.map(c => `<td>${cell(c, x.id)}</td>`).join('')}</tr>`; }).join('')}</tbody></table></div>` : ''}`;
}

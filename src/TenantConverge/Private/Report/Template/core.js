'use strict';
/* ---------- data ---------- */
const D = JSON.parse(document.getElementById('report-data').textContent);
document.getElementById('report-data').textContent = '';
const SOL = D.solutions;
let TAB = null;   /* the rows of the snapshot: read at the first need */
function inventory() { if (!TAB) { const n = document.getElementById('report-tables'); TAB = JSON.parse(n.textContent); n.textContent = ''; } return TAB; }

/* ---------- tools ---------- */
const $ = (s, r = document) => r.querySelector(s);
const esc = v => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const ic = (n, c = '') => `<svg class="i ${c}" aria-hidden="true"><use href="#i-${n}"/></svg>`;
const NF = new Intl.NumberFormat('en-US');
const nb = v => (typeof v === 'number' ? NF.format(v) : (v ?? ''));
const pct = (a, b) => b ? Math.round(100 * a / b) : 0;
const plur = (n, s, p) => `${nb(n)} ${n === 1 ? s : (p || s + 's')}`;
const uniq = l => [...new Set(l)];
const slug = s => String(s).toLowerCase().replace(/[^a-z0-9]+/g, '-');
/* Only our own catalogs hold addresses, and only https ones may become links. */
const safeUrl = u => (/^https:\/\/[^\s"'<>]+$/i.test(String(u ?? '')) ? String(u) : '');
const extLink = (u, t) => { const s = safeUrl(u); return s ? `<a href="${esc(s)}" target="_blank" rel="noopener noreferrer">${esc(t)}</a>` : esc(t); };
const T = Object.fromEntries(D.tenants.map(t => [t.role, t]));
const ROLES = D.tenants.map(t => t.role), SOURCES = ROLES.filter(r => r !== 'Target'), MOMENTS = D.moments;
const nameOf = r => r === 'All' ? 'All tenants' : (T[r] ? T[r].name : (r === 'Consolidation' ? 'Consolidation' : r));
const colorOf = r => `var(--${ROLES.includes(r) ? r : 'All'})`;
const chipT = r => `<span class="chip t" style="--c:${colorOf(r)}">${esc(nameOf(r))}</span>`;
const tabOf = r => (r === 'All' ? 'Target' : r);

/* Rules write "3 account(s)": the true form follows the number before it. */
function agree(t) {
  if (typeof t !== 'string' || !t.includes('(')) return t;
  return t.split(/(?=\b\d[\d,]*\s\p{L})/u).map(seg => { const m = seg.match(/^(\d[\d,]*)/), many = !m || parseInt(m[1].replace(/,/g, ''), 10) !== 1; return seg.replace(/\((es|s)\)/g, (x, l) => many ? l : ''); }).join('');
}
for (const a of [...D.actions, ...D.findings]) { for (const k of ['title', 'finding', 'action', 'why', 'question']) a[k] = agree(a[k]); a.items = (a.items || []).map(agree); }
D.findings.forEach((c, i) => { c.index = i; });

const STATUSES = [['todo', 'To do'], ['doing', 'In progress'], ['done', 'Done'], ['blocked', 'Blocked'], ['na', 'Not applicable']];
const SEVERITY_CLASS = { Critical: 'blocking', High: 'warn', Medium: '', Low: '', Info: 'info' };
const SEVERITIES = ['Critical', 'High', 'Medium', 'Low', 'Info'];
const WORKLOAD_ICON = { 'Entra ID': 'shield', 'Exchange Online': 'mail', 'SharePoint and OneDrive': 'folder', Teams: 'chat', 'Teams Phone': 'phone', Intune: 'laptop', Purview: 'lock', 'Domains and DNS': 'globe', Consolidation: 'merge', 'Other services': 'grid', Coverage: 'database', Identities: 'people', General: 'grid', Azure: 'database', 'Power Platform': 'grid' };
const MOMENT_HELP = {
  Now: 'Decisions and cleanup to start right away: the rest depends on them.',
  Preparation: 'Put the foundation in place and prepare the pre-copy.',
  'Before cutover': 'To finish before the cutover weekend.',
  Cutover: 'The day itself: freeze, domains, DNS, opening the accounts.',
  'After cutover': 'Reconciliation, user follow-up and fixes.',
  Closure: 'Close the source tenants cleanly.'
};
function toast(m) { const t = $('#toast'); t.textContent = m; t.classList.add('shown'); clearTimeout(toast.h); toast.h = setTimeout(() => t.classList.remove('shown'), 2200); }
function download(name, content, type) { const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([content], { type })); a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(a.href), 2000); }

/* The same guard as ConvertTo-TcCsvCell: a person opens these files in Excel, and tenant text is hostile. */
const FORMULA = /^\s*[=+\-@＝＋－＠]/, PLAIN_NUMBER = /^\s*[+-]?\d+([.,]\d+)?\s*$/;
const safeCell = v => { const t = String(v ?? ''); return FORMULA.test(t) && !PLAIN_NUMBER.test(t) ? "'" + t : t; };
function csv(name, heads, rows) {
  const q = v => `"${safeCell(v).replace(/"/g, '""')}"`;
  download(name, '﻿' + [heads.map(q).join(','), ...rows.map(l => l.map(q).join(','))].join('\r\n') + '\r\n', 'text/csv;charset=utf-8');
  toast(plur(rows.length, 'row exported', 'rows exported'));
}
const when = iso => { const d = new Date(iso); return isNaN(d) ? '' : d.toLocaleString('en-CA', { dateStyle: 'short', timeStyle: 'short' }); };
const sourceLink = k => { const s = SOL.sources[k]; return s ? extLink(s.url, s.publisher) : ''; };
const sourceTitle = k => { const s = SOL.sources[k]; return s ? `${s.publisher}: ${s.title}` : ''; };
const checked = f => (f.recheck ? `<span class="chip warn" title="The page could not be read on the last check">To confirm, read on ${esc(f.verifiedOn)}</span>` : `<span class="muted small">Checked ${esc(f.verifiedOn)}</span>`);

/* ---------- gaps: what was not read never reads as a zero ---------- */
const stateOf = (role, table) => ((D.tableStates[role] || {})[table]) || { state: 'NotCollected', status: 'Not run', message: '', remedy: '' };
const isGap = s => s.state === 'NotCollected' || s.state === 'NotFullyRead';
const GAP_LABEL = { NotCollected: 'Not collected', NotFullyRead: 'Not fully read' };
function gapChip(role, table) {
  const s = stateOf(role, table), tip = `${nameOf(role)}: ${GAP_LABEL[s.state] || 'Not read'}${s.status ? ` (${s.status})` : ''}. ${s.message || ''} This is a gap, not a zero.`;
  return `<span class="chip warn gap" data-tip="${esc(tip)}">${esc(GAP_LABEL[s.state] || 'Not read')}</span>`;
}
const measureOf = label => D.measures.find(x => x.label === label);
const measureValue = (m, role) => (m ? m.values[role] : undefined);
/* A value of a measure, as a person should read it. A source of the project missing from the measure is a gap too. */
function measureCell(m, role) { const v = measureValue(m, role); return v === null || v === undefined ? gapChip(role, m ? m.table : '') : esc(nb(v)); }
const missingSources = m => SOURCES.filter(r => { const v = measureValue(m, r); return v === null || v === undefined; });
/* The total of the sources: a minimum when a source was not read, and a gap when none was. */
function totalCell(value, m) {
  if (value === null || value === undefined) return '<span class="chip warn gap" data-tip="No value could be read for this line.">Not read</span>';
  const missing = missingSources(m);
  return missing.length ? `<span class="minimum" data-tip="${esc('At least: not read in ' + missing.map(nameOf).join(', '))}">at least ${esc(nb(value))}</span>` : esc(nb(value));
}
/* The consolidated figure, for the chart and the sheet alike: a minimum when a tenant was not read, nothing when no source was. */
const consolidated = m => {
  if (!m) return null;
  if (m.after !== null && m.after !== undefined) return { value: m.after, minimum: missingSources(m).length > 0 };
  return typeof m.sources === 'number' ? { value: m.sources, minimum: true, targetUnread: true } : null;
};

/* ---------- actions ---------- */
const closed = a => ['done', 'na'].includes(statusOf(a.id));
const actionsOf = r => D.actions.filter(a => a.role === r || (r === 'Target' && a.role === 'All'));
const openBlocking = l => l.filter(a => a.blocking && !closed(a)).length;
const tasksOf = r => D.tasks.filter(t => t.role === r || (r === 'Target' && t.role === 'All') || (t.sources || []).includes(r));
const remediation = id => D.remediations.find(x => x.id === id);
const UNTESTED = 'UNTESTED: this script has never been run on a real tenant. Read it, try it on a test tenant first, and use it at your own risk.';
const untested = x => !x.testedOnRealTenant;

/* ---------- readiness: computed by Get-TcReadiness, only shown here ---------- */
const STATE_KEY = { Blocking: 'b', 'To address': 't', Secondary: 's', Passed: 'p', 'Not collected': 'n' };
const STATE_PRIORITY = ['Blocking', 'To address', 'Secondary', 'Passed', 'Not collected'];
const readinessOf = r => D.readiness.find(x => x.Role === r);
const readLine = (r, w) => { const x = readinessOf(r); return x ? (x.Workloads || []).find(y => y.Workload === w) : null; };
const WORKLOADS = uniq(D.readiness.flatMap(x => (x.Workloads || []).map(y => y.Workload)));
const nothingRead = x => !x || !(x.Workloads || []).some(w => w.State !== 'Not collected');
const sortFindings = (a, b) => SEVERITIES.indexOf(a.severity) - SEVERITIES.indexOf(b.severity) || MOMENTS.indexOf(a.moment) - MOMENTS.indexOf(b.moment);

/* ---------- navigation ---------- */
const TABS = [
  { id: 'summary', name: 'Summary', ic: 'compass' },
  ...SOURCES.map(r => ({ id: r, name: nameOf(r), t: 1 })), { id: 'Target', name: `${nameOf('Target')} (target)`, t: 1 },
  { id: 'solutions', name: 'Solutions and products', ic: 'tool' }, { id: 'analysis', name: 'Analysis', ic: 'lens' },
  { id: 'steering', name: 'Steering', ic: 'scale' }, { id: 'guide', name: 'Guide', ic: 'book' }
];
const ACTIVE_MOMENTS = MOMENTS.filter(m => D.actions.some(a => a.moment === m));
const R = { tab: 'summary', sub: '', arg: '' };
const VIEWS = {};           /* pages: solutions, analysis, steering, guide, summary */
const DO = {}, CHANGE = {}, INPUT = {};   /* handlers by name */
const opened = new Set();
function go(tab, sub = '', arg = '') { const h = '#/' + [tab, sub, arg].filter(Boolean).map(encodeURIComponent).join('/'); if (location.hash === h) route(); else location.hash = h; }
const decode = s => { try { return decodeURIComponent(s); } catch (e) { return ''; } };
function route() {
  const [o, s, a] = location.hash.replace(/^#\/?/, '').split('/').map(decode);
  const before = R.tab + '|' + R.sub;
  R.tab = TABS.some(x => x.id === o) ? o : 'summary'; R.sub = s || ''; R.arg = a || '';
  renderTabs(); render();
  if (R.anchor) { const el = document.getElementById(R.anchor); R.anchor = ''; if (el) el.scrollIntoView({ block: 'start' }); }
  else if (before !== R.tab + '|' + R.sub) window.scrollTo(0, 0);
  align();
}
function renderTabs() {
  $('#tabs').innerHTML = TABS.map(o => {
    let count = '';
    if (o.t) { const n = openBlocking(actionsOf(o.id)); count = n ? `<span class="count" title="${plur(n, 'open blocking action', 'open blocking actions')}">${ic('alert')}${n}</span>` : ''; }
    return `<a class="tab" href="#/${o.id}" ${R.tab === o.id ? 'aria-current="page"' : ''} style="--c:${o.t ? colorOf(o.id) : 'var(--ink)'}">${o.t ? '<span class="dot"></span>' : ic(o.ic)}<span class="tab-name">${esc(o.name)}</span>${count}</a>`;
  }).join('');
}
function render() { const p = $('#page'); (VIEWS[R.tab] || tenantPage)(p); }
/* The bars are sticky: the offsets follow their real height. */
function align() { const h = $('.topbar').offsetHeight; $('#tabs').style.top = innerWidth > 640 ? h + 'px' : ''; document.documentElement.style.scrollPaddingTop = (h + 60) + 'px'; }
const subnav = (list, current, color) => `<div class="subnav" role="group" aria-label="Views of this section" style="--c:${color || 'var(--ink)'}">${list.map(([k, l, i, n]) => `<button data-do="sub" data-s="${esc(k)}" aria-current="${current === k}">${i ? ic(i) : ''}${esc(l)}${n ? `<span class="n">${nb(n)}</span>` : ''}</button>`).join('')}</div>`;
DO.sub = el => go(R.tab, el.dataset.s);

/* ---------- search everywhere ---------- */
let searchTimer = null;
function search(q) {
  const z = $('#results'); q = q.trim().toLowerCase(); clearTimeout(searchTimer);
  if (q.length < 2) { z.classList.remove('open'); return; }
  const has = (...v) => v.join(' ').toLowerCase().includes(q), groups = [];
  const g = (title, l) => { if (l.length) groups.push(`<h5>${esc(title)}</h5>${l.join('')}`); };
  g('Actions', D.actions.filter(a => has(a.title, a.finding, a.id, ...(a.items || []))).slice(0, 7).map(a => `<button data-do="open-action" data-t="${esc(tabOf(a.role))}" data-id="${esc(a.id)}">${chipT(a.role)}<span>${esc(a.title)}</span></button>`));
  g('Tasks', D.tasks.filter(t => has(t.title, t.id)).slice(0, 5).map(t => `<button data-do="go" data-o="steering" data-s="tasks"><span class="chip">${esc(t.id)}</span><span>${esc(t.title)}</span></button>`));
  g('Products', SOL.products.filter(p => has(p.name, p.publisher, p.role)).slice(0, 5).map(p => `<button data-do="go" data-o="solutions" data-s="products" data-a="${esc(p.id)}"><span>${esc(p.name)}</span></button>`));
  g('Decisions', D.decisions.filter(d => has(d.id, d.question)).slice(0, 4).map(d => `<button data-do="go" data-o="steering" data-s="decisions"><span class="chip">${esc(nameOf(d.role))}</span><span>${esc(d.question)}</span></button>`));
  g('Findings', D.findings.filter(c => has(c.title, c.finding, c.id)).slice(0, 5).map(c => `<button data-do="go" data-o="analysis" data-s="findings" data-a="${c.index}">${chipT(c.code)}<span>${esc(c.title)}</span></button>`));
  g('Settings', D.settingGaps.filter(e => has(e.setting)).slice(0, 4).map(e => `<button data-do="go-gap" data-q="${esc(e.setting)}"><span class="chip">${esc(e.workload)}</span><span>${esc(e.setting)}</span></button>`));
  const ids = []; for (const c of SOURCES) { const m = D.identity[c]; if (m) for (const l of m.rows) if (has(l['Display name'], l['Source UPN'], l['Target UPN'])) { ids.push(`<button data-do="go-account" data-t="${esc(c)}" data-q="${esc(l['Source UPN'])}">${chipT(c)}<span>${esc(l['Display name'])} <span class="muted">${esc(l['Source UPN'])}</span></span></button>`); if (ids.length >= 6) break; } }
  g('Accounts', ids);
  z.innerHTML = groups.join('') + '<div id="res-rows"></div>' + (groups.length ? '' : '<p class="empty" id="res-none" style="border:0">Nothing in the plan. Searching the snapshot…</p>');
  z.classList.add('open');
  if (q.length >= 3) searchTimer = setTimeout(() => searchRows(q), 260);
}
/* Last level: every row of the snapshot. */
function searchRows(q) {
  const t = inventory(), res = [];
  for (const r of Object.keys(t)) for (const n of Object.keys(t[r])) {
    const l = t[r][n]; if (!Array.isArray(l)) continue;
    let k = 0; for (const x of l) if (JSON.stringify(x).toLowerCase().includes(q)) k++;
    if (k) res.push([r, n, k]);
  }
  res.sort((a, b) => b[2] - a[2]);
  const z = $('#res-rows'); if (!z) return; const v = $('#res-none');
  if (!res.length) { if (v) v.textContent = 'No result.'; return; }
  if (v) v.remove();
  z.innerHTML = '<h5>Rows of the snapshot</h5>' + res.slice(0, 10).map(([r, n, k]) => `<button data-do="go-table" data-t="${esc(r)}" data-k="${esc(n)}" data-q="${esc(q)}">${chipT(r)}<span>${esc((D.tableLabels[n] || { label: n }).label)} <span class="muted">${plur(k, 'row')}</span></span></button>`).join('');
}
function closeSearch() { $('#results').classList.remove('open'); $('#search').value = ''; }
Object.assign(DO, {
  go(el) { closeSearch(); go(el.dataset.o, el.dataset.s || '', el.dataset.a || ''); },
  'open-action'(el) { closeSearch(); openAction(el.dataset.t, el.dataset.id); }
});
function openAction(c, id) { opened.add(id); const f = filters(c); Object.assign(f, { moment: '', owner: '', severity: '', status: '', workload: '', blocking: false, q: '', assignee: '' }); R.anchor = 'a-' + id; go(c, 'plan'); }

DO.link = () => { if (FILE_API) linkFile(false); else go('steering', 'team'); };
DO['change-file'] = () => linkFile(true);
DO.restore = () => restoreCopy();
DO['forget-copy'] = () => { try { localStorage.removeItem(KEY_COPY); } catch (e) { /* no storage */ } const z = $('#link-state'); if (z) z.outerHTML = linkBlock(); };
DO.who = () => askWho();
DO['i-am'] = el => useName(el.dataset.n);
DO['who-close'] = () => { WHO.next = null; $('#who').close(); };
function useName(name) { const next = WHO.next; WHO.next = null; $('#who').close(); chooseMe(name); const y = scrollY; render(); scrollTo(0, y); toast(`Hello ${name.split(' ')[0]}: your updates will carry your name`); if (next) next(); }

/* ---------- presentation mode ---------- */
const PRESENTATION = [['summary', ''], ['solutions', 'copy'], ['solutions', 'ews'], ...SOURCES.map(r => [r, 'portrait']), ['Target', 'portrait'], ['analysis', 'consolidation'], ['steering', 'decisions']];
let presIndex = -1;
function present(i) {
  presIndex = Math.max(0, Math.min(PRESENTATION.length - 1, i)); document.body.classList.add('pres');
  const b = $('#presentation'); b.hidden = false;
  b.innerHTML = `<button data-do="pres-back" aria-label="Previous view">${ic('chevron', 'p')}</button><span>${presIndex + 1} of ${PRESENTATION.length}</span><button data-do="pres-next" aria-label="Next view">Next</button><button data-do="pres-end" aria-label="Leave the presentation">${ic('close', 'p')}</button>`;
  $('.i', b).style.transform = 'rotate(180deg)';
  go(PRESENTATION[presIndex][0], PRESENTATION[presIndex][1]); window.scrollTo(0, 0);
}
function endPresentation() { presIndex = -1; document.body.classList.remove('pres'); $('#presentation').hidden = true; render(); }
Object.assign(DO, {
  present() { present(0); }, 'pres-back'() { present(presIndex - 1); }, 'pres-next'() { present(presIndex + 1); }, 'pres-end'() { endPresentation(); },
  theme() { const r = document.documentElement, dark = r.dataset.theme ? r.dataset.theme === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches; r.dataset.theme = dark ? 'light' : 'dark'; try { localStorage.setItem('tenantconverge:theme', r.dataset.theme); } catch (e) { /* no storage */ } },
  print() { if (R.sub === 'plan' && T[R.tab]) { filterActions(R.tab).forEach(a => opened.add(a.id)); planList(R.tab); } window.print(); },
  'export-tracking'() { download('team-tracking-copy.csv', stateToCsv(), 'text/csv;charset=utf-8'); toast('Copy of the tracking file downloaded'); },
  'import-tracking'() { $('#file').click(); },
  content() { $('#page').focus(); },
  copy(el) { const t = el.parentElement.firstChild.textContent; navigator.clipboard.writeText(t).then(() => toast('Command copied'), () => toast('Could not copy: select the text')); }
});

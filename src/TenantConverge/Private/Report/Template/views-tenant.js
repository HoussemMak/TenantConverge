/* ---------- one migration, tenant by tenant ---------- */
const SUB_T = { plan: ['Action plan', 'list'], tasks: ['Tasks', 'flag'], portrait: ['Portrait', 'compass'], config: ['Configurations', 'settings'], identities: ['Identities', 'people'], dns: ['Domains and DNS', 'globe'], data: ['Data', 'database'] };
const inRole = (x, c) => x.role === c || (c === 'Target' && x.role === 'All');
function subsOf(c) {
  const l = ['plan'];
  if (tasksOf(c).length) l.push('tasks');
  l.push('portrait');
  if (D.configurations.some(x => inRole(x, c))) l.push('config');
  if (c !== 'Target') { l.push('identities'); const s = D.dns[c]; if (s && !(s.summaryState.state === 'NotUsed' && s.recordState.state === 'NotUsed')) l.push('dns'); }
  l.push('data');
  return l;
}
const F = {};
const filters = c => F[c] || (F[c] = { q: '', moment: '', owner: '', severity: '', status: '', workload: '', blocking: false, assignee: '', cfg: 'essential', cq: '', iq: '', dec: '', tq: '', ts: '' });

function lane(c) {
  const l = actionsOf(c), f = filters(c);
  if (!ACTIVE_MOMENTS.length) return '';
  return `<div class="lane" style="--c:${colorOf(c)};grid-template-columns:repeat(${ACTIVE_MOMENTS.length},minmax(0,1fr))">${ACTIVE_MOMENTS.map(m => { const x = l.filter(a => a.moment === m), d = x.filter(closed).length, b = openBlocking(x); return `<button class="phase ${b ? 'blocked' : ''}" data-do="phase" data-m="${esc(m)}" aria-pressed="${f.moment === m}"><b>${esc(m)}</b><span>${b ? plur(b, 'blocker') : `${d} of ${x.length}`}</span><div class="gauge"><i style="width:${pct(d, x.length)}%"></i></div></button>`; }).join('')}</div>`;
}
DO.phase = el => { const f = filters(R.tab), m = el.dataset.m; f.moment = f.moment === m ? '' : m; if (R.sub !== 'plan') { go(R.tab, 'plan'); return; } render(); };
function collectionBanner(c) {
  const t = T[c];
  if (t.collection === 'Absent') return `<div class="box alert" style="margin-top:12px">${ic('alert', 'p')} <b>This tenant is not in the snapshot.</b> It has not been reached yet. Every number here is a gap, not a zero. Run the assessment for it.</div>`;
  if (t.collection === 'Nothing') return `<div class="box alert" style="margin-top:12px">${ic('alert', 'p')} <b>Nothing was collected for this tenant.</b> Every number here is a gap, not a zero. <a href="#/${esc(c)}/data">See why in the coverage</a>.</div>`;
  if (t.collection === 'Partial') return `<div class="box q" style="margin-top:12px">${ic('info', 'p')} <b>Part of this tenant could not be read:</b> ${nb(t.collected)} of ${nb(t.collectors)} collectors finished clean. <a href="#/${esc(c)}/data">See the coverage</a>.</div>`;
  return '';
}
function tenantPage(p) {
  const c = R.tab, t = T[c], s = subsOf(c), sub = s.includes(R.sub) ? R.sub : 'plan';
  R.sub = sub;
  const l = actionsOf(c), m = D.identity[c];
  const n = { plan: l.length, tasks: tasksOf(c).length, config: D.configurations.filter(x => inRole(x, c) && x.origin !== 'Gap').length, identities: m ? m.rows.length : 0 };
  const fact = (label, u) => { const mm = measureOf(label), v = measureValue(mm, c); return !mm ? '' : `<div><b>${v === null || v === undefined ? gapChip(c, mm.table) : esc(nb(v))}</b><span>${esc(u)}</span></div>`; };
  p.innerHTML = `<div class="tenant-head" style="--c:${colorOf(c)}"><div><h1 class="page-title">${c === 'Target' ? esc(t.name) + ', the target' : esc(t.name) + ' into ' + esc(nameOf('Target'))}</h1><div class="line">${ic('globe', 'p')}<span>${esc((t.domains || []).join(', '))}</span>${t.initialDomain ? `<span class="muted">${esc(t.initialDomain)}</span>` : ''}${t.wave ? `<span class="chip">Wave ${esc(t.wave)}</span>` : ''}</div></div></div>
  ${c === 'Target' ? '<p class="lede">Everything that must be in place in the target before the first cutover, and the consolidation decisions that touch all tenants.</p>' : ''}
  ${collectionBanner(c)}
  <div class="facts">${fact('Active member accounts', 'active accounts')}${fact('User mailboxes', 'mailboxes')}${fact('Mailbox volume (GB)', 'GB of mail')}${fact('OneDrive volume (GB)', 'GB of OneDrive')}${fact('Site volume (GB)', 'GB of sites')}${fact('Teams', 'teams')}${fact('Managed devices', 'managed devices')}</div>
  ${lane(c)}${subnav(s.map(k => [k, SUB_T[k][0], SUB_T[k][1], n[k]]), sub, colorOf(c))}<div id="view"></div>`;
  ({ plan: planView, tasks: tasksView, portrait: portraitView, config: configView, identities: identityView, dns: dnsView, data: dataView })[sub](c, $('#view'));
}

/* portrait: one tenant on its own */
function portraitView(c, v) {
  const x = readinessOf(c), cs = D.findings.filter(k => k.code === c).sort(sortFindings), present = SOL.products.filter(p => p.traces[c]);
  const counts = SEVERITIES.map(s => [s, cs.filter(k => k.severity === s).length]).filter(z => z[1]), unread = (SOL.traceCoverage[c] || { unread: [] }).unread.length;
  v.innerHTML = `<div class="two"><section><h2 class="sec" style="margin-top:4px">Readiness</h2><div class="scores" style="grid-template-columns:auto 1fr;gap:18px;align-items:end">${scoreBlock(c, true)}<div class="counters" style="margin:0">${counts.map(([s, n]) => `<div class="counter"><b>${n}</b><span>${esc(s.toLowerCase())}</span></div>`).join('')}</div></div>${x ? heatMap([c], WORKLOADS) : ''}</section>
  <section><h2 class="sec" style="margin-top:4px">Products found</h2><p class="intro">Found in the technical tables of this tenant. The number counts the rows that cite them.${unread ? ` <b>${plur(unread, 'table')} could not be read</b>, so a product can be missing from this list.` : ''}</p>${present.length ? `<ul class="rows">${present.sort((a, b) => b.traces[c].total - a.traces[c].total).map(p => `<li><a href="#/solutions/products/${esc(p.id)}">${esc(p.name)}</a><div class="sub-line"><span>${plur(p.traces[c].total, 'row')}</span></div></li>`).join('')}</ul>` : `<p class="empty">${unread ? 'No product found in what was read.' : 'No third-party product found.'}</p>`}</section></div>
  <h2 class="sec">Findings</h2>${findingList(cs)}`;
}

/* action plan */
function planView(c, v) {
  const l = actionsOf(c), f = filters(c);
  if (!l.length) { v.innerHTML = '<p class="empty">The plan has no action for this tenant.</p>'; return; }
  const opt = (val, label, cur) => `<option value="${esc(val)}" ${cur === val ? 'selected' : ''}>${esc(label)}</option>`;
  const owners = uniq(l.map(a => a.owner).filter(Boolean)).sort(), workloads = uniq(l.map(a => a.workload).filter(Boolean)).sort(), people = uniq(l.map(assigneeOf).filter(Boolean)).sort();
  v.innerHTML = `<div class="filters">
    <input type="search" data-in="plan-q" placeholder="Filter the actions" aria-label="Filter the actions" value="${esc(f.q)}">
    ${people.length || ME ? `<select data-ch="plan" data-f="assignee" aria-label="Assignee">${opt('', 'All assignees', f.assignee)}${ME ? opt('__me', 'My actions', f.assignee) : ''}${people.map(r => opt(r, r, f.assignee)).join('')}</select>` : ''}
    <select data-ch="plan" data-f="owner" aria-label="Owner">${opt('', 'All owners', f.owner)}${owners.map(r => opt(r, r, f.owner)).join('')}</select>
    <select data-ch="plan" data-f="workload" aria-label="Workload">${opt('', 'All workloads', f.workload)}${workloads.map(r => opt(r, r, f.workload)).join('')}</select>
    <select data-ch="plan" data-f="severity" aria-label="Priority">${opt('', 'All priorities', f.severity)}${SEVERITIES.map(r => opt(r, r, f.severity)).join('')}</select>
    <select data-ch="plan" data-f="status" aria-label="Status">${opt('', 'All statuses', f.status)}${opt('left', 'Left to do', f.status)}${STATUSES.map(r => opt(r[0], r[1], f.status)).join('')}</select>
    <label class="check"><input type="checkbox" data-ch="plan" data-f="blocking" ${f.blocking ? 'checked' : ''}> Blockers only</label>
    <span class="right"><button class="btn" data-do="open-all">${ic('list', 'p')}Expand all</button><button class="btn" data-do="csv-plan">${ic('down', 'p')}Export</button></span>
  </div><div id="list"></div>`;
  planList(c);
}
function filterActions(c) {
  const f = filters(c), q = f.q.toLowerCase(), who = f.assignee === '__me' ? ME : f.assignee;
  return actionsOf(c).filter(a => (!who || assigneeOf(a) === who) && (!f.moment || a.moment === f.moment) && (!f.owner || a.owner === f.owner) && (!f.workload || a.workload === f.workload) && (!f.severity || a.severity === f.severity) && (!f.blocking || a.blocking)
    && (!f.status || (f.status === 'left' ? !closed(a) : statusOf(a.id) === f.status))
    && (!q || [a.title, a.finding, a.action, a.id, a.workload, ...(a.items || [])].join(' ').toLowerCase().includes(q)));
}
function planList(c) {
  const l = filterActions(c), z = $('#list');
  if (!z) return;
  if (!l.length) { z.innerHTML = '<p class="empty">No action matches these filters.</p>'; return; }
  z.innerHTML = MOMENTS.filter(m => l.some(a => a.moment === m)).map(m => {
    const x = l.filter(a => a.moment === m), d = x.filter(closed).length;
    return `<section class="moment"><header style="--c:${colorOf(c)}"><div><h2>${esc(m)}</h2><p>${esc(MOMENT_HELP[m] || '')}</p></div><div class="done-count">${d} of ${x.length} done<div class="gauge" style="--c:var(--ok)"><i style="width:${pct(d, x.length)}%"></i></div></div></header>${x.map(actionRow).join('')}</section>`;
  }).join('');
}
const durationOf = a => { const p = D.procedures[a.procedure]; return (p && p.duration) || a.effort || ''; };
const statusSelect = (id, s, kind) => `<select class="status st-${s}" data-ch="${kind}" data-id="${esc(id)}" aria-label="Status">${STATUSES.map(x => `<option value="${x[0]}" ${x[0] === s ? 'selected' : ''}>${x[1]}</option>`).join('')}</select>`;
function actionRow(a) {
  const s = statusOf(a.id), o = opened.has(a.id), sev = SEVERITY_CLASS[a.severity] || '', who = assigneeOf(a) || a.owner, rem = (a.remediations || []).map(remediation).filter(Boolean);
  return `<article class="action ${o ? 'open' : ''} ${a.blocking ? 'blocking' : ''} ${closed(a) ? 'closed' : ''}" id="a-${esc(a.id)}">
    <div class="head">${statusSelect(a.id, s, 'status')}
      <button class="toggle" data-do="toggle" data-id="${esc(a.id)}" aria-expanded="${o}"><span class="title">${esc(a.title)}</span>
        <span class="meta">${T[R.tab] ? '' : chipT(a.role)}<span>${ic(WORKLOAD_ICON[a.workload] || 'grid', 'p')}${esc(a.workload || 'General')}</span><span title="Owner: ${esc(a.owner)}">${ic('person', 'p')}${esc(who)}</span>${durationOf(a) ? `<span>${ic('clock', 'p')}${esc(durationOf(a))}</span>` : ''}${a.role === 'All' ? `<span>${ic('merge', 'p')}All tenants</span>` : ''}${a.relation ? `<span>${ic('merge', 'p')}${esc(a.relation)}</span>` : ''}</span></button>
      <span class="marks">${rem.some(untested) ? '<span class="chip warn">Untested remediation</span>' : ''}${a.blocking ? `<span class="chip blocking">${ic('alert', 'p')}Blocks the cutover</span>` : ''}<span class="chip ${sev}">${esc(a.severity)}</span></span>
      ${ic('chevron', 'chev')}
    </div>${o ? `<div class="detail">${actionDetail(a)}</div>` : ''}</article>`;
}
const pathLine = t => (t ? `<div class="path">${ic('pin')}${String(t).split(/\s+>\s+/).map(esc).join(ic('chevron'))}</div>` : '');
const cmd = t => `<div class="cmd">${esc(t)}<button data-do="copy" title="Copy the command" aria-label="Copy the command">${ic('copy', 'p')}</button></div>`;
const isCommand = s => /^(Get|Resolve|Test|Invoke|Connect|Search|Select|Measure|Set|New)-[A-Z]/.test(s) || /^\.\\/.test(s);
function verify(x) {
  if (!isCommand(x)) return `<p style="margin-bottom:4px">${esc(x)}</p>`;
  const m = x.match(/^(.*?)\s+:\s+([a-z][^|$]*)$/);
  return m ? `${cmd(m[1])}<p style="margin:3px 0 6px" class="muted">${esc(m[2][0].toUpperCase() + m[2].slice(1))}</p>` : cmd(x);
}
function assigneeField(item, kind) {
  const who = assigneeOf(item), people = uniq([...TEAM, who, ME].filter(Boolean));
  return `<input class="mini" list="people-${esc(item.id)}" data-ch="${kind}" data-id="${esc(item.id)}" value="${esc(who)}" placeholder="To assign" aria-label="Assignee"><datalist id="people-${esc(item.id)}">${people.map(n => `<option value="${esc(n)}"></option>`).join('')}</datalist>`;
}
function noteBlock(item, group) {
  const rec = P[STORE[group]][item.id] || {}, notes = rec.notes || {}, note = (notes[ME] || {}).text || '', others = Object.entries(notes).filter(([n, x]) => n !== ME && x.text);
  return `<div class="block block-note"><h4>${ic('note', 'p')}Tracking note</h4>${others.map(([n, x]) => `<div class="box" style="margin-bottom:6px"><b>${esc(n)}</b>${x.at ? ` <span class="muted small">${esc(when(x.at))}</span>` : ''}<div style="white-space:pre-wrap">${esc(x.text)}</div></div>`).join('')}${ME ? `<textarea class="note" data-in="note" data-g="${group}" data-id="${esc(item.id)}" placeholder="Your note: what, ticket, result" aria-label="Your tracking note">${esc(note)}</textarea>` : `<button class="btn" data-do="who">${ic('person', 'p')}Give my name to write a note</button>`}</div>`;
}
function remediationBlock(a) {
  const l = (a.remediations || []).map(id => [id, remediation(id)]);
  if (!l.length) return '';
  return `<div class="block"><h4>${ic('terminal', 'p')}Remediation</h4>${l.map(([id, x]) => (x ? `<div><a href="#/steering/remediations">${esc(x.title)}</a> <span class="chip">${esc(x.nature)}</span>${untested(x) ? ' <span class="chip warn">Untested</span>' : ''}</div>` : `<div>${esc(id)}</div>`)).join('')}${l.some(([, x]) => x && untested(x)) ? `<p class="muted small" style="margin-top:4px">${esc(UNTESTED)}</p>` : ''}</div>`;
}
function actionDetail(a) {
  const p = D.procedures[a.procedure], rec = P.actions[a.id] || {}, left = [], right = [];
  right.push(`<div class="block"><h4>${ic('person', 'p')}Assignee</h4>${assigneeField(a, 'assignee')}${(rec.t || {}).status && rec.t.status.by ? `<div class="muted small">Status updated by ${esc(rec.t.status.by)}, ${esc(when(rec.t.status.at))}.</div>` : ''}</div>`);
  if (a.finding || a.why) left.push(`<div class="block"><h4>${ic('info', 'p')}What was found</h4>${a.finding ? `<p>${esc(a.finding)}</p>` : ''}${a.why ? `<p style="margin-top:5px"><b>Why it matters.</b> ${esc(a.why)}</p>` : ''}</div>`);
  if (p) {
    if (p.goal && !(a.finding || '').includes(p.goal)) left.push(`<div class="block"><h4>${ic('target', 'p')}Goal</h4><p>${esc(p.goal)}</p></div>`);
    if ((p.prerequisites || []).length) left.push(`<div class="block"><h4>${ic('flag', 'p')}Before you start</h4><ul class="list">${p.prerequisites.map(x => `<li>${esc(x)}</li>`).join('')}</ul></div>`);
    left.push(`<div class="block"><h4>${ic('list', 'p')}Steps</h4><ol class="steps">${(p.steps || []).map(e => `<li>${esc(e.text)}${pathLine(e.where)}${e.command ? cmd(e.command) : ''}</li>`).join('')}</ol></div>`);
  } else if (a.action) left.push(`<div class="block"><h4>${ic('list', 'p')}Planned action</h4><p>${esc(a.action)}</p></div>`);
  if (a.question) right.push(`<div class="block"><h4>${ic('scale', 'p')}Customer decision</h4><div class="box q">${esc(a.question)}<div style="margin-top:6px"><a class="link" href="#/steering/decisions">Record the decision</a></div></div></div>`);
  right.push(remediationBlock(a));
  if (p && (p.configuration || []).length) right.push(`<div class="block"><h4>${ic('settings', 'p')}Configuration to put in place</h4><div class="frame"><table class="t"><thead><tr><th>Setting</th><th>Target value</th></tr></thead><tbody>${p.configuration.map(x => `<tr><td>${esc(x.setting)}${x.where ? pathLine(x.where) : ''}</td><td><b>${esc(x.target)}</b></td></tr>`).join('')}</tbody></table></div></div>`);
  if (p && (p.verification || []).length) right.push(`<div class="block"><h4>${ic('check', 'p')}How to verify</h4>${p.verification.map(verify).join('')}</div>`);
  if (p && (p.risks || []).length) right.push(`<div class="block"><h4>${ic('alert', 'p')}What to watch</h4><ul class="list">${p.risks.map(x => `<li>${esc(x)}</li>`).join('')}</ul></div>`);
  if ((a.items || []).length) right.push(`<div class="block"><h4>${ic('grid', 'p')}Items concerned (${nb(a.itemCount || a.items.length)})</h4>${a.items.length > 10 ? '<input class="mini" type="search" data-in="items" placeholder="Filter" aria-label="Filter the items">' : ''}<div class="items">${a.items.map(x => `<div>${esc(x)}</div>`).join('')}</div>${(a.itemCount || 0) > a.items.length ? `<p class="muted small" style="margin-top:3px">First ${a.items.length} shown. The rest is in the Data tab.</p>` : ''}</div>`);
  if (p && (p.links || []).length) right.push(`<div class="block"><h4>${ic('link', 'p')}Documentation</h4>${p.links.map(l => `<div>${extLink(l.url, l.title)}</div>`).join('')}</div>`);
  right.push(noteBlock(a, 'a'));
  return `<div>${left.join('')}</div><div>${right.join('')}</div>`;
}
const redrawAction = id => { const n = document.getElementById('a-' + id), a = D.actions.find(x => x.id === id); if (n && a) n.outerHTML = actionRow(a); };
Object.assign(DO, {
  toggle(el) { const id = el.dataset.id; opened.has(id) ? opened.delete(id) : opened.add(id); redrawAction(id); const b = document.querySelector(`#a-${CSS.escape(id)} .toggle`); if (b) b.focus({ preventScroll: true }); },
  'open-all'() { const l = filterActions(R.tab), all = l.every(a => opened.has(a.id)); l.forEach(a => all ? opened.delete(a.id) : opened.add(a.id)); planList(R.tab); },
  'csv-plan'() { const c = R.tab; csv(`action-plan-${c}.csv`, ['Moment', 'Action', 'Assignee', 'Priority', 'Blocks the cutover', 'Workload', 'Owner', 'Duration', 'Status', 'Notes', 'Finding'], filterActions(c).map(a => [a.moment, a.title, assigneeOf(a), a.severity, a.blocking ? 'Yes' : '', a.workload, a.owner, durationOf(a), statusLabel(statusOf(a.id)), Object.entries((P.actions[a.id] || {}).notes || {}).map(([n, x]) => `${n}: ${x.text}`).join(' | '), a.finding])); }
});
Object.assign(CHANGE, {
  plan(t) { filters(R.tab)[t.dataset.f] = t.type === 'checkbox' ? t.checked : t.value; planList(R.tab); },
  status(t) {
    const id = t.dataset.id; write(record('a', id), 'status', t.value); redrawAction(id);
    renderTabs(); const v = $('.lane'); if (v && T[R.tab]) v.outerHTML = lane(R.tab);
    const s = $(`[data-ch="status"][data-id="${CSS.escape(id)}"]`); if (s) s.focus({ preventScroll: true });
  },
  assignee(t) { const id = t.dataset.id; write(record('a', id), 'assignee', t.value); opened.add(id); redrawAction(id); toast(t.value ? `Action given to ${t.value}` : 'Action left unassigned'); }
});
Object.assign(INPUT, {
  'plan-q'(t) { filters(R.tab).q = t.value; planList(R.tab); },
  note(t) { const g = t.dataset.g, r = record(g, t.dataset.id); (r.notes = r.notes || box())[ME] = { text: t.value, at: new Date().toISOString() }; P.pending[`${g}|${t.dataset.id}|note|${ME}`] = {}; keep(); },
  items(t) { const q = t.value.toLowerCase(); t.nextElementSibling.querySelectorAll('div').forEach(x => { x.style.display = x.textContent.toLowerCase().includes(q) ? '' : 'none'; }); }
});

/* tasks: a task the plan could not confirm stays here, with its reason */
const confirmChip = t => (t.confirmation === 'Unconfirmed' ? `<span class="chip warn" data-tip="${esc(t.reason || '')}">Unconfirmed</span>` : '');
function taskRow(t) {
  const s = statusOf(t.id), o = opened.has(t.id), p = D.procedures[t.procedure];
  return `<article class="action ${o ? 'open' : ''} ${['done', 'na'].includes(s) ? 'closed' : ''}" id="a-${esc(t.id)}">
    <div class="head">${statusSelect(t.id, s, 'task-status')}
      <button class="toggle" data-do="toggle-task" data-id="${esc(t.id)}" aria-expanded="${o}"><span class="title">${esc(t.title)}</span><span class="meta"><span>${esc(t.id)}</span><span>${esc(t.workstream)}</span><span>${ic('person', 'p')}${esc(assigneeOf(t) || t.owner)}</span>${t.wave ? `<span>Wave ${esc(t.wave)}</span>` : ''}</span></button>
      <span class="marks">${confirmChip(t)}</span>${ic('chevron', 'chev')}
    </div>${t.confirmation === 'Unconfirmed' ? `<p class="task-reason">${ic('info', 'p')} ${esc(t.reason || 'What this task depends on could not be read.')}</p>` : ''}
    ${o ? `<div class="detail"><div>${p ? `<div class="block"><h4>${ic('target', 'p')}Goal</h4><p>${esc(p.goal)}</p></div><div class="block"><h4>${ic('list', 'p')}Steps</h4><ol class="steps">${(p.steps || []).map(e => `<li>${esc(e.text)}${pathLine(e.where)}${e.command ? cmd(e.command) : ''}</li>`).join('')}</ol></div>` : '<p class="muted">This task has no procedure.</p>'}${t.decision ? `<div class="block"><h4>${ic('scale', 'p')}Decision</h4><div class="box q">${esc(t.decision)}</div></div>` : ''}</div><div><div class="block"><h4>${ic('person', 'p')}Assignee</h4>${assigneeField(t, 'task-assignee')}</div>${noteBlock(t, 'k')}</div></div>` : ''}</article>`;
}
const taskList = l => (l.length ? MOMENTS.filter(m => l.some(t => t.moment === m)).map(m => `<section class="moment"><header style="--c:var(--ink)"><div><h2>${esc(m)}</h2></div></header>${l.filter(t => t.moment === m).map(taskRow).join('')}</section>`).join('') : '<p class="empty">No task matches these filters.</p>');
function filterTasks(l, f) { const q = f.tq.toLowerCase(); return l.filter(t => (!f.ts || (f.ts === 'unconfirmed' ? t.confirmation === 'Unconfirmed' : statusOf(t.id) === f.ts)) && (!q || [t.title, t.id, t.workstream].join(' ').toLowerCase().includes(q))); }
const taskFilters = (f, ch) => `<div class="filters"><input type="search" data-in="${ch}-q" placeholder="Filter the tasks" aria-label="Filter the tasks" value="${esc(f.tq)}"><select data-ch="${ch}" aria-label="Status"><option value="">All tasks</option><option value="unconfirmed" ${f.ts === 'unconfirmed' ? 'selected' : ''}>Unconfirmed</option>${STATUSES.map(s => `<option value="${s[0]}" ${f.ts === s[0] ? 'selected' : ''}>${s[1]}</option>`).join('')}</select><span class="right"><button class="btn" data-do="csv-tasks">${ic('down', 'p')}Export</button></span></div>`;
const unconfirmedNote = l => { const n = l.filter(t => t.confirmation === 'Unconfirmed').length; return n ? `<div class="box q" style="margin-bottom:10px">${ic('info', 'p')} <b>${plur(n, 'task', 'tasks')} could not be confirmed.</b> What ${n === 1 ? 'it depends on' : 'they depend on'} was not read, so the plan keeps ${n === 1 ? 'it' : 'them'} until someone checks.</div>` : ''; };
function tasksView(c, v) { const f = filters(c), l = tasksOf(c); v.innerHTML = `${unconfirmedNote(l)}${taskFilters(f, 'tenant-tasks')}<div id="task-list"></div>`; $('#task-list').innerHTML = taskList(filterTasks(l, f)); }
const redrawTask = id => { const n = document.getElementById('a-' + id), t = D.tasks.find(x => x.id === id); if (n && t) n.outerHTML = taskRow(t); };
Object.assign(DO, {
  'toggle-task'(el) { const id = el.dataset.id; opened.has(id) ? opened.delete(id) : opened.add(id); redrawTask(id); },
  'csv-tasks'() { const l = T[R.tab] ? tasksOf(R.tab) : D.tasks; csv('tasks.csv', ['Task', 'Title', 'Workstream', 'Moment', 'Owner', 'Assignee', 'Status', 'Confirmation', 'Reason', 'Decision'], l.map(t => [t.id, t.title, t.workstream, t.moment, t.owner, assigneeOf(t), statusLabel(statusOf(t.id)), t.confirmation, t.reason, t.decision])); }
});
Object.assign(CHANGE, {
  'task-status'(t) { write(record('k', t.dataset.id), 'status', t.value); redrawTask(t.dataset.id); },
  'task-assignee'(t) { write(record('k', t.dataset.id), 'assignee', t.value); redrawTask(t.dataset.id); },
  'tenant-tasks'(t) { const f = filters(R.tab); f.ts = t.value; $('#task-list').innerHTML = taskList(filterTasks(tasksOf(R.tab), f)); }
});
INPUT['tenant-tasks-q'] = t => { const f = filters(R.tab); f.tq = t.value; $('#task-list').innerHTML = taskList(filterTasks(tasksOf(R.tab), f)); };

/* configurations */
const configKey = x => x.role + '|' + x.setting;
const isGapLine = x => /gap$/i.test(x.origin);
function configView(c, v) {
  const f = filters(c);
  v.innerHTML = `<p class="intro">The settings to put in place for this migration. Tick each line once the setting is applied and verified.</p>
  <div class="filters"><input type="search" data-in="cfg-q" placeholder="Filter the settings" aria-label="Filter the settings" value="${esc(f.cq)}">
   <select data-ch="cfg" aria-label="Lines shown"><option value="essential" ${f.cfg === 'essential' ? 'selected' : ''}>To put in place</option><option value="all" ${f.cfg === 'all' ? 'selected' : ''}>With all the gaps</option><option value="left" ${f.cfg === 'left' ? 'selected' : ''}>Not applied yet</option></select>
   <span class="right"><button class="btn" data-do="csv-config">${ic('down', 'p')}Export</button></span></div><div id="cfg"></div>`;
  configList(c);
}
function configLines(c) {
  const f = filters(c), q = f.cq.toLowerCase();
  return D.configurations.filter(x => inRole(x, c) && (f.cfg === 'all' || x.origin !== 'Gap') && (f.cfg !== 'left' || !applied(configKey(x))) && (!q || [x.setting, x.target, x.current, x.where, x.group].join(' ').toLowerCase().includes(q)));
}
function configList(c) {
  const l = configLines(c), g = uniq(l.map(x => x.group)).sort((a, b) => a.localeCompare(b, 'en'));
  $('#cfg').innerHTML = l.length ? g.map(n => { const lg = l.filter(x => x.group === n), withCurrent = lg.some(x => x.current); return `<h3 class="ssec">${ic(WORKLOAD_ICON[n] || 'grid', 'p')} ${esc(n)}</h3><div class="frame"><table class="t"><thead><tr><th style="width:44px">Done</th><th>Setting</th>${withCurrent ? '<th>Current</th>' : ''}<th>Target</th>${lg.some(x => x.where) ? '<th>Where</th>' : ''}</tr></thead><tbody>${lg.map(x => {
    const gap = isGapLine(x);
    return `<tr><td><input type="checkbox" data-ch="applied" data-k="${esc(configKey(x))}" ${applied(configKey(x)) ? 'checked' : ''} aria-label="Setting applied"></td><td>${esc(x.setting)}${gap ? ` <span class="chip ${x.origin === 'Important gap' ? 'warn' : ''}">${esc(x.origin)}</span>` : ''}${x.action && D.actions.some(a => a.id === x.action) ? `<div><button class="link small" data-do="open-action" data-t="${esc(c)}" data-id="${esc(x.action)}">See the action</button></div>` : ''}</td>${withCurrent ? `<td>${esc(x.current)}</td>` : ''}<td><b>${esc(x.target)}</b>${gap ? '<div class="muted small">value of the target, to confirm</div>' : ''}</td>${lg.some(y => y.where) ? `<td>${esc(x.where)}</td>` : ''}</tr>`;
  }).join('')}</tbody></table></div>`; }).join('') : '<p class="empty">No setting to show.</p>';
}
Object.assign(CHANGE, { cfg(t) { filters(R.tab).cfg = t.value; configList(R.tab); }, applied(t) { P.config[t.dataset.k] = { val: t.checked ? 1 : 0, label: labelOf('c', t.dataset.k), ...stamp() }; P.pending['c|' + t.dataset.k] = {}; keep(); } });
INPUT['cfg-q'] = t => { filters(R.tab).cq = t.value; configList(R.tab); };
DO['csv-config'] = () => { const c = R.tab; csv(`configurations-${c}.csv`, ['Workload', 'Setting', 'Current', 'Target', 'Where', 'Origin', 'Applied'], configLines(c).map(x => [x.group, x.setting, x.current, x.target, x.where, x.origin, applied(configKey(x)) ? 'Yes' : ''])); };

/* identities */
const DECISION_CLASS = { Create: 'ok', Duplicate: 'info', 'To review': 'warn' };
function identityView(c, v) {
  const m = D.identity[c], f = filters(c);
  if (!m || !m.drafted) { v.innerHTML = `<div class="box alert">${ic('alert', 'p')} <b>No draft for this source.</b> ${esc(m ? m.reason : '')}${m && m.remedy ? `<div style="margin-top:5px">${esc(m.remedy)}</div>` : ''}</div>`; return; }
  if (!m.rows.length) { v.innerHTML = '<p class="empty">This source has no member account.</p>'; return; }
  const n = m.counts, k = (val, label, count) => `<button class="counter" data-do="decision-filter" data-v="${esc(val)}" aria-pressed="${f.dec === val}"><b>${nb(count)}</b><span>${esc(label)}</span></button>`;
  const hasNotes = m.rows.some(x => x.Notes);
  v.innerHTML = `<div class="box q" style="margin-bottom:12px">${ic('info', 'p')} <b>Draft for the customer to validate.</b> Nothing here is a decision yet.</div>
  <div class="counters">${k('', 'All accounts', m.rows.length)}${k('Create', `To create in ${nameOf('Target')}`, n.Create)}${k('Duplicate', `Already in ${nameOf('Target')}`, n.Duplicate)}${k('To review', 'To review', n['To review'])}${n.Bookings ? k('Bookings', 'Bookings pages', n.Bookings) : ''}</div>
  <div class="filters"><input type="search" data-in="id-q" placeholder="Filter by name or address" aria-label="Filter the accounts" value="${esc(f.iq)}"><span class="right"><button class="btn" data-do="csv-identity">${ic('down', 'p')}Export</button></span></div><div id="identity"></div>`;
  identityList(c, hasNotes);
}
function identityLines(c) { const f = filters(c), q = f.iq.toLowerCase(); return D.identity[c].rows.filter(l => (!f.dec || (f.dec === 'Bookings' ? /Bookings/.test(l.Notes) : l.Decision === f.dec)) && (!q || [l['Display name'], l['Source UPN'], l['Target UPN'], l.Notes].join(' ').toLowerCase().includes(q))); }
function identityList(c, hasNotes) {
  const l = identityLines(c);
  $('#identity').innerHTML = l.length ? `<div class="frame" style="max-height:65vh"><table class="t"><thead><tr><th>Name</th><th>Source account</th><th>Decision</th><th>Target account</th><th>Type</th>${hasNotes ? '<th>Notes</th>' : ''}</tr></thead><tbody>${l.slice(0, 500).map(x => `<tr><td>${esc(x['Display name'])}</td><td>${esc(x['Source UPN'])}</td><td><span class="chip ${DECISION_CLASS[x.Decision] || ''}">${esc(x.Decision)}</span></td><td>${esc(x['Target UPN'])}</td><td>${esc(x.Type)}</td>${hasNotes ? `<td>${esc(x.Notes)}</td>` : ''}</tr>`).join('')}</tbody></table></div>${l.length > 500 ? `<p class="muted small" style="margin-top:6px">First 500 rows of ${nb(l.length)}: use the filter or the export.</p>` : ''}` : '<p class="empty">No account for this filter.</p>';
}
DO['decision-filter'] = el => { filters(R.tab).dec = el.dataset.v; identityView(R.tab, $('#view')); };
INPUT['id-q'] = t => { filters(R.tab).iq = t.value; identityList(R.tab, D.identity[R.tab].rows.some(x => x.Notes)); };
DO['csv-identity'] = () => { const c = R.tab; csv(`identities-${c}.csv`, ['Name', 'Source account', 'Decision', 'Target account', 'Temporary account', 'Type', 'License', 'Notes'], identityLines(c).map(l => [l['Display name'], l['Source UPN'], l.Decision, l['Target UPN'], l['Temporary UPN'], l.Type, l.License, l.Notes])); };
DO['go-account'] = el => { closeSearch(); const f = filters(el.dataset.t); f.iq = el.dataset.q; f.dec = ''; go(el.dataset.t, 'identities'); };

/* domains and DNS */
function dnsView(c, v) {
  const d = D.dns[c], s = d.summaryState, r = d.recordState;
  const gap = isGap(s) && isGap(r);
  if (gap) { v.innerHTML = `<div class="box alert">${ic('alert', 'p')} <b>The DNS of this tenant could not be read (${esc(s.status)}).</b> ${esc(s.message)}${s.remedy ? `<div style="margin-top:5px">${esc(s.remedy)}</div>` : ''}</div>`; return; }
  const keys = d.summary.length ? Object.keys(d.summary[0]).filter(k => !['Domain', 'DNS host'].includes(k) && d.summary.some(x => x[k] !== null && x[k] !== undefined && x[k] !== '')) : [];
  const chip = v2 => (/^unknown$/i.test(String(v2)) ? '<span class="chip warn" data-tip="The query failed: this is not an empty answer.">Unknown</span>' : /^(missing|none)$/i.test(String(v2)) ? `<span class="chip warn">${esc(v2)}</span>` : esc(cellText(v2)));
  const domains = uniq([...d.summary.map(x => x.Domain), ...d.records.map(x => x.Domain)]);
  v.innerHTML = `${isGap(s) || isGap(r) ? `<div class="box q" style="margin-bottom:10px">${ic('info', 'p')} Part of the DNS could not be read: ${esc(isGap(s) ? (D.tableLabels.dnsSummary || {}).label : (D.tableLabels.publicDns || {}).label)} (${esc(isGap(s) ? s.status : r.status)}).</div>` : ''}
  ${d.summary.length ? `<h2 class="sec" style="margin-top:6px">Each domain</h2><div class="frame"><table class="t"><thead><tr><th>Domain</th><th>DNS host</th>${keys.map(k => `<th>${esc(k)}</th>`).join('')}</tr></thead><tbody>${d.summary.map(x => `<tr><td><b>${esc(x.Domain)}</b></td><td>${chip(x['DNS host'])}</td>${keys.map(k => `<td>${chip(x[k])}</td>`).join('')}</tr>`).join('')}</tbody></table></div>` : ''}
  ${domains.filter(n => d.records.some(x => x.Domain === n)).map(n => `<h3 class="ssec">${ic('globe')} ${esc(n)}</h3><div class="frame"><table class="t"><thead><tr><th>Record</th><th>Type</th><th>Current value</th><th class="num">TTL (s)</th><th>State</th></tr></thead><tbody>${d.records.filter(x => x.Domain === n).map(x => { const none = !x.Value, unknown = /^unknown$/i.test(String(x.Value)), long = Number(x.TTL) > 300; return `<tr><td>${esc(x.Record)}</td><td>${esc(x.Type)}</td><td>${none ? '<span class="muted">none</span>' : chip(x.Value)}</td><td class="num">${esc(x.TTL ?? '')}</td><td>${unknown ? '<span class="chip warn">Not known</span>' : none ? '<span class="chip warn">To create</span>' : long ? '<span class="chip warn">Lower to 300 s</span>' : '<span class="chip ok">Ready</span>'}</td></tr>`; }).join('')}</tbody></table></div>`).join('')}`;
}

/* the data of the snapshot */
const TV = {};
function dataView(c, v) {
  v.innerHTML = '<p class="empty">Reading the snapshot…</p>';
  setTimeout(() => {
    if (!v.isConnected || R.tab !== c || R.sub !== 'data') return;
    const t = inventory()[c] || {}, states = D.tableStates[c] || {};
    const tv = TV[c] || (TV[c] = { table: '__coverage', q: '', sort: '', dir: 1, page: 0 }), groups = {};
    if (R.arg && states[R.arg]) { tv.table = R.arg; tv.page = 0; }
    for (const k of Object.keys(states)) { const label = D.tableLabels[k] || { label: k, workload: 'Other' }, s = states[k]; if (s.state === 'NotUsed' || (s.state !== 'Collected' && !isGap(s))) continue; (groups[label.workload] = groups[label.workload] || []).push([k, label.label, s]); }
    const cv = D.coverage.filter(x => x.role === c), ok = cv.filter(x => x.status === 'OK').length, unused = Object.values(states).filter(s => s.state === 'NotUsed').length;
    const mark = s => (s.state === 'Collected' ? nb(s.rows) : s.state === 'NotFullyRead' ? 'not fully read' : 'not collected');
    v.innerHTML = `<div class="data-view"><div class="tables" role="group" aria-label="Tables of the snapshot"><button data-do="table" data-k="__coverage" aria-pressed="${tv.table === '__coverage'}"><span>Collection coverage</span><span class="n">${ok}/${cv.length}</span></button>${Object.keys(groups).sort((a, b) => a.localeCompare(b, 'en')).map(g => `<h4>${esc(g)}</h4>${groups[g].map(x => `<button data-do="table" data-k="${esc(x[0])}" aria-pressed="${tv.table === x[0]}"><span>${esc(x[1])}</span><span class="n ${isGap(x[2]) ? 'gap-text' : ''}">${esc(mark(x[2]))}</span></button>`).join('')}`).join('')}${unused ? `<p class="muted small" style="margin:8px 7px 3px">${plur(unused, 'table')} read and empty: not used in this tenant.</p>` : ''}</div><div id="table" style="min-width:0"></div></div>`;
    showTable(c);
  }, 20);
}
function tableRows(c) {
  const tv = TV[c];
  if (tv.table === '__coverage') return D.coverage.filter(x => x.role === c).map(x => ({ Collector: x.id, Subject: x.title, Workload: x.workload, Status: x.status, Message: x.message, 'What to do': x.remedy }));
  return (inventory()[c] || {})[tv.table] || [];
}
const cellText = v => (v === true ? 'Yes' : v === false ? 'No' : (v !== null && typeof v === 'object') ? JSON.stringify(v) : (v ?? ''));
function showTable(c) {
  const tv = TV[c], all = tableRows(c), q = tv.q.toLowerCase(), cols = uniq(all.slice(0, 80).flatMap(l => Object.keys(l))), st = stateOf(c, tv.table);
  let l = q ? all.filter(x => cols.some(k => String(cellText(x[k])).toLowerCase().includes(q))) : all.slice();
  if (tv.sort) l.sort((a, b) => { const x = cellText(a[tv.sort]), y = cellText(b[tv.sort]); return tv.dir * (typeof x === 'number' && typeof y === 'number' ? x - y : String(x).localeCompare(String(y), 'en', { numeric: true })); });
  const size = 50, pages = Math.max(1, Math.ceil(l.length / size)); tv.page = Math.min(tv.page, pages - 1);
  const name = tv.table === '__coverage' ? 'Collection coverage' : (D.tableLabels[tv.table] || { label: tv.table }).label;
  const blank = tv.table !== '__coverage' && isGap(st) ? `<div class="box alert">${ic('alert', 'p')} <b>${esc(GAP_LABEL[st.state])} (${esc(st.status)}).</b> ${esc(st.message)}${st.remedy ? `<div style="margin-top:5px">${esc(st.remedy)}</div>` : ''}<div class="muted small" style="margin-top:5px">This table says nothing about the tenant: its rows may exist.</div></div>` : '<p class="empty">Empty table: nothing of this kind in this tenant.</p>';
  $('#table').innerHTML = `<div class="filters" style="margin-top:0"><h3 class="ssec" style="margin:0 8px 0 0">${esc(name)}</h3><input type="search" data-in="table-q" placeholder="Filter this table" aria-label="Filter this table" value="${esc(tv.q)}"><span class="right"><button class="btn" data-do="csv-table">${ic('down', 'p')}Export</button></span></div>
  ${l.length ? `<div class="frame" style="max-height:66vh"><table class="t"><thead><tr>${cols.map(k => `<th><button data-do="sort" data-k="${esc(k)}">${esc(k)}${tv.sort === k ? (tv.dir > 0 ? ' ↑' : ' ↓') : ''}</button></th>`).join('')}</tr></thead><tbody>${l.slice(tv.page * size, (tv.page + 1) * size).map(x => `<tr>${cols.map(k => { const v = cellText(x[k]); return `<td class="${typeof v === 'number' ? 'num' : ''}">${esc(v)}</td>`; }).join('')}</tr>`).join('')}</tbody></table></div>
  <div class="pages"><button class="btn" data-do="page" data-d="-1" ${tv.page ? '' : 'disabled'}>Previous</button><span>Page ${tv.page + 1} of ${pages}, ${plur(l.length, 'row')}</span><button class="btn" data-do="page" data-d="1" ${tv.page < pages - 1 ? '' : 'disabled'}>Next</button></div>` : blank}`;
}
Object.assign(DO, {
  table(el) { const tv = TV[R.tab]; Object.assign(tv, { table: el.dataset.k, q: '', sort: '', page: 0 }); document.querySelectorAll('.tables button').forEach(b => b.setAttribute('aria-pressed', b === el)); showTable(R.tab); },
  sort(el) { const tv = TV[R.tab], k = el.dataset.k; if (tv.sort === k) tv.dir = -tv.dir; else { tv.sort = k; tv.dir = 1; } showTable(R.tab); },
  page(el) { TV[R.tab].page += +el.dataset.d; showTable(R.tab); },
  'csv-table'() { const c = R.tab, l = tableRows(c), cols = uniq(l.slice(0, 80).flatMap(x => Object.keys(x))); csv(`data-${c}-${TV[c].table.replace('__', '')}.csv`, cols, l.map(x => cols.map(k => cellText(x[k])))); },
  'go-table'(el) { closeSearch(); const c = el.dataset.t; TV[c] = { table: el.dataset.k, q: el.dataset.q, sort: '', dir: 1, page: 0 }; go(c, 'data'); }
});
INPUT['table-q'] = t => { const v = t.value, tv = TV[R.tab]; tv.q = v; tv.page = 0; showTable(R.tab); const n = $('[data-in="table-q"]'); n.focus(); n.setSelectionRange(v.length, v.length); };

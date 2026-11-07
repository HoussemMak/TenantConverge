/* ---------- summary: the consolidation ledger ---------- */
const LEDGER_LINES = [
  ['Active member accounts', 'accounts'], ['User mailboxes', 'mailboxes'], ['Shared mailboxes', 'shared mailboxes'], ['Mailbox volume (GB)', 'GB of mail'],
  ['OneDrive accounts', 'OneDrive accounts'], ['OneDrive volume (GB)', 'GB of OneDrive'], ['Sites', 'sites'], ['Site volume (GB)', 'GB of sites'],
  ['Teams', 'teams'], ['Managed devices', 'managed devices'], ['Phone numbers', 'numbers']
];
let chosenLine = 'Active member accounts';
const numberOf = (label, r) => { const v = measureValue(measureOf(label), r); return typeof v === 'number' ? v : 0; };
const titleWord = n => ['No tenant', 'One tenant', 'Two tenants', 'Three tenants'][n] || `${n} tenants`;

function flowChart(label) {
  const m = measureOf(label), narrow = innerWidth < 700, W = narrow ? 400 : 560, H = narrow ? 300 : 376, margin = 16, xL = narrow ? 104 : 136, xR = narrow ? 280 : 414, wide = narrow ? 24 : 30, unit = (LEDGER_LINES.find(l => l[0] === label) || [])[1] || '';
  const order = ['Target', ...SOURCES], value = r => numberOf(label, r), read = r => { const v = measureValue(m, r); return v !== null && v !== undefined; };
  const text = r => (read(r) ? nb(value(r)) : 'not read');
  const short = (r, max = 16) => { const n = nameOf(r); return n.length > max ? n.slice(0, max - 1) + '…' : n; };
  const total = order.reduce((s, c) => s + value(c), 0) || 1, srcTotal = SOURCES.reduce((s, c) => s + value(c), 0);
  const roomR = H - 2 * margin - 3 * SOURCES.length, k = roomR / total;
  const roomL = H - 2 * margin - 40, kL = Math.min(k * 1.6, roomL / (srcTotal || 1));   /* the sources read better a little wider */
  let yR = margin, o = '';
  /* right column: the target first, then what arrives */
  const seg = {}; order.forEach(c => { const h = value(c) * k; seg[c] = { y: yR, h }; yR += h + (h > 0 ? 3 : 0); });
  const step = (H - 2 * margin) / SOURCES.length;
  SOURCES.forEach((c, i) => {
    const hL = Math.max(value(c) * kL, value(c) ? 3 : 1), yL = margin + step * i + (step - hL) / 2, s = seg[c], hR = Math.max(s.h, value(c) ? 1.5 : 0), mid = (xL + xR) / 2;
    const d = `M${xL},${yL} C${mid},${yL} ${mid},${s.y} ${xR},${s.y} L${xR},${s.y + hR} C${mid},${s.y + hR} ${mid},${yL + hL} ${xL},${yL + hL} Z`;
    o += `<a href="#/${esc(c)}" aria-label="${esc(nameOf(c))}: ${esc(text(c))} ${esc(unit)}"><path class="stream" d="${d}" fill="${colorOf(c)}" data-tip="${esc(nameOf(c))} into ${esc(nameOf('Target'))}: ${esc(text(c))} ${esc(unit)}"/>
      <rect x="${xL - 5}" y="${yL}" width="5" height="${hL}" rx="1.5" fill="${colorOf(c)}"/><text x="${xL - 12}" y="${yL + hL / 2 - 2}" text-anchor="end" font-size="15" font-weight="600">${esc(short(c))}</text><text class="t2" x="${xL - 12}" y="${yL + hL / 2 + 15}" text-anchor="end" font-size="14">${esc(text(c))}</text></a>`;
  });
  order.forEach(c => { const s = seg[c]; if (s.h > 0) o += `<rect x="${xR}" y="${s.y}" width="${wide}" height="${Math.max(s.h, 1.5)}" rx="2" fill="${colorOf(c)}" data-tip="${esc(nameOf(c))}: ${esc(nb(value(c)))} ${esc(unit)} (${pct(value(c), total)} %)"/>`; });
  const after = consolidated(m), afterText = after ? `${after.minimum ? 'at least ' : ''}${nb(after.value)}` : 'not read';
  o += `<text x="${xR + wide + 9}" y="${margin + 15}" font-size="15" font-weight="600">${esc(short('Target', narrow ? 10 : 13))}</text><text class="t2" x="${xR + wide + 9}" y="${margin + 33}" font-size="14">after</text><text x="${xR + wide + 9}" y="${margin + 56}" font-size="19" font-weight="700">${esc(afterText)}</text>`;
  return `<svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(label)}: ${esc(order.map(c => `${nameOf(c)} ${text(c)}`).join(', '))}">${o}</svg>`;
}
function ledgerSheet() {
  const rows = LEDGER_LINES.map(([label]) => {
    const m = measureOf(label), on = label === chosenLine;
    if (!m) return '';
    const c = consolidated(m), after = c && c.targetUnread ? `<span class="minimum" data-tip="${esc('At least: the target was not read')}">at least ${esc(nb(c.value))}</span>` : totalCell(c ? c.value : null, m);
    return `<tr class="${on ? 'chosen' : ''}"><td><button data-do="line" data-l="${esc(label)}" aria-pressed="${on}">${esc(label.replace(' (GB)', ''))}${label.includes('(GB)') ? ' <span class="muted">GB</span>' : ''}</button></td>${SOURCES.map(c => `<td>${measureCell(m, c)}</td>`).join('')}${SOURCES.length > 1 ? `<td class="subtotal">${totalCell(m.sources, m)}</td>` : ''}<td>${measureCell(m, 'Target')}</td><td class="total">${after}</td></tr>`;
  }).join('');
  const head = c => `<th class="ledger-name" title="${esc(nameOf(c))}"><i style="--c:${colorOf(c)}"></i>${esc(nameOf(c))}</th>`;
  return `<div style="overflow:auto"><table class="sheet"><caption class="muted small" style="caption-side:bottom;text-align:left;padding:7px 14px 9px">Choose a line to redraw the flows. Consolidated = sources + target, before cleanup. "At least" means a tenant could not be read.</caption><thead><tr><th scope="col">Consolidation ledger</th>${SOURCES.map(head).join('')}${SOURCES.length > 1 ? '<th>Sources</th>' : ''}${head('Target')}<th>Consolidated</th></tr></thead><tbody>${rows}</tbody></table></div>`;
}
function drawLedger() { $('#flow-svg').innerHTML = flowChart(chosenLine); $('#flow-title').textContent = chosenLine.replace(' (GB)', ', in GB'); $('#sheet').innerHTML = ledgerSheet(); }
DO.line = el => { chosenLine = el.dataset.l; drawLedger(); const b = $(`[data-l="${CSS.escape(chosenLine)}"]`); if (b) b.focus({ preventScroll: true }); };

function progressGrid() {
  if (!ACTIVE_MOMENTS.length) return '<p class="empty">The plan has no action yet.</p>';
  const head = `<div class="head">Migration</div>${ACTIVE_MOMENTS.map(m => `<div class="head">${esc(m)}</div>`).join('')}<div class="head">Blockers</div>`;
  const rows = [...SOURCES, 'Target'].map(c => {
    const l = actionsOf(c), n = openBlocking(l);
    return `<a class="tenant" href="#/${esc(c)}/plan" style="--c:${colorOf(c)}"><i></i><span class="tab-name">${esc(nameOf(c))}</span></a>${ACTIVE_MOMENTS.map(m => { const x = l.filter(a => a.moment === m), d = x.filter(closed).length; return x.length ? `<button class="cell" data-do="moment" data-t="${esc(c)}" data-m="${esc(m)}" aria-label="${esc(nameOf(c))}, ${esc(m)}: ${d} of ${x.length}"><b>${d}</b> <span class="muted">of ${x.length}</span><div class="gauge"><i style="width:${pct(d, x.length)}%"></i></div></button>` : '<div class="muted">0</div>'; }).join('')}<div class="last">${n ? `<span class="chip blocking">${ic('alert', 'p')}${n}</span>` : `<span class="chip ok">${ic('check', 'p')}0</span>`}</div>`;
  }).join('');
  return `<div class="progress" style="grid-template-columns:minmax(150px,1.2fr) repeat(${ACTIVE_MOMENTS.length},minmax(82px,1fr)) minmax(92px,auto)">${head}${rows}</div>`;
}
const NOT_HERE = { State: 'Not in this tenant' };
function heatCell(role, w) {
  const e = readLine(role, w) || { State: 'Not collected', Open: 0, Findings: 0, Coverage: 'None', Unread: [], RulesStopped: 0, Applicable: true };
  const absent = e.Applicable === false, state = absent ? NOT_HERE.State : e.State, key = absent ? 'x' : STATE_KEY[e.State];
  const cs = D.findings.filter(c => c.code === role && c.workload === w), det = SEVERITIES.slice(0, 4).map(s => { const n = cs.filter(c => c.severity === s).length; return n ? `${n} ${s.toLowerCase()}` : ''; }).filter(Boolean).join(', ');
  const partly = e.Coverage === 'Partial' || (e.Unread || []).length || e.RulesStopped;
  const tip = `${nameOf(role)}, ${w}: ${state.toLowerCase()}${det ? ` (${det})` : ''}${e.Coverage === 'Partial' ? '. Partly collected.' : ''}${(e.Unread || []).length ? `. Not read: ${e.Unread.join(', ')}.` : ''}${e.RulesStopped ? `. ${plur(e.RulesStopped, 'rule')} stopped.` : ''}`;
  return `<button class="c e-${key}${partly ? ' partly' : ''}" data-do="workload" data-v="${esc(slug(w))}" data-tip="${esc(tip)}"><b>${e.Open || (key === 'n' ? '?' : key === 'x' ? '–' : '0')}${partly ? '*' : ''}</b><span>${esc(state)}</span></button>`;
}
function heatMap(roles, workloads) {
  let h = `<div class="heat" style="grid-template-columns:minmax(150px,1.2fr) repeat(${roles.length},minmax(92px,1fr))"><div></div>${roles.map(c => `<div class="e">${chipT(c)}</div>`).join('')}`;
  workloads.forEach(v => { h += `<a class="v" href="#/analysis/workloads/${esc(slug(v))}">${esc(v)}</a>${roles.map(r => heatCell(r, v)).join('')}`; });
  return `${h}</div><div class="state-legend">${STATE_PRIORITY.map(s => `<span><i class="e-${STATE_KEY[s]}"></i>${esc(s)}</span>`).join('')}<span><i class="e-x"></i>Not in this tenant</span><span class="muted">The number counts the findings of the workload that are not Info. A * means part of it could not be read.</span></div>`;
}
DO.workload = el => go('analysis', 'workloads', el.dataset.v);
DO.moment = el => { const f = filters(el.dataset.t); Object.assign(f, { moment: el.dataset.m, owner: '', severity: '', status: '', workload: '', blocking: false, q: '' }); go(el.dataset.t, 'plan'); };

/* Score counts what was not read as lost. CollectedScore shows the part that was read. */
function scoreBlock(role, wide) {
  const x = readinessOf(role);
  if (!x) return `<div class="x" style="--c:${colorOf(role)}"><b>–</b> <span>no score</span><div>${esc(nameOf(role))}</div><div class="muted small">This tenant is not in the snapshot.</div></div>`;
  const none = nothingRead(x), gap = x.CollectedScore - x.Score;
  const note = none ? 'Nothing was read: there is nothing to score.' : gap > 0 ? `${gap} points lost to what could not be read.` : 'Everything scored was read.';
  return `<div class="x" style="--c:${colorOf(role)}"><b>${x.Score}</b> <span>of 100</span>${wide ? '' : `<div class="tab-name">${esc(nameOf(role))}</div>`}<div class="muted small">Score of what was read: ${none ? 'none' : x.CollectedScore}</div><div class="muted small">${esc(note)}</div></div>`;
}
const gapBanner = () => {
  const l = D.tenants.filter(t => ['Nothing', 'Absent'].includes(t.collection));
  return l.length ? `<div class="box alert" style="margin:0 0 12px">${ic('alert', 'p')} <b>${esc(l.map(t => t.name).join(', '))}:</b> nothing was collected. Numbers for ${l.length > 1 ? 'these tenants' : 'this tenant'} are gaps, not zeros.</div>` : '';
};

VIEWS.summary = p => {
  const mail = measureOf('Mailbox volume (GB)'), sites = measureOf('Site volume (GB)'), od = measureOf('OneDrive volume (GB)'), accounts = measureOf('Active member accounts');
  const minimum = l => l.some(m => m && missingSources(m).length), some = m => (m && typeof m.sources === 'number' ? m.sources : 0);
  const blocking = D.actions.filter(a => a.blocking && !closed(a)).sort((a, b) => SEVERITIES.indexOf(a.severity) - SEVERITIES.indexOf(b.severity));
  const toDecide = D.decisions.filter(d => (P.decisions[d.id] || {}).status !== 'decided'), start = D.actions.filter(a => a.moment === 'Now' && !a.blocking && !closed(a) && a.severity === 'High');
  const lineA = a => `<li><a href="#/${esc(tabOf(a.role))}/plan" data-do="open-action" data-t="${esc(tabOf(a.role))}" data-id="${esc(a.id)}">${esc(a.title)}</a><div class="sub-line">${chipT(a.role)}<span>${esc(a.workload || 'General')}</span><span>${esc(a.owner)}</span></div></li>`;
  p.innerHTML = `<section class="opening"><h1>${esc(titleWord(SOURCES.length))} to bring into ${esc(nameOf('Target'))}</h1>
    <p>${minimum([accounts, mail, sites, od]) ? 'At least ' : ''}${nb(some(accounts))} active accounts, ${nb(Math.round(some(mail)))} GB of mail and ${nb(Math.round(some(sites) + some(od)))} GB of documents to move. This report brings together the assessment of ${plur(ROLES.length, 'tenant')}, the action plan of each migration and the solutions to use.</p></section>
  ${gapBanner()}
  <section class="ledger" aria-label="Consolidation ledger"><div class="flow"><h2 id="flow-title"></h2><div id="flow-svg"></div></div><div id="sheet"></div></section>
  <h2 class="sec">Where each migration stands</h2><p class="intro">Finished actions by moment of the project. Click a cell to open the matching actions.</p>${progressGrid()}
  <div class="three" style="margin-top:8px">
    <section><h2 class="sec">What blocks</h2>${blocking.length ? `<ul class="rows">${blocking.slice(0, 6).map(lineA).join('')}</ul><p class="small muted" style="margin-top:6px">${plur(blocking.length, 'blocking action')} in all.</p>` : '<p class="empty">No open blocking action.</p>'}</section>
    <section><h2 class="sec">To decide</h2>${toDecide.length ? `<ul class="rows">${toDecide.slice(0, 6).map(d => `<li><a href="#/steering/decisions">${esc(d.question)}</a><div class="sub-line">${chipT(d.role)}<span>${esc(d.owner)}</span></div></li>`).join('')}</ul><p class="small muted" style="margin-top:6px">${plur(toDecide.length, 'open decision')}. <a href="#/steering/decisions">See them all</a></p>` : '<p class="empty">No open decision.</p>'}</section>
    <section><h2 class="sec">To start now</h2>${start.length ? `<ul class="rows">${start.slice(0, 6).map(lineA).join('')}</ul>` : '<p class="empty">Nothing else to start now.</p>'}</section>
  </div>
  <h2 class="sec">Readiness by tenant</h2><p class="intro">Each workload takes the state of its most severe finding. <b>Score</b> counts what could not be read as lost, so losing a service never raises it. <b>Score of what was read</b> leaves those workloads out: it says how the collected part looks. The difference is how much of the picture is missing. The method is in <a href="#/analysis/coverage">Coverage and method</a>.</p>
  <div class="scores" style="grid-template-columns:repeat(${Math.min(ROLES.length, 4)},minmax(0,1fr))">${[...SOURCES, 'Target'].map(c => scoreBlock(c)).join('')}</div>
  ${heatMap([...SOURCES, 'Target'], WORKLOADS)}`;
  drawLedger();
};

/* tooltip: its text is set as text, never as markup */
document.addEventListener('mouseover', e => {
  const el = e.target.closest('[data-tip]'), b = $('#tooltip');
  if (!el) { b.hidden = true; return; }
  b.textContent = el.dataset.tip; b.hidden = false;
});
document.addEventListener('mousemove', e => { const b = $('#tooltip'); if (b.hidden) return; b.style.left = Math.min(e.clientX + 14, innerWidth - b.offsetWidth - 8) + 'px'; b.style.top = Math.min(e.clientY + 14, innerHeight - b.offsetHeight - 8) + 'px'; });

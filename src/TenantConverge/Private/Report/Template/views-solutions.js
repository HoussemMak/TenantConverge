/* ---------- solutions and products ---------- */
const product = id => SOL.products.find(p => p.id === id);
const FAMILY = id => SOL.families.find(f => f.id === id) || { name: id, icon: 'grid' };
const foundIn = p => ROLES.filter(r => p.traces[r]);
const foundChip = p => { const n = foundIn(p).length; return !p.searched ? '<span class="chip">Not searched</span>' : n ? `<span class="chip info">Found in ${plur(n, 'tenant')}</span>` : '<span class="chip">Not found in what was read</span>'; };
const taskChip = id => { const t = D.tasks.find(x => x.templateId === id); return t ? `<span class="chip" data-tip="${esc(t.title)}">${esc(id)}</span>` : ''; };
/* No trace means no product only where every technical table was read: elsewhere it is a gap, not a zero. */
const traceGap = r => (T[r] && ['Nothing', 'Absent'].includes(T[r].collection) ? 'Not collected' : (SOL.traceCoverage[r] || { unread: [] }).unread.length ? 'Not fully read' : '');
const traceValue = (p, r) => { const x = p.traces[r]; return x ? x.total : !p.searched ? 'Not searched' : traceGap(r) || 0; };

VIEWS.solutions = p => {
  const s = ['copy', 'ews', 'products'].includes(R.sub) ? R.sub : 'copy'; R.sub = s;
  const TITLES = { copy: 'The copy tool', ews: 'The retirement of EWS', products: 'Product sheets' };
  p.innerHTML = `<h1 class="page-title">${presIndex >= 0 ? esc(TITLES[s]) : 'Solutions and products'}</h1><p class="lede no-pres">The tools that can do each part of the migration, public facts about them, and what their limits touch in these tenants. Facts were checked on ${esc(SOL.checkedOn)}: these products change fast, so check again before relying on one.</p>
  ${subnav([['copy', 'Copy tool', 'folder'], ['ews', 'EWS retirement', 'alert'], ['products', 'Product sheets', 'grid', SOL.products.length]], s)}<div id="view"></div>`;
  ({ copy: copyView, ews: ewsView, products: productsView })[s]($('#view'));
};

function copyView(v) {
  const st = SOL.matrixStates, expo = SOL.exposure;
  const cell = c => { const e = st[c.state]; return `<div class="mcell"><span class="m-${esc(c.state)}" data-tip="${esc(e.label)}">${ic(e.icon)}</span><div>${esc(c.note)}${c.source ? ` <span class="small">${sourceLink(c.source)}</span>` : ''}${c.recheck ? ' <span class="chip warn">To confirm</span>' : ''}</div></div>`; };
  const needRow = m => {
    const x = m.exposure ? expo[m.exposure] : null, read = x ? SOURCES.filter(c => x[c] !== null && x[c] !== undefined) : [], total = x ? read.reduce((s, c) => s + x[c], 0) : 0;
    const line = !x ? '' : !read.length ? 'not read in the sources' : `${read.length < SOURCES.length ? 'at least ' : ''}${nb(total)} in the sources`;
    return `<tr><td>${esc(m.name)}${x ? `<div class="muted small" style="font-weight:400">${esc(line)}</div>` : ''}</td>${SOL.copyTools.map(t => `<td>${cell(m.cells[t.id])}</td>`).join('')}</tr>`;
  };
  const facts = SOL.exposureFacts, toneLabel = { ok: ['ok', 'No effect'], warn: ['warn', 'To handle'], info: ['info', 'Good to know'], gap: ['warn', 'Not read'] };
  v.innerHTML = `<p class="intro">A first view for choosing a tool, to complete with a pilot. A cell "To check" means that no public source was read for it: it does not predict the result.</p>
  <div class="state-legend" style="margin-bottom:8px">${Object.entries(st).map(([k, e]) => `<span><span class="m-${esc(k)}">${ic(e.icon, 'p')}</span>${esc(e.label)}</span>`).join('')}</div>
  <div class="frame matrix" style="max-height:74vh"><table class="t"><thead><tr><th>Need</th>${SOL.copyTools.map(t => `<th><a href="#/solutions/products/${esc(t.id)}">${esc(t.name)}</a></th>`).join('')}</tr></thead><tbody>${SOL.copyMatrix.map(needRow).join('')}</tbody></table></div>
  <h2 class="sec">Your data against these limits</h2><p class="intro">What the limits really touch. Computed from the snapshot.</p>
  <div class="frame"><table class="t"><thead><tr><th>Measure</th>${SOURCES.map(c => `<th class="num">${esc(nameOf(c))}</th>`).join('')}<th>Consequence</th></tr></thead><tbody>${facts.map(f => { const t = toneLabel[f.tone] || toneLabel.info; return `<tr><td><b>${esc(f.label)}</b></td>${SOURCES.map(c => { const n = f.values[c]; return `<td class="num">${n === null || n === undefined ? '<span class="chip warn gap">Not read</span>' : `${esc(nb(n))}${f.unit ? ' ' + esc(f.unit) : ''}`}</td>`; }).join('')}<td><span class="chip ${t[0]}">${esc(t[1])}</span> ${esc(f.text)}${f.source ? ` <span class="small">${sourceLink(f.source)}</span>` : ''}</td></tr>`; }).join('')}</tbody></table></div>`;
}

function ewsView(v) {
  const e = SOL.ews, st = SOL.ewsState;
  const reading = x => {
    if (!x.read) return ['Not read', 'warn', `Not collected (${x.status})`];
    if (!x.found) return ['No value', 'warn', 'The setting was not in what was read'];
    const t = String(x.enabled).toLowerCase();
    return t === 'true' ? ['True', 'ok', 'Enabled on purpose'] : t === 'false' ? ['False', 'blocking', 'Blocked'] : ['Empty', 'warn', 'Not set: Microsoft turns it off in its rollout'];
  };
  v.innerHTML = `<p class="intro">Exchange Web Services is the interface several tools use to copy mailboxes. Microsoft retires it, so this comes before choosing a copy tool.</p>
  <div class="milestones">${e.milestones.map(f => `<article><b>${esc(f.date)}</b><div style="font-weight:600">${esc(f.title)}</div><p class="muted">${esc(f.text)} <span class="small">${sourceLink(f.source)}</span> ${checked(f)}</p></article>`).join('')}</div>
  <h2 class="sec">State of your tenants</h2><p class="intro">Values read in the snapshot of ${esc(D.report.snapshotFinished)}.</p>
  <div class="frame"><table class="t"><thead><tr><th>Tenant</th><th>EwsEnabled</th><th>Reading</th><th class="num">Mailboxes with EWS on</th></tr></thead><tbody>${['Target', ...SOURCES].map(r => { const x = st[r], l = reading(x); return `<tr><td>${chipT(r)}</td><td><code>${esc(l[0])}</code></td><td><span class="chip ${l[1]}">${esc(l[2])}</span></td><td class="num">${x.mailboxes === null || x.mailboxes === undefined ? gapChip(r, 'mailboxProtocols') : `${nb(x.usingEws)} of ${nb(x.mailboxes)}`}</td></tr>`; }).join('')}</tbody></table></div>
  <div class="two"><section><h2 class="sec">What depends on it</h2><div class="frame"><table class="t"><tbody>${e.dependencies.map(d => `<tr><td><b>${esc(d.name)}</b></td><td>${esc(d.text)} <span class="small">${sourceLink(d.source)}</span> ${checked(d)}</td></tr>`).join('')}</tbody></table></div></section>
  <section><h2 class="sec">To check, read-only</h2><p class="intro">In Exchange Online PowerShell, for each tenant.</p>${e.readCommands.map(c => cmd(c)).join('')}
  <h3 class="ssec">${ic('alert', 'p')}To remember</h3><ul class="list">${e.cautions.map(x => `<li>${esc(x)}</li>`).join('')}</ul></section></div>`;
}

let productFamily = '';
function productsView(v) {
  if (R.arg && product(R.arg) && productFamily && product(R.arg).family !== productFamily) productFamily = '';
  const list = SOL.products.filter(p => !productFamily || p.family === productFamily), id = R.arg && product(R.arg) ? R.arg : list[0].id;
  v.innerHTML = `<div class="filters"><select data-ch="product-family" aria-label="Family"><option value="">All families</option>${SOL.families.map(f => `<option value="${esc(f.id)}" ${productFamily === f.id ? 'selected' : ''}>${esc(f.name)}</option>`).join('')}</select><span class="muted small">${plur(list.length, 'product')}</span><span class="right"><button class="btn" data-do="csv-products">${ic('down', 'p')}Export</button></span></div>
  <div class="products"><div class="product-list">${SOL.families.map(f => { const l = list.filter(p => p.family === f.id); return l.length ? `<h4>${ic(f.icon, 'p')}${esc(f.name)}</h4>${l.map(p => `<button data-do="sheet" data-id="${esc(p.id)}" aria-pressed="${p.id === id}"><span>${esc(p.name)}</span></button>`).join('')}` : ''; }).join('')}</div><div id="sheet-card"></div></div>`;
  productSheet(id);
}
function productSheet(id) {
  const p = product(id), fam = FAMILY(p.family), tr = p.traces, roles = [...SOURCES, 'Target'];
  const dl = (l, x) => (x ? `<dt>${esc(l)}</dt><dd>${esc(x.text)} <span class="small">${sourceLink(x.source)}</span> ${checked(x)}</dd>` : '');
  const when3 = (t, l) => (l.length ? `<div><h4 style="font-weight:600;margin-bottom:3px">${esc(t)}</h4><ul class="list">${l.map(x => `<li>${esc(x)}</li>`).join('')}</ul></div>` : '');
  const any = Object.keys(tr).length, unread = roles.reduce((s, r) => s + ((SOL.traceCoverage[r] || { unread: [] }).unread.length), 0), examples = uniq(roles.flatMap(r => (tr[r] || { examples: [] }).examples)).slice(0, 6);
  const traceCell = r => { const x = tr[r], gaps = (SOL.traceCoverage[r] || { unread: [] }).unread.length, none = T[r] && ['Nothing', 'Absent'].includes(T[r].collection), gap = traceGap(r); return `<div style="--c:${colorOf(r)}"><div class="tab-name">${esc(nameOf(r))}</div><b>${x ? nb(x.total) : gap ? `<span class="chip warn gap">${esc(gap)}</span>` : '0'}</b>${x ? `<ul>${x.tables.slice(0, 3).map(t => `<li><button class="link" data-do="go-table" data-t="${esc(r)}" data-k="${esc(t[0])}" data-q="">${esc((D.tableLabels[t[0]] || { label: t[0] }).label)}</button> ${nb(t[1])}</li>`).join('')}</ul>` : ''}${!x && !none && gaps ? `<div class="muted small">${plur(gaps, 'table')} not read</div>` : ''}</div>`; };
  $('#sheet-card').innerHTML = `<article class="card"><h2>${esc(p.name)}</h2><div class="card-sub">${foundChip(p)}<span class="muted">${esc(fam.name)}, ${esc(p.publisher)}</span>${safeUrl(p.link) ? extLink(p.link, 'Official site') : ''}${checked(p)}</div>
  <p style="margin-top:10px;font-size:16.5px">${esc(p.role)}</p>
  ${(p.before.length || p.during.length || p.after.length) ? `<h3 class="ssec">${ic('route', 'p')}In the migration</h3><div class="timing">${when3('Before', p.before)}${when3('During', p.during)}${when3('After', p.after)}</div>` : ''}
  ${p.limits.length ? `<h3 class="ssec">${ic('alert', 'p')}Limits to know</h3><ul class="list">${p.limits.map(l => `<li>${esc(l.text)} <span class="small">${sourceLink(l.source)}</span> ${checked(l)}</li>`).join('')}</ul>` : ''}
  ${(p.license || p.rights || p.dataLocation) ? `<h3 class="ssec">${ic('lock', 'p')}License, rights and data</h3><dl>${dl('License model', p.license)}${dl('What it needs', p.rights)}${dl('Where the data goes', p.dataLocation)}</dl>` : ''}
  ${p.searched ? `<h3 class="ssec">${ic('database', 'p')}Traces in your tenants</h3><div class="trace" style="grid-template-columns:repeat(${Math.min(roles.length, 4)},minmax(0,1fr))">${roles.map(traceCell).join('')}</div>${examples.length ? `<p class="muted small" style="margin-top:7px">Examples: ${esc(examples.join(', '))}</p>` : ''}${!any ? `<p class="muted" style="margin-top:6px">Nothing found in what was read.${unread ? ' Some tables could not be read, so this does not prove the product is absent.' : ''}</p>` : ''}` : ''}
  ${(p.tasks || []).some(t => D.tasks.some(x => x.templateId === t)) ? `<h3 class="ssec">${ic('scale', 'p')}Related tasks</h3><div style="display:flex;gap:4px;flex-wrap:wrap">${p.tasks.map(taskChip).join('')}</div>` : ''}</article>`;
}
DO.sheet = el => { history.replaceState(null, '', `#/solutions/products/${encodeURIComponent(el.dataset.id)}`); R.arg = el.dataset.id; document.querySelectorAll('.product-list button').forEach(b => b.setAttribute('aria-pressed', b === el)); productSheet(el.dataset.id); };
CHANGE['product-family'] = t => { productFamily = t.value; const l = SOL.products.filter(p => !productFamily || p.family === productFamily); if (l.length && !l.some(p => p.id === R.arg)) R.arg = l[0].id; productsView($('#view')); };
DO['csv-products'] = () => csv('products.csv', ['Product', 'Publisher', 'Family', 'Role', 'Checked on', 'To confirm', ...ROLES.map(nameOf)], SOL.products.map(p => [p.name, p.publisher, FAMILY(p.family).name, p.role, p.verifiedOn, p.recheck ? 'Yes' : '', ...ROLES.map(r => traceValue(p, r))]));

/* ---------- team tracking ----------
   The file team-tracking.csv is authoritative: what changes or leaves it shows in the report. The report
   receives it at generation, then links to it. The browser keeps only what is not written yet (P.pending),
   so nothing is lost when the file is busy or not linked. Each field keeps its author and time: that is what
   lets the work of several people merge. A row whose item left the plan stays in the file and in the view.
   A row the page cannot read stays in the file as it is, and shows: what a person typed leaves only by a person. */
const PROJECT = D.project.key;
const KEY_COPY = 'tenantconverge:copy:' + PROJECT, KEY = 'tenantconverge:state:' + PROJECT, KEY_ME = 'tenantconverge:me';
const TEAM = D.project.team || [];
const readJson = k => { try { return JSON.parse(localStorage.getItem(k)); } catch (e) { return null; } };
let ME = ''; try { ME = localStorage.getItem(KEY_ME) || ''; } catch (e) { /* no storage */ }
/* Ids come from a file a person can edit: these containers have no prototype to pollute. */
const box = o => Object.assign(Object.create(null), o || {});
const blankState = () => ({ actions: box(), tasks: box(), decisions: box(), config: box(), unknown: [], extra: [] });
function loadState() {
  const raw = readJson(KEY) || {}, p = { conflicts: raw.conflicts || [], pending: box(raw.pending), synced: raw.synced || '', ...blankState(), unknown: raw.unknown || [], extra: raw.extra || [] };
  for (const k of ['actions', 'tasks', 'decisions', 'config']) p[k] = box(raw[k]);
  return p;
}
const P = loadState();
/* Two tabs of one report share this store and each holds its own P, so a tab reads the store again before it writes over
   it. Only what has not reached the file is taken: the rest of the store is a copy of the file, and the file decides that. */
function unwritten(raw) {
  const e = blankState();
  for (const key of Object.keys(raw.pending || {})) {
    const [g, ...r] = key.split('|');
    if (g === 'c') { const k = r.join('|'), v = (raw.config || {})[k]; if (v) e.config[k] = v; continue; }
    const name = STORE[g], id = r[0], field = r[1], s = name ? (raw[name] || {})[id] : null; if (!s) continue;
    const d = e[name][id] || (e[name][id] = {}); if (s.label) d.label = s.label;
    if (field === 'note') { const author = r.slice(2).join('|'), n = (s.notes || {})[author]; if (n) (d.notes = d.notes || box())[author] = n; }
    else if (s[field] !== undefined) { d[field] = s[field]; (d.t = d.t || {})[field] = (s.t || {})[field]; }
  }
  return e;
}
function takeOtherTabs(raw = readJson(KEY)) {
  if (!raw) return 0;
  for (const c of raw.conflicts || []) if (!P.conflicts.some(x => x.key === c.key)) P.conflicts.push(c);
  P.conflicts.length = Math.min(P.conflicts.length, 100);
  const res = mergeInto(unwritten(raw)); if (res.changed) LINK.dirty = true;
  return res.changed;
}
function persist() { takeOtherTabs(); try { localStorage.setItem(KEY, JSON.stringify(P)); } catch (e) { /* no storage */ } }
/* When the value behind a pending key was saved, in the page or in the store. Null when it is not there. */
function savedAt(s, key) {
  const [g, ...r] = key.split('|');
  if (g === 'c') { const v = (s.config || {})[r.join('|')]; return v ? v.at || '' : null; }
  const rec = (s[STORE[g]] || {})[r[0]]; if (!rec) return null;
  if (r[1] === 'note') { const n = (rec.notes || {})[r.slice(2).join('|')]; return n ? n.at || '' : null; }
  return rec[r[1]] === undefined ? null : ((rec.t || {})[r[1]] || {}).at || '';
}
/* Reading the store is no lock: a tab can miss a write made a few milliseconds earlier in another tab, and write over it.
   Every tab hears of every write here. The one that still holds what went missing puts it back, and what another tab took
   to the file stops waiting. A tab writes only when the store really lacks something, so the tabs settle. */
function followOtherTab(text) {
  let raw = null; try { raw = JSON.parse(text); } catch (e) { /* not a state: nothing to follow */ }
  if (!raw) return;
  if (takeOtherTabs(raw)) refresh();
  let lost = false;
  for (const key of Object.keys(P.pending)) {
    const mine = savedAt(P, key), theirs = savedAt(raw, key);
    if (mine === null) continue;
    if (theirs === null || theirs < mine) lost = true;
    else if (!(raw.pending || {})[key]) delete P.pending[key];
  }
  if (lost) persist();
}
function keep() { persist(); if (!ME && !WHO.asked) { WHO.asked = true; askWho(); } LINK.dirty = true; clearTimeout(LINK.timer); LINK.timer = setTimeout(sync, 600); }
const stamp = () => ({ at: new Date().toISOString(), by: ME });
/* One way to say who you are. Clicking a name in Steering shows that person's items, nothing more. */
const WHO = { next: null, asked: false };
function askWho(next) { WHO.next = next || null; const d = $('#who'); if (!d.open) d.showModal(); }
function chooseMe(name) {
  ME = name; const sel = $('#me');
  if (name && ![...sel.options].some(o => o.value === name)) { const o = document.createElement('option'); o.textContent = name; o.value = name; sel.append(o); }
  sel.value = name;
  try { if (name) localStorage.setItem(KEY_ME, name); else localStorage.removeItem(KEY_ME); } catch (e) { /* no storage */ }
  if (!name) return;
  /* what was entered here before giving a name receives the signature */
  let n = 0; const sign = (t, key) => { if (t && t.at && !t.by) { t.by = name; P.pending[key] = {}; n++; } };
  for (const [g, l] of [['a', P.actions], ['k', P.tasks], ['d', P.decisions]]) for (const [id, r] of Object.entries(l)) for (const [k, t] of Object.entries(r.t || {})) sign(t, `${g}|${id}|${k}`);
  for (const [k, v] of Object.entries(P.config)) sign(v, 'c|' + k);
  if (n) keep();
}
const ORIGIN = new WeakMap();
function write(rec, field, val) { const t = rec.t = rec.t || {}, prev = (t[field] || {}).at || ''; rec[field] = val; t[field] = { ...stamp(), prev }; P.pending[`${ORIGIN.get(rec)}|${field}`] = {}; keep(); }
const STORE = { a: 'actions', k: 'tasks', d: 'decisions' };
const record = (g, id) => { const s = P[STORE[g]], r = s[id] || (s[id] = {}); ORIGIN.set(r, g + '|' + id); return r; };
const applied = k => !!(P.config[k] || {}).val;
const statusOf = id => (P.actions[id] || P.tasks[id] || {}).status || 'todo';
const assigneeOf = a => (P.actions[a.id] || P.tasks[a.id] || {}).assignee || '';
/* The latest wins. Two entries that ignore each other: the gap stays visible in Steering, Team.
   Someone who changes a value knowing the previous one creates no conflict: "prev" proves it. */
function mergeFields(dst, src, fields, id, res) {
  for (const k of fields) {
    if (src[k] === undefined) continue;
    const ts = (src.t || {})[k] || { at: '', by: '' }, td = (dst.t || {})[k] || { at: '', by: '' };
    if (src[k] === dst[k]) { if (ts.at > td.at) (dst.t = dst.t || {})[k] = ts; continue; }
    const wins = dst[k] === undefined || ts.at > td.at || (ts.at === td.at && ts.by > td.by);
    const follows = (ts.prev || '') >= td.at || (td.prev || '') >= ts.at;
    if (dst[k] !== undefined && td.by && ts.by && td.by !== ts.by && !follows) {
      const kept = wins ? { v: src[k], ...ts } : { v: dst[k], ...td }, dropped = wins ? { v: dst[k], ...td } : { v: src[k], ...ts }, key = [id, k, dropped.at, dropped.by].join('|');
      if (!P.conflicts.some(x => x.key === key)) { P.conflicts.unshift({ key, id, field: k, kept, dropped }); P.conflicts.length = Math.min(P.conflicts.length, 100); res.conflicts++; }
    }
    if (wins) { dst[k] = src[k]; (dst.t = dst.t || {})[k] = ts; res.changed++; if (res.prefix) P.pending[`${res.prefix}|${id}|${k}`] = {}; }
  }
}
/* Adds an imported tracking file. Everything taken from it leaves for the linked file. */
function merge(state) { const res = mergeInto(state); persist(); return res; }
function mergeInto(state) {
  const res = { changed: 0, conflicts: 0, prefix: 'a' };
  for (const [g, name] of [['a', 'actions'], ['k', 'tasks']]) {
    res.prefix = g;
    for (const [id, s] of Object.entries(state[name])) {
      const d = record(g, id); mergeFields(d, s, ['status', 'assignee'], id, res); if (s.label && !d.label) d.label = s.label;
      for (const [author, n] of Object.entries(s.notes || {})) { const x = (d.notes || {})[author]; if ((!x || (n.at || '') > (x.at || '')) && !(x && x.text === n.text)) { (d.notes = d.notes || box())[author] = n; res.changed++; P.pending[`${g}|${id}|note|${author}`] = {}; } }
    }
  }
  res.prefix = 'd';
  for (const [id, s] of Object.entries(state.decisions)) { const d = record('d', id); mergeFields(d, s, ['answer', 'status'], id, res); if (s.label && !d.label) d.label = s.label; }
  for (const [k, v] of Object.entries(state.config)) { const d = P.config[k]; if (!d || (v.at || '') > (d.at || '')) { if (!d || !!d.val !== !!v.val) res.changed++; P.config[k] = v; P.pending['c|' + k] = {}; } }
  return res;
}

/* ---------- the CSV file: one row per piece of information, readable in Excel ---------- */
const CSV_HEAD = ['Type', 'Id', 'Label', 'Field', 'Value', 'Author', 'Date', 'Replaces'];
const csvCell = v => { const t = safeCell(v); return /[",\r\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t; };
const PLAN_ITEM = { a: Object.fromEntries(D.actions.map(a => [a.id, a])), k: Object.fromEntries(D.tasks.map(t => [t.id, t])), d: Object.fromEntries(D.decisions.map(d => [d.id, d])), c: Object.fromEntries(D.configurations.map(x => [x.role + '|' + x.setting, x])) };
const labelOf = (g, id, rec) => { const i = PLAN_ITEM[g][id]; if (!i) return (rec || {}).label || ''; return g === 'd' ? i.question : g === 'c' ? i.setting : i.title; };
const statusLabel = s => (STATUSES.find(x => x[0] === s) || [0, s])[1];
function stateToCsv() {
  const l = [], row = (type, id, label, field, val, t) => l.push([type, id, label, field, val, (t || {}).by || '', (t || {}).at || '', (t || {}).prev || '']);
  for (const [g, type] of [['a', 'action'], ['k', 'task']]) for (const [id, a] of Object.entries(P[STORE[g]])) {
    const label = labelOf(g, id, a), t = a.t || {};
    if (a.status !== undefined) row(type, id, label, 'status', statusLabel(a.status), t.status);
    if (a.assignee !== undefined) row(type, id, label, 'assignee', a.assignee, t.assignee);
    for (const [n, x] of Object.entries(a.notes || {})) row(type, id, label, 'note', x.text, { by: n, at: x.at, prev: x.prev });
  }
  for (const [id, d] of Object.entries(P.decisions)) {
    const label = labelOf('d', id, d), t = d.t || {};
    if (d.answer !== undefined) row('decision', id, label, 'answer', d.answer, t.answer);
    if (d.status !== undefined) row('decision', id, label, 'status', d.status, t.status);
  }
  for (const [k, v] of Object.entries(P.config)) row('configuration', k, labelOf('c', k, v), 'applied', v.val ? 'Yes' : 'No', v);
  const key = x => [x[0], x[1], x[3], x[5]].join('\u0001');
  l.sort((x, y) => (key(x) < key(y) ? -1 : key(x) > key(y) ? 1 : 0));
  /* Rows it cannot read come first: when two rows give one field a value the last one wins, so this order keeps the answer. */
  return '﻿' + [[...CSV_HEAD, ...P.extra], ...P.unknown.map(x => x.cells), ...l].map(x => x.map(csvCell).join(',')).join('\r\n') + '\r\n';
}
function readCsv(t) {
  t = t.replace(/^﻿/, '');
  /* Excel in some languages saves with semicolons: the header says which. */
  const first = t.split(/\r?\n/, 1)[0], sep = (first.match(/;/g) || []).length > (first.match(/,/g) || []).length ? ';' : ',', rows = [];
  let c = '', l = [], q = false;
  for (let i = 0; i < t.length; i++) {
    const x = t[i];
    if (q) { if (x === '"') { if (t[i + 1] === '"') { c += '"'; i++; } else q = false; } else c += x; }
    else if (x === '"') q = true;
    else if (x === sep) { l.push(c); c = ''; }
    else if (x === '\n') { l.push(c.replace(/\r$/, '')); rows.push(l); l = []; c = ''; }
    else c += x;
  }
  if (c || l.length) { l.push(c.replace(/\r$/, '')); rows.push(l); }
  return rows;
}
const UNSAFE_KEY = /^(__proto__|constructor|prototype)$/;
const low = v => String(v ?? '').trim().toLowerCase();
const WHY = { type: 'Not a type of row the report knows', field: 'Not a field the report knows', status: 'Not a status the report knows', yesNo: 'Expected Yes or No', name: 'The Id or the Author cannot be used', later: 'A later row gives this field a new value' };
function csvToState(text) {
  const [head, ...rows] = readCsv(text), names = (head || []).map(low), c = n => names.indexOf(low(n)), e = blankState();
  if (!head || c('Type') < 0 || c('Id') < 0 || c('Value') < 0) throw new Error('format');
  /* A person can add a column in Excel: it stays, after the columns the page writes. */
  const known = CSV_HEAD.map(c), others = names.flatMap((n, i) => (known.includes(i) ? [] : [i])), held = box();
  e.extra = others.map(i => head[i]);
  const setAside = (r, why) => e.unknown.push({ cells: [...known.map(i => r[i] ?? ''), ...others.map(i => r[i] ?? ''), ...r.slice(head.length)], why });
  /* The last row of a field wins, as it always did. The state holds one value, so the row it replaces goes with the rows set aside. */
  const claim = (key, r) => { if (held[key]) setAside(held[key], WHY.later); held[key] = r; };
  for (const r of rows) {
    if (!r.some(x => x.trim())) continue;
    const get = n => r[c(n)] ?? '', type = low(get('Type')), id = get('Id'), label = get('Label'), field = low(get('Field')), val = get('Value').replace(/^'(?=\s*[=+\-@＝＋－＠])/, ''), by = get('Author'), at = get('Date'), prev = get('Replaces'), t = { at, by, prev }, slot = [type, id, field, field === 'note' ? by : ''].join('\u0001');
    const stray = [...others.filter(i => (r[i] || '').trim()).map(i => head[i] || 'no name'), ...(r.slice(head.length).some(x => x.trim()) ? ['no name'] : [])];
    if (stray.length) { setAside(r, `Text in a column the report does not know: ${uniq(stray).join(', ')}`); continue; }
    if (!id || UNSAFE_KEY.test(id) || UNSAFE_KEY.test(by)) { setAside(r, WHY.name); continue; }
    if (type === 'action' || type === 'task') {
      const s = e[type + 's'], item = () => { const a = s[id] || (s[id] = {}); if (label) a.label = label; return a; };
      if (field === 'status') {
        const x = STATUSES.find(y => low(val) === y[0] || low(val) === low(y[1]));
        if (!x) { setAside(r, WHY.status); continue; }
        claim(slot, r); const a = item(); a.status = x[0]; (a.t = a.t || {}).status = t;
      } else if (field === 'assignee') { claim(slot, r); const a = item(); a.assignee = val; (a.t = a.t || {}).assignee = t; }
      else if (field === 'note') { claim(slot, r); const a = item(); (a.notes = a.notes || box())[by] = { text: val, at, prev }; }
      else setAside(r, WHY.field);
    } else if (type === 'decision') {
      if (field !== 'answer' && field !== 'status') { setAside(r, WHY.field); continue; }
      const v = field === 'status' ? low(val) : val;
      if (field === 'status' && !['open', 'decided'].includes(v)) { setAside(r, WHY.status); continue; }
      claim(slot, r); const d = e.decisions[id] || (e.decisions[id] = {}); if (label) d.label = label;
      d[field] = v; (d.t = d.t || {})[field] = t;
    } else if (type === 'configuration') {
      if (field !== 'applied') { setAside(r, WHY.field); continue; }
      if (!['yes', 'no'].includes(low(val))) { setAside(r, WHY.yesNo); continue; }
      claim(slot, r); e.config[id] = { val: low(val) === 'yes' ? 1 : 0, label, ...t };
    } else setAside(r, WHY.type);
  }
  return e;
}

/* Rows of the file that match nothing in this plan: they stay visible, and nothing removes them. */
function orphans() {
  const l = [], add = (type, g, id, r, text) => { if (!PLAN_ITEM[g][id]) l.push({ type, id, label: r.label || '', text }); };
  for (const [g, type] of [['a', 'action'], ['k', 'task']]) for (const [id, r] of Object.entries(P[STORE[g]])) add(type, g, id, r, [r.status && statusLabel(r.status), r.assignee, ...Object.entries(r.notes || {}).map(([n, x]) => `${n}: ${x.text}`)].filter(Boolean).join(' | '));
  for (const [id, r] of Object.entries(P.decisions)) add('decision', 'd', id, r, [r.answer, r.status].filter(Boolean).join(' | '));
  for (const [id, r] of Object.entries(P.config)) add('configuration', 'c', id, r, r.val ? 'Applied' : 'Not applied');
  return l;
}

/* ---------- the file is authoritative ----------
   What shows = the file + what is not written to it yet. A write stays pending until a read finds it:
   if a colleague overwrote it in the same second, it is written again. */
function carryPending(old, res) {
  for (const key of Object.keys(P.pending)) {
    const [g, ...r] = key.split('|'), e = P.pending[key], hold = () => { e.written = false; res.toWrite = true; }, lift = () => { delete P.pending[key]; };
    if (g === 'c') {
      const k = r.join('|'), v = old.config[k], x = P.config[k];
      if (!v || (x && x.at === v.at && !!x.val === !!v.val)) lift();
      else if (!x || (v.at || '') >= (x.at || '')) { P.config[k] = v; hold(); } else lift();
      continue;
    }
    const id = r[0], field = r[1], author = r.slice(2).join('|'), name = STORE[g], src = old[name][id], target = P[name];
    if (!src) { lift(); continue; }
    const dst = target[id] || (target[id] = {});
    if (field === 'note') {
      const n = (src.notes || {})[author], x = (dst.notes || {})[author];
      if (!n || (x && x.at === n.at)) lift();
      else if (!x || (n.at || '') >= (x.at || '')) { (dst.notes = dst.notes || box())[author] = n; hold(); } else lift();
      continue;
    }
    if (src[field] === undefined) { lift(); continue; }
    const ts = (src.t || {})[field] || {}, td = (dst.t || {})[field];
    if (td && td.at === ts.at && dst[field] === src[field]) { lift(); continue; }
    mergeFields(dst, src, [field], id, res);
    if (dst[field] === src[field]) hold(); else lift();
  }
}
const countRows = () => (stateToCsv().match(/\r\n/g) || []).length - 1;
function adopt(text) {
  const e = text.trim() ? csvToState(text) : blankState();
  const old = { actions: P.actions, tasks: P.tasks, decisions: P.decisions, config: P.config }, before = stateToCsv(), nBefore = countRows(), res = { changed: 0, conflicts: 0, toWrite: false };
  P.actions = e.actions; P.tasks = e.tasks; P.decisions = e.decisions; P.config = e.config; P.unknown = e.unknown; P.extra = e.extra;
  carryPending(old, res);
  res.removed = Math.max(0, nBefore - countRows()); res.change = stateToCsv() !== before; res.unknown = P.unknown.length;
  /* In a team no row disappears by itself: a removal comes from a hand. Keep a way back. */
  if (res.removed) { try { localStorage.setItem(KEY_COPY, JSON.stringify({ text: before, n: nBefore, date: new Date().toISOString() })); } catch (x) { /* no storage */ } }
  persist(); return res;
}
function decodeCsv(buf) { try { return new TextDecoder('utf-8', { fatal: true }).decode(buf); } catch (e) { return new TextDecoder('windows-1252').decode(buf); } }
async function restoreCopy() {
  const c = readJson(KEY_COPY); if (!c || !LINK.h) return;
  try { const w = await LINK.h.createWritable(); await w.write(c.text); await w.close(); localStorage.removeItem(KEY_COPY); LINK.seen = 0; await sync(); refresh(); toast(plur(c.n, 'row restored', 'rows restored')); } catch (e) { toast('File busy: close it, then try again'); }
}

/* ---------- the link to the file ---------- */
const LINK = { h: null, state: 'none', timer: null, running: false, again: false, dirty: false, seen: 0, time: '', toRender: false };
const FILE_API = typeof window.showOpenFilePicker === 'function';
const LINK_LABEL = { none: 'Link tracking', resume: 'Resume tracking', linked: 'Tracking linked', busy: 'File busy', unreadable: 'File unreadable', nofile: 'Local tracking' };
function linkDb() { return new Promise((ok, ko) => { const q = indexedDB.open('tenantconverge', 1); q.onupgradeneeded = () => q.result.createObjectStore('link'); q.onsuccess = () => ok(q.result); q.onerror = () => ko(q.error); setTimeout(() => ko(new Error('timeout')), 1500); }); }
/* One handle per project: the report of a second project must never write to the file of the first. */
async function rememberLink(h) { try { const b = await linkDb(); b.transaction('link', 'readwrite').objectStore('link').put(h, PROJECT); } catch (e) { /* the file will be chosen again next time */ } }
async function recallLink() { try { const b = await linkDb(); return await new Promise(ok => { const q = b.transaction('link').objectStore('link').get(PROJECT); q.onsuccess = () => ok(q.result || null); q.onerror = () => ok(null); }); } catch (e) { return null; } }
function linkState(e) {
  LINK.state = e; const b = $('#link'); if (!b) return;
  b.className = 'link-csv ' + e; b.querySelector('span').textContent = LINK_LABEL[e];
  b.title = e === 'linked' ? `Linked to ${LINK.h ? LINK.h.name : D.tracking.fileName}, up to date at ${LINK.time}` : e === 'busy' ? 'The file is busy, often open in Excel. Your updates wait and leave by themselves.' : e === 'unreadable' ? 'The file lost its columns. The report does not overwrite it.' : e === 'nofile' ? 'This browser cannot write to a file: use Edge or Chrome' : `Link the report to ${D.tracking.fileName}`;
  const z = $('#link-state'); if (z) z.outerHTML = linkBlock();
}
function refresh() {
  const a = document.activeElement;
  if (a && /^(INPUT|TEXTAREA|SELECT)$/.test(a.tagName) && a.closest('#page')) { LINK.toRender = true; return; }
  const y = scrollY; LINK.toRender = false; renderTabs(); render(); scrollTo(0, y);
}
async function linkFile(change) {
  if (!ME) { askWho(() => linkFile(change)); return; }
  try {
    if (!LINK.h || change) { const [h] = await window.showOpenFilePicker({ id: 'team-tracking', multiple: false, types: [{ description: 'Tracking file', accept: { 'text/csv': ['.csv'] } }] }); LINK.h = h; LINK.seen = 0; rememberLink(h); }
    if ((await LINK.h.requestPermission({ mode: 'readwrite' })) !== 'granted') { linkState('resume'); toast('Without permission, the report cannot write to the file'); return; }
    LINK.dirty = true; linkState('linked'); await sync(); if (LINK.state === 'linked') toast('Tracking linked: your changes are written to the file');
  } catch (e) { if (e.name !== 'AbortError') { LINK.h = null; linkState('none'); toast(`File not reachable: choose ${D.tracking.fileName}`); } }
}
async function sync() {
  if (takeOtherTabs()) refresh();
  if (!LINK.h || !['linked', 'busy', 'unreadable'].includes(LINK.state)) return;
  if (LINK.running) { LINK.again = true; return; }
  LINK.running = true;
  try {
    const f = await LINK.h.getFile();
    if (LINK.dirty || f.lastModified !== LINK.seen) {
      const r = adopt(decodeCsv(await f.arrayBuffer()));
      LINK.dirty = false; P.synced = new Date().toISOString();
      /* Only what waits is written: the file is never redone for nothing, nor reformatted. */
      if (r.toWrite) {
        const w = await LINK.h.createWritable(); await w.write(stateToCsv()); await w.close();
        Object.values(P.pending).forEach(e => { e.written = true; });
        LINK.seen = 0; setTimeout(sync, 1200);   /* read again to confirm: a colleague may have written just after */
      } else LINK.seen = f.lastModified;
      persist();
      if (r.change) { refresh(); toast(`${r.removed ? `${plur(r.removed, 'row', 'rows')} removed from the tracking file` : 'Tracking updated from the file'}${r.unknown ? `, ${plur(r.unknown, 'row')} not recognised` : ''}${r.conflicts ? `, ${plur(r.conflicts, 'conflict')} to check` : ''}`); }
    }
    LINK.time = new Date().toLocaleTimeString('en-CA', { hour: '2-digit', minute: '2-digit' }); linkState('linked');
  } catch (e) {
    if (e.name === 'NotFoundError') { LINK.h = null; linkState('none'); toast('The tracking file moved: link it again'); }
    else if (e.name === 'NotAllowedError') linkState('resume');
    else if (e.message === 'format') linkState('unreadable');
    else { LINK.dirty = true; linkState('busy'); }
  } finally { LINK.running = false; if (LINK.again) { LINK.again = false; sync(); } }
}
async function startLink() {
  if (!FILE_API) { linkState('nofile'); return; }
  linkState('none');
  const h = await recallLink(); if (!h) return;
  LINK.h = h;
  try { const p = await h.queryPermission({ mode: 'readwrite' }); linkState(p === 'granted' ? 'linked' : 'resume'); if (p === 'granted') sync(); } catch (e) { LINK.h = null; linkState('none'); }
}

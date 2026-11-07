/* Walks every view of a report and returns what it found. Runs in the page, from the browser tests. */
window.reportWalk = async function (options) {
  const settings = options || {};
  const wait = ms => new Promise(r => setTimeout(r, ms));
  const found = { views: [], injected: [], blank: [], wide: [], emptyColumns: [], tips: 0, text: '' };
  const routes = [['summary', '']];
  for (const r of [...SOURCES, 'Target']) for (const s of subsOf(r)) routes.push([r, s]);
  for (const s of ['copy', 'ews', 'products']) routes.push(['solutions', s]);
  routes.push(['analysis', 'consolidation'], ['analysis', 'workloads'], ['analysis', 'findings']);
  if (D.settingGaps.length) routes.push(['analysis', 'gaps']);
  routes.push(['analysis', 'coverage']);
  for (const t of steeringTabs()) routes.push(['steering', t[0]]);
  routes.push(['guide', '']);

  const check = name => {
    for (const el of document.querySelectorAll('*')) {
      if (el.closest('#report-data,#report-tables')) continue;
      if ([...el.attributes].some(a => /^on/i.test(a.name))) found.injected.push(`${name}: ${el.tagName} with a handler`);
      if (/^(IMG|IFRAME|OBJECT|EMBED|LINK|BASE|FORM)$/.test(el.tagName) && !(el.tagName === 'LINK' && el.rel === 'icon') && el.id !== 'who-free') found.injected.push(`${name}: ${el.tagName}`);
      for (const k of ['href', 'src', 'action', 'formaction']) { const v = el.getAttribute(k); if (v && /^\s*(javascript|data|vbscript):/i.test(v) && el.tagName !== 'LINK') found.injected.push(`${name}: ${k}=${v.slice(0, 40)}`); }
    }
    if (document.scripts.length !== 3) found.injected.push(`${name}: ${document.scripts.length} scripts`);
    if (window.__xss) found.injected.push(`${name}: a script ran (${window.__xss})`);
    const page = $('#page');
    if (page.innerText.trim().length < 15) found.blank.push(name);
    const doc = document.documentElement;
    if (doc.scrollWidth > doc.clientWidth + 1) found.wide.push(`${name}: ${doc.scrollWidth} in ${doc.clientWidth}`);
    for (const table of page.querySelectorAll('table.t')) {
      if (table.closest('#table')) continue;
      const rows = [...table.querySelectorAll('tbody tr')].filter(r => !r.classList.contains('group'));
      if (rows.length < 2) continue;
      const heads = [...table.querySelectorAll('thead th')];
      heads.forEach((h, i) => {
        const empty = rows.every(r => { const c = r.children[i]; return !c || (!c.textContent.trim() && !c.querySelector('input,svg,span,.gauge')); });
        if (empty) found.emptyColumns.push(`${name}: "${h.textContent.trim()}"`);
      });
    }
    found.views.push(name);
    if (settings.keepText) found.text += '\n' + page.innerText;
  };

  for (const [tab, sub] of routes) {
    go(tab, sub); route();
    await wait(tab !== 'summary' && sub === 'data' ? 60 : 15);
    const name = `${tab}/${sub}`;
    if (settings.deep) {
      if (sub === 'plan' && document.getElementById('list')) { filterActions(tab).forEach(a => opened.add(a.id)); planList(tab); }
      if (sub === 'tasks') { (tab === 'steering' ? D.tasks : tasksOf(tab)).forEach(t => opened.add(t.id)); render(); await wait(5); }
      if (sub === 'findings') document.querySelectorAll('details.item').forEach(d => { d.open = true; });
      if (sub === 'products') for (const p of SOL.products) { productSheet(p.id); check(`${name}/${p.id}`); }
      if (sub === 'data' && T[tab]) for (const k of Object.keys(D.tableStates[tab])) { TV[tab].table = k; TV[tab].page = 0; showTable(tab); check(`${name}/${k}`); }
      for (const el of document.querySelectorAll('[data-tip]')) { el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true })); found.tips++; if ($('#tooltip').children.length) found.injected.push(`${name}: markup in a tooltip`); }
    }
    check(name);
  }
  if (settings.deep) {
    /* search, with each kind of result */
    for (const q of (settings.searches || [])) { search(q); searchRows(q.toLowerCase()); await wait(5); check(`search ${q}`); }
    closeSearch();
    /* presentation mode */
    present(0); for (let i = 1; i < PRESENTATION.length; i++) { present(i); await wait(10); check(`present ${i}`); } endPresentation();
  }
  go('summary'); route();
  return found;
};

/* Replaces the download so a test can read what a person would save. */
window.reportExports = [];
window.reportCapture = function () {
  const create = URL.createObjectURL;
  URL.createObjectURL = blob => { window.reportExports.push(blob); return create.call(URL, blob); };
  HTMLAnchorElement.prototype.click = function () { };
};
window.reportExportAll = async function () {
  window.reportExports.length = 0;
  go('Target', 'plan'); route(); await new Promise(r => setTimeout(r, 20));
  for (const r of [...SOURCES, 'Target']) {
    go(r, 'plan'); route(); await new Promise(x => setTimeout(x, 10));
    if (document.getElementById('list')) DO['csv-plan']();
    if (D.configurations.some(x => inRole(x, r))) { go(r, 'config'); route(); DO['csv-config'](); }
    if (r !== 'Target' && D.identity[r].rows.length) { go(r, 'identities'); route(); DO['csv-identity'](); }
    go(r, 'data'); route(); await new Promise(x => setTimeout(x, 60));
    for (const k of Object.keys(inventory()[r] || {})) { TV[r].table = k; DO['csv-table'](); }
  }
  DO['csv-findings'](); DO['csv-products'](); DO['csv-decisions'](); DO['csv-tasks']();
  if (D.settingGaps.length) DO['csv-gaps']();
  const texts = [];
  for (const blob of window.reportExports) { const buffer = await blob.arrayBuffer(); texts.push(new TextDecoder('utf-8', { ignoreBOM: true }).decode(buffer)); }
  return texts;
};

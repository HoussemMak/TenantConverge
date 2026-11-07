/* ---------- events ---------- */
document.addEventListener('click', e => {
  const el = e.target.closest('[data-do]');
  if (el && DO[el.dataset.do]) { if (el.tagName === 'A') e.preventDefault(); DO[el.dataset.do](el, e); }
  if (!e.target.closest('.search')) $('#results').classList.remove('open');
});
document.addEventListener('change', e => { const t = e.target, n = t.dataset.ch; if (n && CHANGE[n]) CHANGE[n](t); });
document.addEventListener('input', e => {
  const t = e.target;
  if (t.id === 'search') search(t.value);
  else if (t.dataset.in && INPUT[t.dataset.in]) INPUT[t.dataset.in](t);
});
document.addEventListener('keydown', e => {
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName);
  if ($('#who').open) return;
  if (e.key === 'Escape') { $('#results').classList.remove('open'); if (e.target.id === 'search') e.target.blur(); if (presIndex >= 0) endPresentation(); return; }
  if (presIndex >= 0 && !typing) { if (['ArrowRight', 'PageDown', ' '].includes(e.key)) { e.preventDefault(); present(presIndex + 1); } else if (['ArrowLeft', 'PageUp'].includes(e.key)) { e.preventDefault(); present(presIndex - 1); } return; }
  if (typing || e.ctrlKey || e.metaKey || e.altKey) return;
  if (e.key === '/') { e.preventDefault(); $('#search').focus(); }
  else if (e.key === '?') go('guide');
  else if (e.key === 'p' || e.key === 'P') present(0);
});
$('#file').addEventListener('change', async e => {
  const files = [...e.target.files], names = [], total = { changed: 0, conflicts: 0, unknown: 0 }; let unreadable = 0;
  e.target.value = '';
  for (const f of files) {
    try { const s = csvToState(decodeCsv(await f.arrayBuffer())), r = merge(s); total.changed += r.changed; total.conflicts += r.conflicts; total.unknown += s.unknown.length; names.push(f.name); } catch (err) { unreadable++; }
  }
  LINK.dirty = true; sync(); renderTabs(); render();
  toast(names.length ? `${plur(total.changed, 'update')} taken from ${names.join(', ')}${total.unknown ? `, ${plur(total.unknown, 'row')} not recognised and left in that file` : ''}${total.conflicts ? `, ${plur(total.conflicts, 'conflict')} to check` : ''}${unreadable ? `, ${plur(unreadable, 'file')} unreadable` : ''}` : 'Tracking file unreadable');
});
const meOptions = uniq([...TEAM, ME].filter(Boolean));
$('#me').innerHTML = `<option value="">Who are you?</option>${meOptions.map(n => `<option ${n === ME ? 'selected' : ''}>${esc(n)}</option>`).join('')}`;
$('#me').addEventListener('change', e => { chooseMe(e.target.value); render(); });
$('#who-names').innerHTML = TEAM.map(n => `<button class="btn" data-do="i-am" data-n="${esc(n)}">${ic('person', 'p')}${esc(n)}</button>`).join('');
$('#who-free').addEventListener('submit', e => { e.preventDefault(); const n = $('#who-input').value.trim(); if (n) { $('#who-input').value = ''; useName(n); } });
$('#who').addEventListener('close', () => { WHO.next = null; });
document.addEventListener('focusout', () => setTimeout(() => { if (LINK.toRender) refresh(); }, 60));
document.addEventListener('visibilitychange', () => { if (!document.hidden) sync(); });
window.addEventListener('focus', () => sync());   /* back from Excel or Notepad: read again at once */
window.addEventListener('storage', e => { if (e.key === KEY && e.newValue) followOtherTab(e.newValue); });   /* another tab of this report saved */
setInterval(() => { if (!document.hidden) sync(); }, 15000);
window.addEventListener('hashchange', route);
window.addEventListener('resize', align);

/* ---------- start ---------- */
try { const t = localStorage.getItem('tenantconverge:theme'); if (t) document.documentElement.dataset.theme = t; } catch (e) { /* no storage */ }
document.title = `${D.project.name}: consolidation report`;
$('#brand-name').textContent = D.project.name;
/* The tracking known at generation: a new report starts from it, even with no link to the file. */
if (D.tracking.text && (!P.synced || (D.report.generatedIso || '') > P.synced)) { try { adopt(D.tracking.text); } catch (e) { toast('Tracking file unreadable at generation'); } }
$('#footer').textContent = `Generated on ${D.report.generated} from the snapshot of ${D.report.snapshotFinished}. Holds personal data: do not share it without the agreement of the customer.`;
route();
startLink();
/* First opening of the session with no known name: ask once, and do not block reading. */
if (!ME) { let seen = false; try { seen = !!sessionStorage.getItem('tenantconverge:who'); sessionStorage.setItem('tenantconverge:who', '1'); } catch (e) { /* no storage */ } if (!seen) askWho(); }

import Foundation

// Kleine aanpassingen aan Pinterests pagina-indeling.
// - De inbox-knop (berichten en meldingen) in de balk onderin verbergen.
// - Een geopende pin opmaken zoals in de Pinterest-app (alleen in de brede opmaak).
let pageTweaksJS = #"""
(() => {
  'use strict';

  // ---------- Inbox-knop verbergen ----------

  const INBOX = /inbox|message|notification|conversation|updates|berichten|meldingen/i;

  const describe = (el) => (el.getAttribute('aria-label') || '') + ' ' + (el.getAttribute('href') || '') +
                           ' ' + (el.getAttribute('data-test-id') || '');

  // Knop in de onderbalk: klein en in de onderste strook van het scherm
  const inBottomBar = (el) => {
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.width < 200 && r.top > innerHeight - 160;
  };

  // Verberg het hele "vakje" van de knop, niet alleen het icoon, zodat er geen gat overblijft
  const slotOf = (el) => {
    let slot = el;
    while (slot.parentElement && slot.parentElement.children.length === 1 && slot.parentElement !== document.body) {
      slot = slot.parentElement;
    }
    return slot;
  };

  let hidden = null;   // de verborgen knop; zolang die op de pagina staat, hoeven we niets te doen

  const hideInbox = () => {
    if (hidden && hidden.isConnected && hidden.style.display === 'none') return;
    for (const el of document.querySelectorAll('a, button, [role="button"], [role="tab"], [role="link"]')) {
      if (INBOX.test(describe(el)) && inBottomBar(el)) {
        hidden = slotOf(el);
        hidden.style.setProperty('display', 'none', 'important');
        return;
      }
    }
  };

  // ---------- Geopende pin opmaken zoals in de app ----------
  // We verschuiven en vergroten blokken alleen visueel (transform), zodat Pinterests eigen
  // opbouw en knoppen gewoon blijven werken. Namen komen uit de pagina-analyse (data-test-id).

  const q = (id, root = document) => root.querySelector('[data-test-id="' + id + '"]');
  const style = document.createElement('style');
  style.textContent =
    // Terugknop als donker rondje op de hoek van de afbeelding
    '.pf-back { background: rgba(0,0,0,.45) !important; border-radius: 50% !important; color: #fff !important; }' +
    '.pf-back svg, .pf-back path { fill: #fff !important; color: #fff !important; }';
  document.documentElement.appendChild(style);

  const moved = new Set();   // elementen waar wij een transform op zetten
  const setT = (el, t) => { if (!el) return; el.style.transform = t; moved.add(el); };
  const reset = () => { for (const el of moved) if (el.isConnected) el.style.transform = ''; moved.clear(); };

  const layoutPin = () => {
    reset();
    const body = q('closeup-body-landscape');
    if (!body || !location.pathname.includes('/pin/') || innerWidth < 1000) return;
    const image = q('closeup-container', body);
    const details = q('CloseupDetails', body);
    if (!image || !details) return;
    const ir = image.getBoundingClientRect();
    if (ir.width < 100) return;

    // 1. Afbeelding naar de linkerrand, en zo groot als de ruimte toelaat (max. 12% groter)
    const margin = 16;
    const room = innerHeight - ir.top - 150;              // laat "More to explore" nog net zien
    const scale = Math.max(1, Math.min(1.12, room / ir.height));
    const dx = margin - ir.left;
    setT(image, 'translateX(' + dx + 'px) scale(' + scale + ')');
    image.style.transformOrigin = 'top left';
    const grow = ir.height * (scale - 1);
    const related = q('closeup-related-modules-container');
    if (related) { related.style.marginTop = grow + 'px'; }
    const imageRight = margin + ir.width * scale;

    // 2. Details direct rechts naast de afbeelding (de hele kolom in één keer)
    const dr = details.getBoundingClientRect();
    const detailsDx = Math.min(0, imageRight + 28 - dr.left);
    if (detailsDx) setT(details, 'translateX(' + detailsDx + 'px)');

    // 3. Knoppenbalk omhoog, gelijk met de bovenkant van de afbeelding (zoals in de app).
    //    Wat onder de balk stond, schuift omhoog in het gat dat hij achterlaat.
    //    (Binnen de verschoven kolom alleen verticaal schuiven; dat telt bij de kolom op.)
    const header = q('header', details);
    const bar = q('pin-action-bar-container', details);
    if (header && bar) {
      const hr = header.getBoundingClientRect();
      const up = ir.top - hr.top;
      if (up < -4) {
        const outermost = (test) => {
          const picked = [];
          for (const el of details.querySelectorAll('[data-test-id]')) {
            if (el === header || header.contains(el) || el.contains(header)) continue;
            if (picked.some((p) => p.contains(el))) continue;
            const r = el.getBoundingClientRect();
            if (r.height > 0 && test(r)) picked.push(el);
          }
          return picked;
        };
        const above = outermost((r) => r.bottom <= hr.top + 1);
        const below = outermost((r) => r.top >= hr.bottom - 1);
        const lastInfoBottom = Math.max(dr.top, ...above.map((el) => el.getBoundingClientRect().bottom));
        setT(header, 'translateY(' + up + 'px)');
        const lift = lastInfoBottom - hr.bottom;   // negatief: zoveel omhoog
        if (lift < 0) for (const el of below) setT(el, 'translateY(' + lift + 'px)');
      }

      // Save helemaal rechts in de balk, zoals in de app
      if (getComputedStyle(bar).display.includes('flex')) {
        const slot = (id) => { let s = q(id, bar); while (s && s.parentElement !== bar) s = s.parentElement; return s; };
        const order = { 'comment-button': 1, 'share-button': 2, 'visit-button-mobile': 3, 'standard-save-button': 9 };
        for (const [id, n] of Object.entries(order)) { const s = slot(id); if (s) s.style.order = n; }
        const save = slot('standard-save-button');
        if (save) save.style.marginLeft = 'auto';
      }
    }

    // 4. Terugknop als rondje op de hoek van de afbeelding
    const back = q('back-button');
    if (back) {
      back.classList.add('pf-back');
      const br = back.getBoundingClientRect();
      setT(back, 'translate(' + (margin + 12 - br.left) + 'px,' + (ir.top + 12 - br.top) + 'px)');
    }
  };

  // ---------- Opnieuw toepassen als de pagina verandert ----------

  let queued = false;
  let lastKey = '';
  const run = () => {
    queued = false;
    hideInbox();
    // Alleen opnieuw opmaken als er een andere pin of opmaak is (scheelt werk tijdens scrollen)
    const body = q('closeup-body-landscape');
    const key = location.pathname + '|' + innerWidth + '|' + (body ? 'L' : '-') + '|' +
                (q('closeup-container') ? Math.round(q('closeup-container').offsetHeight) : 0);
    if (key !== lastKey) { lastKey = key; layoutPin(); }
  };
  const schedule = () => {
    if (queued) return;
    queued = true;
    setTimeout(run, 150);
  };
  new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true });
  window.addEventListener('resize', () => { lastKey = ''; schedule(); });
  window.addEventListener('popstate', schedule);
  run();
})();
"""#

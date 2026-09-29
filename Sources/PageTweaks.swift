import Foundation

// Kleine aanpassingen aan Pinterests pagina-indeling.
// - De inbox-knop (berichten en meldingen) in de balk onderin verbergen.
// - Een geopende pin opmaken zoals in de Pinterest-app (alleen in de brede opmaak).
//
// De pin-opmaak is defensief: eerst meten we alles, dan rekenen we uit of het past, dan verschuiven we
// en daarna controleren we het resultaat. Past het niet (of is er iets afgesneden), dan draaien we
// ALLES terug en blijft Pinterests eigen opmaak staan ("safe"). Zo kan onze aanpassing nooit de
// oorzaak zijn van een afgesneden pin. De uitkomst gaat als "closeupReady" naar de app (LayoutBridge
// in Transitions.swift), samen met de plek van de afbeelding, zodat de open-animatie niet hoeft te gokken.
let pageTweaksJS = #"""
(() => {
  'use strict';

  const R = Math.round;
  const native = (m) => { try { webkit.messageHandlers.pfLayout.postMessage(m); } catch (e) {} };
  // Korte gebeurtenissenlijst voor de pagina-analyse (zie Columns.swift); zelfde lijst als columnsJS
  const log = (m) => {
    try {
      const a = (window.__pfLog = window.__pfLog || []);
      const v = window.visualViewport;
      a.push(R(performance.now()) + ' ' + m + ' iw=' + innerWidth + ' vv=' + ((v && v.scale) || 1).toFixed(2));
      if (a.length > 24) a.shift();
    } catch (e) {}
  };
  const settledNow = () => !(window.__pfVP && window.__pfVP.pending);   // viewport klaar? (columnsJS)

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
  // Bestaat de knop in deze opmaak niet (liggend, uitgelogd), dan zoeken we niet eindeloos door het
  // hele raster: per pagina/schermmaat een beperkt aantal pogingen, met tijd ertussen.
  let scanKey = '', scanTries = 0, lastScan = 0;

  const hideInbox = () => {
    if (hidden && hidden.isConnected && hidden.style.display === 'none') return;
    hidden = null;
    const key = location.pathname + '|' + innerWidth + '|' + innerHeight;
    if (key !== scanKey) { scanKey = key; scanTries = 0; }
    const now = performance.now();
    // Eerst snel (12 keer, 700 ms ertussen); daarna niet stoppen maar rustiger (elke 4 s), want de
    // onderbalk kan bij een trage verbinding pas veel later verschijnen.
    if (now - lastScan < (scanTries >= 12 ? 4000 : 700)) return;
    scanTries++;
    lastScan = now;
    for (const el of document.querySelectorAll('a, button, [role="button"], [role="tab"], [role="link"]')) {
      if (INBOX.test(describe(el)) && inBottomBar(el)) {
        const slot = slotOf(el);
        const r = slot.getBoundingClientRect();
        if (r.width > 300 || r.height > 200) continue;   // een grote container verbergen geeft een leeg scherm
        hidden = slot;
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

  // Alles wat we aanpassen wordt bijgehouden, zodat reset() het volledig kan terugdraaien
  const undo = [];      // [element, eigenschap, oude waarde, oude prioriteit]
  const classed = [];   // [element, klasse]
  const setStyle = (el, prop, val, prio = '') => {
    if (!el) return;
    undo.push([el, prop, el.style.getPropertyValue(prop), el.style.getPropertyPriority(prop)]);
    el.style.setProperty(prop, val, prio);
  };
  const setT = (el, t) => setStyle(el, 'transform', t);
  const addClass = (el, c) => { if (el && !el.classList.contains(c)) { el.classList.add(c); classed.push([el, c]); } };
  const reset = () => {
    for (let i = undo.length - 1; i >= 0; i--) {
      const [el, prop, old, prio] = undo[i];
      if (old) el.style.setProperty(prop, old, prio); else el.style.removeProperty(prop);
    }
    undo.length = 0;
    for (const [el, c] of classed) el.classList.remove(c);
    classed.length = 0;
  };

  let queued = false, fastQueued = false;   // staat er al een run() ingepland? (zie schedule)
  let lastKey = '', keyPath = '';   // sleutel van de laatste opmaak-ronde (zie run)
  let runToken = 0;       // een nieuwe opmaak-ronde annuleert de vorige
  let lastStatus = '';    // 'ok' | 'safe' | 'plain' | 'geen'
  let curKey = '', safeKey = '';
  let lastPost = '';

  // Onthoud wat er besloten is (voor de pagina-analyse)
  const record = (status, reason, info) => {
    lastStatus = status;
    const v = window.visualViewport;
    window.__pfLayout = Object.assign({ t: R(performance.now()), path: location.pathname, iw: innerWidth,
                                         vs: (v && v.scale) || 1, status, reason }, info || {});
    log('layout ' + status + (reason ? ' (' + reason + ')' : ''));
  };

  // Grootste afbeelding in het pinblok (de foto zelf), anders het blok
  const imageRectOf = (cont) => {
    let best = null, area = 0;
    for (const img of cont.querySelectorAll('img')) {
      const r = img.getBoundingClientRect();
      const a = r.width * r.height;
      if (r.width > 120 && r.height > 120 && a > area) { best = r; area = a; }
    }
    return best || cont.getBoundingClientRect();
  };

  // Meld de app dat de pinpagina klaar is, met de plek van de afbeelding in punten van de webview
  const post = (status, cont, natural) => {
    if (!cont || !cont.isConnected) return;
    const r = imageRectOf(cont);
    if (r.width < 20 || r.height < 20) return;
    const s = (window.visualViewport && visualViewport.scale) || 1;
    const msg = { type: 'closeupReady', path: location.pathname, status, iw: innerWidth,
                  x: r.left * s, y: r.top * s, w: r.width * s, h: r.height * s,
                  nw: natural ? natural.w * s : 0, nh: natural ? natural.h * s : 0 };
    const sig = [msg.path, status, R(msg.x), R(msg.y), R(msg.w), R(msg.h)].join('|');
    if (sig === lastPost) return;
    lastPost = sig;
    if (window.__pfLayout) window.__pfLayout.img = [R(r.left), R(r.top), R(r.width), R(r.height)];
    native(msg);
  };

  // Wacht tot de plek van een element twee frames achter elkaar gelijk is (Pinterest is nog aan het bouwen
  // of animeren), of 12 frames voorbij zijn. Stopt als er een nieuwe ronde is of de viewport nog wisselt.
  const whenStable = (el, my, cb) => {
    let prev = null, n = 0;
    const step = () => {
      if (my !== runToken) return;
      // Element vervangen of viewport wisselt nog: sleutel wissen, zodat de volgende ronde opnieuw meet
      if (!el.isConnected || !settledNow()) { lastKey = ''; return; }
      const r = el.getBoundingClientRect();
      const cur = [r.left, r.top, r.width, r.height];
      const same = prev && cur.every((v, i) => Math.abs(v - prev[i]) < 0.5);
      if (same || ++n > 12) { cb(); return; }
      prev = cur;
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  };

  // Ouders die de verschoven afbeelding zouden afknippen (overflow, clip-path, contain). Waar het kan
  // zetten we dat uit (terug te draaien); scrollende containers laten we met rust en tellen als fout.
  const liftClips = (image) => {
    const bad = [];
    const ir = image.getBoundingClientRect();
    const clipping = [];
    for (let a = image.parentElement; a && a !== document.body && a !== document.documentElement; a = a.parentElement) {
      const cs = getComputedStyle(a);
      const clips = cs.overflowX !== 'visible' || cs.overflowY !== 'visible' || cs.clipPath !== 'none' ||
                    /paint|strict|content/.test(cs.contain);
      if (!clips) continue;
      const r = a.getBoundingClientRect();
      const out = Math.max(r.left - ir.left, ir.right - r.right, r.top - ir.top, ir.bottom - r.bottom);
      if (out <= 1) continue;
      const scrolls = /auto|scroll/.test(cs.overflowY) && a.scrollHeight > a.clientHeight + 2;
      if (scrolls) { bad.push('geknipt door scrollcontainer ' + (a.getAttribute('data-test-id') || a.tagName.toLowerCase()) + ' ' + R(out) + ' px'); continue; }
      clipping.push(a);
    }
    for (const a of clipping) {
      setStyle(a, 'overflow', 'visible', 'important');
      setStyle(a, 'clip-path', 'none', 'important');
      setStyle(a, 'contain', 'none', 'important');
    }
    for (const a of clipping) {
      const cs = getComputedStyle(a);
      if (cs.overflowX !== 'visible' || cs.overflowY !== 'visible' || cs.clipPath !== 'none') {
        bad.push('geknipt door ' + (a.getAttribute('data-test-id') || a.tagName.toLowerCase()));
      }
    }
    return bad;
  };

  // Controle na het opmaken: alles binnen het scherm, geen zijwaarts scrollen, niets afgeknipt
  const verify = (image, details, back, W, baseScroll) => {
    const bad = [];
    const check = (name, el) => {
      if (!el) return;
      const r = el.getBoundingClientRect();
      if (r.width > 0 && (r.left < -1 || r.right > W + 1)) bad.push(name + ' ' + R(r.left) + '..' + R(r.right) + ' van ' + W);
    };
    check('afbeelding', image);
    check('details', details);
    check('terugknop', back);
    const de = document.documentElement;
    if (de.scrollWidth > Math.max(W + 1, baseScroll)) bad.push('scrollWidth ' + de.scrollWidth + ' > ' + W);
    if (Math.abs(window.scrollX) > 1) window.scrollTo(0, window.scrollY);
    return bad.concat(liftClips(image));
  };

  // Terug naar Pinterests eigen opmaak, en onthoud dat dit voor deze pin niet past
  const goSafe = (why, cont, info) => {
    reset();
    safeKey = curKey;
    record('safe', why, info);
    post('safe', cont);
  };

  const place = (my, cont, image, details) => {
    const W = Math.min(innerWidth, document.documentElement.clientWidth || innerWidth);
    const vs = (window.visualViewport && visualViewport.scale) || 1;

    // 1. Eerst alles meten, dan pas schrijven (schrijven tussen het meten door dwingt steeds nieuwe layout af)
    const ir = image.getBoundingClientRect();
    if (ir.width < 100) { record('plain', 'afbeelding te smal'); post('plain', cont); return; }
    const dr = details.getBoundingClientRect();
    const related = q('closeup-related-modules-container');
    const header = q('header', details);
    const bar = q('pin-action-bar-container', details);
    const back = q('back-button');
    const hr = header ? header.getBoundingClientRect() : null;
    const br = back ? back.getBoundingClientRect() : null;
    const baseScroll = document.documentElement.scrollWidth;

    let up = 0, lift = 0, below = [];
    if (header && bar && hr) {
      up = ir.top - hr.top;
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
        below = outermost((r) => r.top >= hr.bottom - 1);
        const lastInfoBottom = Math.max(dr.top, ...above.map((el) => el.getBoundingClientRect().bottom));
        lift = lastInfoBottom - hr.bottom;   // negatief: zoveel omhoog
      }
    }
    const barFlex = !!bar && getComputedStyle(bar).display.includes('flex');
    const slot = (id) => { let s = bar && q(id, bar); while (s && s.parentElement !== bar) s = s.parentElement; return s; };

    // 2. Uitrekenen of het past. Afbeelding naar de linkerrand, zo groot als de hoogte toelaat (max. 12%
    //    groter), details direct rechts ernaast. Bij te weinig breedte eerst minder vergroten; past het
    //    dan nog niet, dan doen we niets.
    const margin = 16, gap = 28, edge = 16;
    const room = innerHeight - ir.top - 150;                 // laat "More to explore" nog net zien
    let scale = Math.max(1, Math.min(1.12, room / ir.height));
    const detailsShift = (s) => {
      const imageRight = margin + ir.width * s;
      let d = imageRight + gap - dr.left;
      if (d > 0 && dr.left - imageRight >= 12) d = 0;       // er zit al genoeg ruimte tussen
      return d;
    };
    let detailsDx = detailsShift(scale);
    if (detailsDx > 0) {
      const sMax = (W - edge - dr.width - gap - margin) / ir.width;
      if (sMax < 1) {
        goSafe('past niet: breedte ' + W + ', details ' + R(dr.width) + ', beeld ' + R(ir.width), cont,
               { ir: [R(ir.left), R(ir.top), R(ir.width), R(ir.height)], dr: [R(dr.left), R(dr.top), R(dr.width), R(dr.height)] });
        return;
      }
      if (sMax < scale) { scale = sMax; detailsDx = detailsShift(scale); }
    }
    const imageRight = margin + ir.width * scale;
    const dx = margin - ir.left;
    const grow = ir.height * (scale - 1);

    // 3. Toepassen
    setT(image, 'translateX(' + dx + 'px) scale(' + scale + ')');
    setStyle(image, 'transform-origin', 'top left');
    if (related) setStyle(related, 'margin-top', grow + 'px');
    if (detailsDx) setT(details, 'translateX(' + detailsDx + 'px)');

    //    Knoppenbalk omhoog, gelijk met de bovenkant van de afbeelding (zoals in de app).
    //    Wat onder de balk stond, schuift omhoog in het gat dat hij achterlaat.
    //    (Binnen de verschoven kolom alleen verticaal schuiven; dat telt bij de kolom op.)
    if (header && bar && up < -4) {
      setT(header, 'translateY(' + up + 'px)');
      if (lift < 0) for (const el of below) setT(el, 'translateY(' + lift + 'px)');
    }
    //    Save helemaal rechts in de balk, zoals in de app
    if (header && bar && barFlex) {
      const order = { 'comment-button': 1, 'share-button': 2, 'visit-button-mobile': 3, 'standard-save-button': 9 };
      for (const [id, n] of Object.entries(order)) { const s = slot(id); if (s) setStyle(s, 'order', String(n)); }
      const save = slot('standard-save-button');
      if (save) setStyle(save, 'margin-left', 'auto');
    }
    //    Terugknop als rondje op de hoek van de afbeelding
    if (back && br) {
      addClass(back, 'pf-back');
      setT(back, 'translate(' + (margin + 12 - br.left) + 'px,' + (ir.top + 12 - br.top) + 'px)');
    }

    // 4. Controleren; bij twijfel alles terugdraaien
    const info = { ir: [R(ir.left), R(ir.top), R(ir.width), R(ir.height)], dr: [R(dr.left), R(dr.top), R(dr.width), R(dr.height)],
                   scale: +scale.toFixed(3), dx: R(dx), detailsDx: R(detailsDx), imageRight: R(imageRight), W };
    const bad = verify(image, details, back, W, baseScroll);
    if (bad.length) { goSafe(bad.join('; '), cont, info); return; }
    record('ok', '', info);
    post('ok', cont, { w: ir.width, h: ir.height });

    // Pinterest bouwt soms nog even door: nog een keer controleren als het rustig is
    setTimeout(() => {
      if (my !== runToken || lastStatus !== 'ok' || !image.isConnected) return;
      const again = verify(image, details, back, W, baseScroll);
      if (again.length) goSafe('later: ' + again.join('; '), cont, info);
    }, 500);
  };

  const layoutPin = (my) => {
    reset();   // altijd vanaf Pinterests eigen opmaak beginnen
    if (!location.pathname.includes('/pin/')) return;
    const cont = q('closeup-container');
    if (!cont) { record('geen', 'geen closeup-container'); return; }
    const body = q('closeup-body-landscape');
    const image = body && q('closeup-container', body);
    const details = body && q('CloseupDetails', body);
    if (!body || !image || !details || innerWidth < 1000) {
      const why = !body ? 'geen closeup-body-landscape' : (innerWidth < 1000 ? 'te smal (' + innerWidth + ')' : 'blokken ontbreken');
      whenStable(cont, my, () => { record('plain', why); post('plain', cont); });
      return;
    }
    // Eerder gebleken dat de app-opmaak hier niet past: Pinterests eigen opmaak laten staan
    if (curKey === safeKey) { whenStable(cont, my, () => post('safe', cont)); return; }
    whenStable(image, my, () => place(my, cont, image, details));
  };

  // Elke pinpagina: past de pagina in de breedte? Zo niet, dan de viewport één keer opnieuw laten instellen.
  // (Voor pins waar we niets verschuiven: video, carrousel, staande opmaak.)
  const guardTried = new Set();
  const guard = (path, my) => {
    if (my !== runToken || location.pathname !== path || lastStatus === 'ok') return;
    const de = document.documentElement;
    if (Math.abs(window.scrollX) > 2) window.scrollTo(0, window.scrollY);
    if (de.scrollWidth > innerWidth + 2) {
      log('bewaker: scrollWidth ' + de.scrollWidth + ' > ' + innerWidth);
      if (!guardTried.has(path)) {
        guardTried.add(path);
        reset();
        if (window.__pfRecheckViewport) window.__pfRecheckViewport();
      }
    }
  };

  // ---------- Opnieuw toepassen als de pagina verandert ----------

  // Verandert het pinblok van grootte (afbeelding laadt later), dan opnieuw opmaken
  let ro = null, roEl = null;
  const watchContainer = (el) => {
    if (!window.ResizeObserver || el === roEl) return;
    if (ro) ro.disconnect();
    roEl = el;
    let first = true;
    ro = new ResizeObserver(() => { if (first) { first = false; return; } schedule(true); });
    ro.observe(el);
  };

  const ids = new WeakMap();   // Pinterest kan het pinblok vervangen; een nieuw element telt als nieuwe situatie
  let idSeq = 0;
  const idOf = (el) => { if (!el) return 0; if (!ids.has(el)) ids.set(el, ++idSeq); return ids.get(el); };
  const run = () => {
    queued = fastQueued = false;
    hideInbox();
    if (!location.pathname.includes('/pin/')) {
      // Terug in de feed: alles teruggedraaid en klaar voor de volgende pin
      if (lastKey !== 'feed') {
        lastKey = 'feed'; keyPath = location.pathname; curKey = safeKey = ''; lastPost = '';
        lastStatus = '';
        runToken++;
        reset();
      }
      return;
    }
    // De viewport wisselt nog (columnsJS): meten heeft nu geen zin. Na het "resize"-signaal komen we terug.
    if (!settledNow()) return;
    const body = q('closeup-body-landscape');
    const cont = q('closeup-container');
    if (cont) watchContainer(cont);
    const vs = (window.visualViewport && visualViewport.scale) || 1;
    // Alleen opnieuw opmaken als er een andere pin, schermmaat of opmaak is (scheelt werk tijdens scrollen)
    const key = location.pathname + '|' + innerWidth + 'x' + innerHeight + '@' + vs.toFixed(2) + '|' + (body ? 'L' : '-') + '|' +
                (cont ? idOf(cont) + ':' + Math.round(cont.offsetWidth) + 'x' + Math.round(cont.offsetHeight) : 0);
    keyPath = location.pathname;
    if (key === lastKey) return;
    lastKey = curKey = key;
    const my = ++runToken;
    const path = location.pathname;
    layoutPin(my);
    setTimeout(() => guard(path, my), 500);
  };

  // Op een pinpagina meteen bij de eerstvolgende frame (nieuwe pin of het pinblok is er nog niet);
  // anders 150 ms verzamelen zodat het raster tijdens scrollen niet steeds werk geeft.
  const schedule = (fast) => {
    if (fast && location.pathname.includes('/pin/')) {
      if (fastQueued) return;
      fastQueued = true;
      requestAnimationFrame(run);
      return;
    }
    if (queued) return;
    queued = true;
    setTimeout(run, 150);
  };
  new MutationObserver(() => {
    const onPin = location.pathname.includes('/pin/');
    schedule(onPin && (keyPath !== location.pathname || !roEl || !roEl.isConnected));
  }).observe(document.body, { childList: true, subtree: true });
  window.addEventListener('resize', () => schedule(true));
  window.addEventListener('popstate', () => schedule(true));
  run();
})();
"""#

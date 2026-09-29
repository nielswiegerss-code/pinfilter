import Foundation

// JavaScript voor de YouTube-weergave (alleen daar; nooit in de Pinterest-weergave).
//
// LET OP: alle selectors, renderernamen en spelerdetails hieronder komen uit filterlijsten en uit het
// geheugen, NIET uit een echte, ingelogde m.youtube.com-sessie. Ze zijn onbevestigd tot Niels een
// screenshot van de YouTube-analyse heeft gestuurd (lang indrukken op de wisselknop, zie ytProbeJS).
//
// Regels voor elk script:
// - alleen in de hoofdframe en alleen op *.youtube.com, nooit op accounts.google.com, accounts.youtube.com
//   of consent.youtube.com (daar mag niets aan de pagina veranderen, anders blokkeert Google het inloggen)
// - geen brug naar de app (geen WKScriptMessageHandler): de app praat alleen via evaluateJavaScript
// - elke functie die we vervangen ziet er bij toString() uit als de echte, ingebouwde functie

// Advertenties: antwoorden van YouTubes eigen API opschonen (niet JSON.parse of Response.json globaal
// vervangen, want daar let YouTube juist op). Shorts worden met hetzelfde mechanisme uit de lijsten gehaald.
let ytAdFilterJS = #"""
(() => {
  'use strict';
  const H = location.hostname;
  if (!/(^|\.)youtube\.com$/.test(H) || H === 'accounts.youtube.com' || H === 'consent.youtube.com') return;

  const HIDE_SHORTS = true;
  const NEUTRALISE_ABNORMALITY = false;   // alleen aanzetten als YouTube het afspelen gaat blokkeren
  let removed = 0;
  const origParse = JSON.parse;

  // Vervangen functies laten zich bij toString() gelden als de originele, ingebouwde functie
  const nts = Function.prototype.toString;
  const fake = new WeakMap();
  const disguise = (f, real) => {
    try {
      fake.set(f, nts.call(real));
      Object.defineProperty(f, 'length', { value: real.length, configurable: true });
      Object.defineProperty(f, 'name', { value: real.name, configurable: true });
    } catch (e) {}
    return f;
  };
  const ts = new Proxy(nts, { apply: (t, self, a) => (fake.has(self) ? fake.get(self) : Reflect.apply(t, self, a)) });
  fake.set(ts, nts.call(nts));
  Function.prototype.toString = ts;

  // Namen van advertentie- en Shorts-blokken in YouTubes data (onbevestigd, zie bovenaan)
  const AD = ['adSlotRenderer', 'promotedSparklesWebRenderer', 'promotedSparklesTextSearchRenderer',
    'compactPromotedVideoRenderer', 'promotedVideoRenderer', 'searchPyvRenderer', 'bannerPromoRenderer',
    'statementBannerRenderer', 'brandVideoSingleRenderer', 'brandVideoShelfRenderer',
    'videoMastheadAdV3Renderer', 'primetimePromoRenderer', 'inFeedAdLayoutRenderer', 'displayAdRenderer',
    'actionCompanionAdRenderer', 'playerLegacyDesktopWatchAdsRenderer'];
  const SHORT = ['reelShelfRenderer', 'shortsLockupViewModel', 'reelItemRenderer'];
  const has = (o, list) => list.some((k) => k in o);

  // Is dit array-item een advertentie of Short? Kijkt ook een paar lagen dieper in het item zelf.
  const bad = (o, d = 0) => {
    if (!o || typeof o !== 'object' || Array.isArray(o) || d > 3) return false;
    if (has(o, AD)) return true;
    if (HIDE_SHORTS && (has(o, SHORT) || (o.navigationEndpoint && o.navigationEndpoint.reelWatchEndpoint))) return true;
    for (const v of Object.values(o)) if (v && typeof v === 'object' && !Array.isArray(v) && bad(v, d + 1)) return true;
    return false;
  };
  const prune = (n, d) => {
    if (!n || typeof n !== 'object' || d > 60) return;
    if (Array.isArray(n)) {
      for (let i = n.length - 1; i >= 0; i--) {
        if (bad(n[i])) { n.splice(i, 1); removed++; } else prune(n[i], d + 1);
      }
      return;
    }
    for (const k of Object.keys(n)) prune(n[k], d + 1);
  };
  // Spelerdata: de velden waaruit de speler zijn advertenties haalt weghalen
  const cleanPlayer = (o) => {
    if (o && typeof o === 'object') {
      for (const k of ['adPlacements', 'adSlots', 'playerAds', 'adBreakHeartbeatParams']) if (k in o) { delete o[k]; removed++; }
      if (o.playerResponse) cleanPlayer(o.playerResponse);
    }
    return o;
  };

  // A. Begindata: YouTube zet die inline in de pagina (var ytInitialData = {...}); opschonen bij het toewijzen
  const hook = (name, fn) => {
    let v;
    try {
      Object.defineProperty(window, name, {
        configurable: true,
        get: () => v,
        set: (x) => { try { v = fn(x); } catch (e) { v = x; } }
      });
    } catch (e) {}
  };
  hook('ytInitialPlayerResponse', (x) => cleanPlayer(x));
  hook('ytInitialData', (x) => { prune(x, 0); return x; });

  // B. API-antwoorden: alleen YouTubes eigen /youtubei/v1/-adressen (dus nooit de videostream zelf)
  const API = /\/youtubei\/v1\/(player|get_watch|next|browse|search|reel\/)/;
  const MARK = /"(adSlotRenderer|promotedSparklesWebRenderer|compactPromotedVideoRenderer|promotedVideoRenderer|reelShelfRenderer|shortsLockupViewModel|reelWatchEndpoint)"/;
  const rewrite = (text) => {
    let t = text.replace(/"(adPlacements|adSlots|playerAds)"/g, '"no_$1"');
    if (MARK.test(t)) {
      try { const o = origParse(t); prune(o, 0); t = JSON.stringify(o); } catch (e) {}
    }
    return t;
  };

  const of = window.fetch;
  window.fetch = disguise(async function fetch(input, init) {
    const res = await of.apply(this, arguments);
    try {
      const url = String((input && input.url) || input);
      if (!API.test(url)) return res;
      const text = await res.clone().text();
      const out = rewrite(text);
      if (out === text) return res;
      const fresh = new Response(out, { status: res.status, statusText: res.statusText, headers: res.headers });
      try { Object.defineProperty(fresh, 'url', { value: res.url }); } catch (e) {}
      return fresh;
    } catch (e) { return res; }
  }, of);

  const urls = new WeakMap(), cache = new WeakMap(), seen = new WeakSet();
  const xo = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = disguise(function open(m, u) {
    try { urls.set(this, String(u)); } catch (e) {}
    return xo.apply(this, arguments);
  }, xo);
  for (const p of ['response', 'responseText']) {
    const d = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, p);
    if (!d || !d.get) continue;
    const g = disguise(function () {
      const r = d.get.call(this);
      try {
        const u = urls.get(this);
        if (this.readyState !== 4 || !u || !API.test(u)) return r;
        if (typeof r === 'string') {
          const c = cache.get(this);
          if (c && c.src === r) return c.out;
          const out = rewrite(r);
          cache.set(this, { src: r, out });
          return out;
        }
        if (r && typeof r === 'object' && !seen.has(r)) { seen.add(r); cleanPlayer(r); prune(r, 0); }
      } catch (e) {}
      return r;
    }, d.get);
    Object.defineProperty(XMLHttpRequest.prototype, p, { configurable: true, enumerable: d.enumerable, get: g });
  }

  // C. YouTube haalt soms via een nieuw iframe een "schone" fetch op om te zien of die is aangepast; die krijgt onze versie
  for (const m of ['appendChild', 'insertBefore']) {
    const o = Node.prototype[m];
    Node.prototype[m] = disguise(function (n) {
      const r = o.apply(this, arguments);
      try { if (n && n.tagName === 'IFRAME' && n.contentWindow) n.contentWindow.fetch = window.fetch; } catch (e) {}
      return r;
    }, o);
  }

  // D. Anti-adblock-melding van YouTube onschadelijk maken (staat uit, zie bovenaan)
  if (NEUTRALISE_ABNORMALITY) {
    Promise.prototype.then = new Proxy(Promise.prototype.then, {
      apply: (t, self, a) => {
        if (typeof a[0] === 'function' && a[0].toString().includes('onAbnormalityDetected')) a[0] = function () {};
        return Reflect.apply(t, self, a);
      }
    });
  }

  // E. Vangnet voor advertenties die toch in de speler beginnen: dempen, naar het einde spoelen, overslaan.
  // Niet bij "SSAP" (advertenties die in de videostream zelf zijn gelijmd): dan zou echte inhoud wegvallen.
  let queued = false;
  const skip = () => {
    queued = false;
    const p = document.querySelector('#movie_player.ad-showing, .html5-video-player.ad-showing');
    if (!p) return;
    let ssap = false;
    try { ssap = String((p.getStatsForNerds && p.getStatsForNerds().debug_info) || '').startsWith('SSAP'); } catch (e) {}
    const v = p.querySelector('video');
    if (v && !ssap && isFinite(v.duration) && v.duration > 0) { v.muted = true; v.currentTime = v.duration; }
    document.querySelectorAll('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern, .videoAdUiSkipButton, .ytp-ad-overlay-close-button')
      .forEach((b) => b.click());
  };
  const watch = () => {
    if (!document.documentElement) return false;
    new MutationObserver(() => { if (!queued) { queued = true; requestAnimationFrame(skip); } })
      .observe(document.documentElement, { subtree: true, childList: true, attributes: true, attributeFilter: ['class'] });
    return true;
  };
  if (!watch()) {
    const wait = new MutationObserver(() => { if (watch()) wait.disconnect(); });
    wait.observe(document, { childList: true });
  }

  window.__pfAdStats = () => removed;
})();
"""#

// Uiterlijk: app-achtige opmaak, advertentie- en Shorts-blokken verbergen (vangnet naast de data-filter),
// en Home/Explore/Shorts uit de onderbalk. Alleen CSS en een kleine opruimlus, geen dataverandering.
let ytStyleJS = #"""
(() => {
  'use strict';
  const H = location.hostname;
  if (!/(^|\.)youtube\.com$/.test(H) || H === 'accounts.youtube.com' || H === 'consent.youtube.com') return;

  const CSS = `
    * { -webkit-tap-highlight-color: transparent; }
    html, body { -webkit-touch-callout: none; }
    /* Promoties, "open de app", Premium */
    ytm-mealbar-promo-renderer, ytm-upsell-dialog-renderer, ytm-statement-banner-renderer,
    ytd-enforcement-message-view-model { display: none !important; }
    /* Advertenties */
    #player-ads, .ytp-ad-module, .ytp-ad-overlay-container, ytm-promoted-sparkles-web-renderer,
    ytm-promoted-video-renderer, ytm-companion-slot, ytm-ad-slot-renderer, ytm-brand-video-singleton-renderer,
    ytd-ad-slot-renderer, ytm-rich-item-renderer:has(ytm-ad-slot-renderer),
    ytm-item-section-renderer:has(> ytm-ad-slot-renderer) { display: none !important; }
    /* Shorts */
    ytm-reel-shelf-renderer, ytm-shorts-lockup-view-model, ytm-shorts-lockup-view-model-v2,
    ytm-rich-section-renderer:has(ytm-reel-shelf-renderer), ytm-item-section-renderer:has(ytm-reel-shelf-renderer),
    ytm-pivot-bar-item-renderer:has(.pivot-shorts),
    ytm-video-with-context-renderer:has(ytm-thumbnail-overlay-time-status-renderer[data-style="SHORTS"]),
    ytm-video-with-context-renderer:has(a[href^="/shorts/"]),
    ytm-rich-item-renderer:has(a[href^="/shorts/"]) { display: none !important; }
  `;
  const addStyle = () => {
    if (!document.documentElement) return false;
    const st = document.createElement('style');
    st.textContent = CSS;
    document.documentElement.appendChild(st);
    return true;
  };

  // Wat CSS niet kan: onderbalk opruimen (Home, Explore, Shorts), de chip "Shorts", en "open de app"-knoppen
  const PIVOT_HIDE = /^(home|startpagina|explore|verkennen|shorts)$/i;
  let queued = false;
  const tidy = () => {
    queued = false;
    for (const it of document.querySelectorAll('ytm-pivot-bar-item-renderer')) {
      const a = it.querySelector('a[href]');
      const path = a ? (a.getAttribute('href') || '').split('?')[0] : null;
      const label = (it.textContent || '').trim();
      if (path === '/' || path === '/feed/explore' || path === '/shorts' || PIVOT_HIDE.test(label)) it.style.display = 'none';
    }
    for (const c of document.querySelectorAll('ytm-chip-cloud-chip-renderer')) {
      if (/^shorts$/i.test((c.textContent || '').trim())) c.style.display = 'none';
    }
    for (const b of document.querySelectorAll('ytm-mobile-topbar-renderer a, ytm-mobile-topbar-renderer button')) {
      const t = (b.getAttribute('aria-label') || b.textContent || '').trim();
      if (/(open|get|download).{0,8}app|app openen|app downloaden/i.test(t)) b.style.display = 'none';
    }
  };
  const start = () => {
    if (!document.documentElement) return false;
    new MutationObserver(() => { if (!queued) { queued = true; requestAnimationFrame(tidy); } })
      .observe(document.documentElement, { subtree: true, childList: true });
    return true;
  };

  if (!addStyle() || !start()) {
    const wait = new MutationObserver(() => { if (addStyle()) { start(); wait.disconnect(); } });
    wait.observe(document, { childList: true });
  }
})();
"""#

// Achtergrondgeluid en Beeld-in-beeld: de pagina denkt dat hij altijd zichtbaar is (dan pauzeert
// YouTube niet), hervat de video als iOS hem toch pauzeert bij het verlaten van de app, klikt de
// vraag "Kijk je nog?" weg, en zet een PiP-knop in de speler. De app roept __pfBg(aan/uit) en
// __pfResume() aan (zie YouTube.swift) en __pfPip() voor Beeld-in-beeld.
let ytMediaJS = #"""
(() => {
  'use strict';
  const H = location.hostname;
  if (!/(^|\.)youtube\.com$/.test(H) || H === 'accounts.youtube.com' || H === 'consent.youtube.com') return;

  const nts = Function.prototype.toString;
  const fake = new WeakMap();
  const disguise = (f, real) => {
    try {
      fake.set(f, nts.call(real));
      Object.defineProperty(f, 'length', { value: real.length, configurable: true });
      Object.defineProperty(f, 'name', { value: real.name, configurable: true });
    } catch (e) {}
    return f;
  };
  const ts = new Proxy(nts, { apply: (t, self, a) => (fake.has(self) ? fake.get(self) : Reflect.apply(t, self, a)) });
  fake.set(ts, nts.call(nts));
  Function.prototype.toString = ts;

  // 1. Altijd "zichtbaar"
  const spoof = (proto, prop, value) => {
    try {
      const d = Object.getOwnPropertyDescriptor(proto, prop);
      Object.defineProperty(proto, prop, {
        configurable: true,
        enumerable: d ? d.enumerable : true,
        get: d && d.get ? disguise(function () { return value; }, d.get) : () => value
      });
    } catch (e) {}
  };
  spoof(Document.prototype, 'hidden', false);
  spoof(Document.prototype, 'webkitHidden', false);
  spoof(Document.prototype, 'visibilityState', 'visible');
  spoof(Document.prototype, 'webkitVisibilityState', 'visible');
  try { Document.prototype.hasFocus = disguise(function hasFocus() { return true; }, Document.prototype.hasFocus); } catch (e) {}
  for (const t of ['visibilitychange', 'webkitvisibilitychange']) {
    document.addEventListener(t, (e) => e.stopImmediatePropagation(), true);
    window.addEventListener(t, (e) => e.stopImmediatePropagation(), true);
  }
  // YouTube mag niet reageren op het wisselen naar of van Beeld-in-beeld (dan pauzeert de video soms)
  window.addEventListener('webkitpresentationmodechanged', (e) => e.stopImmediatePropagation(), true);

  // 2. "Kijk je nog?" wegklikken en YouTube laten denken dat er nog iemand is
  setInterval(() => {
    try {
      window._lact = Date.now();
      const b = document.querySelector('yt-confirm-dialog-renderer #confirm-button button, ' +
        'ytm-confirm-dialog-renderer button.yt-spec-button-shape-next--call-to-action, ' +
        'ytm-confirm-dialog-renderer .dialog-buttons button');
      if (b) b.click();
    } catch (e) {}
  }, 60000);

  // 3. Hervatten: iOS pauzeert de video als de app naar de achtergrond gaat. De app zegt dat hij weggaat
  // (__pfBg(true)) en vraagt daarna hervatten (__pfResume). Een pauze binnen 2,5 s na het weggaan is van iOS,
  // een latere pauze (bijvoorbeeld via het vergrendelscherm) van jou en blijft staan.
  let bg = false, was = false, t0 = 0;
  const vid = () => document.querySelector('video');
  window.__pfBg = (on) => {
    bg = on;
    if (on) { const v = vid(); was = !!v && !v.paused && !v.ended; t0 = Date.now(); } else was = false;
  };
  window.__pfResume = () => {
    const v = vid();
    if (bg && was && v && v.paused) { const p = v.play(); if (p && p.catch) p.catch(() => {}); }
  };
  document.addEventListener('pause', (e) => {
    if (bg && was && e.target instanceof HTMLVideoElement && Date.now() - t0 < 2500) setTimeout(window.__pfResume, 40);
  }, true);

  // 4. Beeld-in-beeld: de app en de knop in de speler gebruiken dezelfde functie
  window.__pfPip = () => {
    const v = vid();
    if (!v) return 'geen video';
    try {
      if (v.webkitSetPresentationMode) {
        v.webkitSetPresentationMode(v.webkitPresentationMode === 'picture-in-picture' ? 'inline' : 'picture-in-picture');
        return 'ok';
      }
      if (document.pictureInPictureElement) { document.exitPictureInPicture(); return 'ok'; }
      if (v.requestPictureInPicture) { v.requestPictureInPicture().catch(() => {}); return 'ok'; }
    } catch (e) { return 'fout ' + e; }
    return 'niet ondersteund';
  };

  const CSS = `
    .pf-pip { position: absolute; top: 10px; right: 64px; z-index: 60; width: 36px; height: 36px; padding: 0;
      border: 0; border-radius: 18px; background: rgba(0, 0, 0, 0.55); display: flex; align-items: center;
      justify-content: center; opacity: 0; pointer-events: none; transition: opacity 0.2s; }
    .pf-pip svg { width: 22px; height: 22px; fill: #fff; }
    #movie_player:not(.ytp-autohide) .pf-pip, .html5-video-player:not(.ytp-autohide) .pf-pip,
    #movie_player.paused-mode .pf-pip { opacity: 1; pointer-events: auto; }
  `;
  const makeButton = () => {
    const b = document.createElement('button');
    b.className = 'pf-pip';
    b.setAttribute('aria-label', 'Beeld-in-beeld');
    const NS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(NS, 'svg');
    svg.setAttribute('viewBox', '0 0 24 24');
    const path = document.createElementNS(NS, 'path');
    path.setAttribute('d', 'M19 7h-8v6h8V7zm2-4H3c-1.1 0-2 .9-2 2v14c0 1.1.9 1.98 2 1.98h18c1.1 0 2-.88 2-1.98V5c0-1.1-.9-2-2-2zm0 16.01H3V4.98h18v14.03z');
    svg.appendChild(path);
    b.appendChild(svg);
    b.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); window.__pfPip(); });
    return b;
  };
  let queued = false;
  const inject = () => {
    queued = false;
    if (!document.head || !location.pathname.startsWith('/watch')) return;
    if (!document.getElementById('pf-pip-style')) {
      const st = document.createElement('style');
      st.id = 'pf-pip-style';
      st.textContent = CSS;
      document.head.appendChild(st);
    }
    const player = document.querySelector('#movie_player, .html5-video-player');
    if (player && !player.querySelector('.pf-pip')) player.appendChild(makeButton());
  };
  const watch = () => {
    if (!document.documentElement) return false;
    new MutationObserver(() => { if (!queued) { queued = true; requestAnimationFrame(inject); } })
      .observe(document.documentElement, { subtree: true, childList: true });
    return true;
  };
  if (!watch()) {
    const wait = new MutationObserver(() => { if (watch()) wait.disconnect(); });
    wait.observe(document, { childList: true });
  }
})();
"""#

// Analyse voor als er toch een advertentie doorheen komt: wordt onder de pagina-analyse gezet (lang indrukken
// op de wisselknop terwijl YouTube open staat). Niels maakt er een screenshot van voor Claude.
let ytProbeJS = #"""
(() => {
  const L = [];
  try {
    L.push('agent ' + navigator.userAgent);
    L.push('pagina ' + location.href);
    L.push('webkit-brug ' + (window.webkit && window.webkit.messageHandlers ? 'ja' : 'nee'));
    L.push('zichtbaarheid ' + document.visibilityState + ' hidden=' + document.hidden);
    L.push('weggehaald ' + (window.__pfAdStats ? window.__pfAdStats() : 'filter draait niet'));
    const p = document.querySelector('#movie_player');
    if (p) {
      L.push('speler .ad-showing ' + p.classList.contains('ad-showing') + '  klassen ' + p.className);
      try {
        const r = p.getPlayerResponse ? p.getPlayerResponse() : null;
        L.push('spelerdata ' + (r ? ['adPlacements', 'adSlots', 'playerAds'].map((k) => k + '=' + (k in r)).join(' ') : 'geen'));
      } catch (e) { L.push('spelerdata fout ' + e); }
      try { L.push('stats ' + String((p.getStatsForNerds && p.getStatsForNerds().debug_info) || '-')); } catch (e) {}
    } else {
      L.push('speler geen #movie_player');
    }
    const v = document.querySelector('video');
    L.push('video ' + (v ? 'paused=' + v.paused + ' pip=' + (v.webkitPresentationMode || '-') + ' t=' + Math.round(v.currentTime) : 'geen'));
    L.push('pip-knop ' + (document.querySelector('.pf-pip') ? 'ja' : 'nee'));

    // Blokken in de begindata met Ad/Promoted/Reel/Short in de naam (dat wat het filter liet staan)
    const keys = {};
    const walk = (n, d, c) => {
      if (!n || typeof n !== 'object' || d > 40 || c.n > 60000) return;
      c.n++;
      if (Array.isArray(n)) { for (const x of n) walk(x, d + 1, c); return; }
      for (const k of Object.keys(n)) {
        if (/(^|[a-z])(Ad|Promoted|Reel|Shorts?)([A-Z]|$)/.test(k) || /^ad[A-Z]/.test(k)) keys[k] = (keys[k] || 0) + 1;
        walk(n[k], d + 1, c);
      }
    };
    if (window.ytInitialData) walk(window.ytInitialData, 0, { n: 0 });
    const ks = Object.keys(keys).slice(0, 30).map((k) => k + 'x' + keys[k]);
    L.push('begindata-sleutels ' + (ks.join(' · ') || 'geen'));

    const items = (sel) => document.querySelectorAll(sel).length;
    L.push('ytm-elementen: pivot ' + items('ytm-pivot-bar-item-renderer') + '  chips ' + items('ytm-chip-cloud-chip-renderer') +
           '  shorts-links ' + items('a[href^="/shorts/"]') + '  advertentie-slots ' + items('ytm-ad-slot-renderer, ytm-promoted-sparkles-web-renderer'));
    const tags = {};
    for (const el of document.querySelectorAll('*')) {
      const t = el.tagName.toLowerCase();
      if (/^yt[dm]-/.test(t) && /(ad|promo|banner|upsell|mealbar|app)/.test(t)) tags[t] = (tags[t] || 0) + 1;
    }
    L.push('verdachte tags ' + (Object.keys(tags).slice(0, 25).map((k) => k + 'x' + tags[k]).join(' · ') || 'geen'));
  } catch (e) { L.push('fout ' + e); }
  return L.join('\n');
})()
"""#

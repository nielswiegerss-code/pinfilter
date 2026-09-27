import UIKit
import WebKit

// Lang indrukken op een pin opent een rond menu, zoals in de Pinterest-app.
// Sleep naar een optie en laat los (of tik erop).
// Beide opties openen onzichtbaar Pinterests eigen "…"-menu van de pin en tikken daarin:
// - Save: "Save", waarna Pinterest de bordkeuze toont (de pin gaat niet open).
// - Hide: "See less", zodat Pinterest minder van dit soort pins laat zien.

// Brug van JavaScript naar de app: trillen, en scrollen uit/aan zolang het menu open is
final class NativeBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    weak var transitions: PinTransitions?
    private let generator = UIImpactFeedbackGenerator(style: .medium)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "haptic":
            generator.impactOccurred()
        case "scroll":
            webView?.scrollView.isScrollEnabled = (body["on"] as? Bool) ?? true
        case "pinTap":
            // Tik op een pin in het raster: open-animatie starten (zie Transitions.swift)
            let n = { (key: String) in CGFloat((body[key] as? NSNumber)?.doubleValue ?? 0) }
            let rect = CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
            let pinId = (body["pinId"] as? String) ?? ""
            MainActor.assumeIsolated { transitions?.pinTapped(rect: rect, pinId: pinId) }
        default:
            break
        }
    }
}

let pinSaveJS = #"""
(() => {
  'use strict';
  const HOLD_MS = 450;      // hoe lang indrukken voordat het menu verschijnt
  const MOVE_CANCEL = 10;   // zoveel pixels bewegen = scrollen, geen lang indrukken

  // iOS-"afbeelding bewaren" en tekstselectie uitzetten op pins (erft door naar alles erin)
  const style = document.createElement('style');
  style.textContent =
    '[data-grid-item] { -webkit-touch-callout: none !important; -webkit-user-select: none !important; user-select: none !important; }' +
    // Indruk-effect: de pin veert iets in zolang je hem aanraakt
    '[data-grid-item] > * { transition: transform .2s cubic-bezier(.2,.8,.3,1); }' +
    '[data-grid-item].pf-press > * { transform: scale(.96); }' +
    // Het menu, zoals in de Pinterest-app: donkere achtergrond, opgetilde pin, knoppen in een boog
    '#pf-menu { position: fixed; inset: 0; z-index: 2147483646; background: rgba(0,0,0,0); transition: background .2s; }' +
    '#pf-menu.pf-in { background: rgba(0,0,0,.6); }' +
    '#pf-menu .pf-lift { position: fixed; object-fit: cover; border-radius: 16px; pointer-events: none;' +
    '  box-shadow: 0 0 0 rgba(0,0,0,0); transition: transform .28s cubic-bezier(.2,.9,.3,1.2), box-shadow .28s; }' +
    '#pf-menu.pf-in .pf-lift { transform: scale(1.05) rotate(-2.5deg); box-shadow: 0 24px 60px rgba(0,0,0,.55); }' +
    '#pf-menu .pf-opt { position: fixed; width: 52px; height: 52px; margin: -26px 0 0 -26px; border-radius: 50%;' +
    '  background: rgba(28,28,28,.88); color: #fff; display: flex; align-items: center; justify-content: center;' +
    '  box-shadow: 0 4px 16px rgba(0,0,0,.35); transform: scale(.4); opacity: 0;' +
    '  transition: transform .22s cubic-bezier(.2,.9,.3,1.3), opacity .15s, background .12s, color .12s; }' +
    '#pf-menu.pf-in .pf-opt { transform: scale(1); opacity: 1; }' +
    '#pf-menu.pf-in .pf-opt.pf-hot { transform: scale(1.18); background: #fff; color: #111; }' +
    '#pf-menu .pf-opt svg { width: 24px; height: 24px; fill: currentColor; }' +
    '#pf-menu .pf-title { position: fixed; transform: translateX(-50%); color: #fff; opacity: 0;' +
    '  font: 700 22px -apple-system, sans-serif; text-shadow: 0 2px 10px rgba(0,0,0,.5); transition: opacity .12s; white-space: nowrap; }' +
    // Tijdens een actie het "…"-menu van Pinterest onzichtbaar houden
    'html.pf-quiet [role="dialog"], html.pf-quiet [aria-modal="true"] { opacity: 0 !important; }' +
    '#pf-toast { position: fixed; left: 50%; bottom: 60px; transform: translateX(-50%); z-index: 2147483647;' +
    '  max-width: 90vw; padding: 10px 14px; border-radius: 12px; background: rgba(0,0,0,.85); color: #fff;' +
    '  font: 13px -apple-system, sans-serif; white-space: pre-wrap; }';
  document.documentElement.appendChild(style);

  const toast = (text, ms = 2500) => {
    let t = document.getElementById('pf-toast');
    if (!t) { t = document.createElement('div'); t.id = 'pf-toast'; document.body.appendChild(t); }
    t.textContent = text;
    clearTimeout(t._timer);
    t._timer = setTimeout(() => t.remove(), ms);
  };

  const hideToast = () => { const t = document.getElementById('pf-toast'); if (t) t.remove(); };

  const native = (msg) => { try { webkit.messageHandlers.pfNative.postMessage(msg); } catch (e) {} };
  const haptic = () => native({ type: 'haptic' });
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // --- Pinterests eigen knoppen vinden ---

  const label = (el) => ((el.getAttribute('aria-label') || '') + ' ' + (el.textContent || '')).trim().toLowerCase();
  const isSave = (el) => /^(opslaan|save|bewaren)$/.test(label(el));
  const isLess = (el) => /^(see less|minder zien|minder hiervan)/.test(label(el));
  const visible = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const clickables = (root) => [...root.querySelectorAll('button, [role="button"], [role="menuitem"], [role="option"], a, div[tabindex]')];
  const outsideGrid = (el) => !el.closest('[data-grid-item]') && visible(el);

  // In volgorde van voorkeur; een omhulsel (bijv. een div met data-test-id) wordt vervangen door de knop erin
  const SAVE_SELECTORS = ['[data-test-id="closeup-save-button"]', '[data-test-id="PinBetterSaveButton"]',
    '[data-test-id="pin-save-button"]', '[data-test-id="save-button"]', '[aria-label="Save"]', '[aria-label="Opslaan"]'];
  const MENU_BUTTON_SELECTORS = ['[data-test-id="contextual-menu-button"]', '[aria-label="pin options" i]',
    '[aria-label="more options" i]', '[aria-label="meer opties" i]'];

  const asButton = (el) => el.matches('button, [role="button"]') ? el : (el.querySelector('button, [role="button"]') || el);

  // Eerste element dat past, per selector in volgorde van voorkeur
  const pick = (root, selectors, ok = () => true) => {
    for (const sel of selectors) {
      for (const el of root.querySelectorAll(sel)) { const b = asButton(el); if (ok(b)) return b; }
    }
    return null;
  };

  // Zoek op de pagina, maar niet in het raster met pins
  const findOutsideGrid = (selectors, test) =>
    pick(document, selectors, outsideGrid) || clickables(document).find((b) => outsideGrid(b) && test(b));

  const waitFor = async (fn, ms, step = 50) => {
    for (let t = 0; t < ms; t += step) { const el = fn(); if (el) return el; await sleep(step); }
    return null;
  };

  // Als iets niet lukt: laat zien welke knoppen er wél zijn, zodat het te repareren is
  const diagnose = (root, what) => {
    const found = clickables(root)
      .filter((b) => root !== document || outsideGrid(b))
      .map((b) => b.getAttribute('data-test-id') || b.getAttribute('aria-label') || (b.textContent || '').trim().slice(0, 24))
      .filter(Boolean);
    toast(what + ' niet gevonden. Maak een screenshot voor Claude:\n' + [...new Set(found)].slice(0, 30).join(' · '), 15000);
  };

  const pressButton = (el) => {
    const opts = { bubbles: true, cancelable: true, view: window };
    el.dispatchEvent(new PointerEvent('pointerdown', { ...opts, pointerType: 'touch' }));
    el.dispatchEvent(new MouseEvent('mousedown', opts));
    el.dispatchEvent(new PointerEvent('pointerup', { ...opts, pointerType: 'touch' }));
    el.dispatchEvent(new MouseEvent('mouseup', opts));
    el.click();
  };

  // Open de pin binnen Pinterest zelf (geen volledige herlaad), zodat "terug" naar het raster werkt
  const openPin = (item) => {
    const a = item.querySelector('a[href*="/pin/"]');
    if (!a) return false;
    a.click();
    return true;
  };

  const dialogOpen = () => [...document.querySelectorAll('[role="dialog"], [aria-modal="true"]')].some(visible);

  // Opties in Pinterests "…"-menu van een pin (zichtbaar in de diagnose als data-test-id)
  const SAVE_OPTION = ['[data-test-id="save-repin-menu-link"]'];
  const LESS_OPTION = ['[data-test-id="see-less-option"]'];
  const CLOSE_MENU = ['[aria-label="close context modal" i]'];

  // Opent het "…"-menu van de pin onzichtbaar en tikt op een optie daarin.
  // Geeft false terug als er geen "…"-knop is (dan kan de aanroeper iets anders proberen).
  // Tijdens een actie elke nieuwe laag die Pinterest bovenop de pagina zet (zoals het "…"-menu)
  // meteen onzichtbaar maken. Een MutationObserver reageert nog vóór de volgende schermverversing,
  // dus de laag komt nooit in beeld. Geeft een functie terug die alles weer zichtbaar maakt.
  const hideNewLayers = () => {
    const hidden = [];
    const isLayer = (n) => [n, ...n.querySelectorAll(':scope > *, :scope > * > *')].slice(0, 25)
      .some((e) => getComputedStyle(e).position === 'fixed');
    const observer = new MutationObserver((records) => {
      for (const r of records) {
        for (const n of r.addedNodes) {
          if (n.nodeType !== 1 || n.id === 'pf-menu' || n.id === 'pf-toast' || n.closest('[data-grid-item]')) continue;
          if (isLayer(n)) { hidden.push([n, n.style.opacity]); n.style.opacity = '0'; }
        }
      }
    });
    observer.observe(document.body, { childList: true, subtree: true });
    return () => {
      observer.disconnect();
      for (const [n, opacity] of hidden) n.style.opacity = opacity;
    };
  };

  // Buitenste "fixed" laag rond een element (het menu zelf), maar nooit iets waar de pin in zit
  const outerLayer = (el, item) => {
    let found = null;
    for (let e = el; e && e !== document.body; e = e.parentElement) {
      if (getComputedStyle(e).position === 'fixed') found = e;
    }
    return found && !found.contains(item) ? found : null;
  };

  const viaPinMenu = async (item, selectors, test, what) => {
    const menuBtn = pick(item, MENU_BUTTON_SELECTORS);
    if (!menuBtn) return false;
    const html = document.documentElement;
    html.classList.add('pf-quiet');
    const showLayers = hideNewLayers();
    let layer = null, layerOpacity = '';
    try {
      pressButton(menuBtn);
      const option = await waitFor(() => pick(document, selectors, visible) ||
                                         clickables(document).find((b) => outsideGrid(b) && test(b)), 2500);
      if (!option) {
        showLayers();
        html.classList.remove('pf-quiet');
        diagnose(document, what);
        return true;
      }
      // Zat het menu in een laag die er al was? Die dan ook onzichtbaar houden
      layer = outerLayer(option, item);
      if (layer) { layerOpacity = layer.style.opacity; layer.style.opacity = '0'; }

      pressButton(option);
      // Pas weer zichtbaar maken als Pinterests menu echt weg is (daarna komt bijv. de bordkeuze)
      await waitFor(() => !option.isConnected || !visible(option), 1500);
      await sleep(60);
      // Staat het menu nog open (optie sloot het niet zelf)? Dan netjes sluiten
      if (pick(document, selectors, visible)) {
        const close = pick(document, CLOSE_MENU, visible);
        if (close) { pressButton(close); await sleep(200); }
      }
      return true;
    } finally {
      if (layer) layer.style.opacity = layerOpacity;
      showLayers();
      html.classList.remove('pf-quiet');
    }
  };

  const actions = {
    // Save: via het "…"-menu, zodat de pin niet opengaat; Pinterest toont dan de bordkeuze
    async save(item) {
      if (await viaPinMenu(item, SAVE_OPTION, isSave, 'Save-optie')) return;

      // Terugval: pin openen, daar op Save drukken, en na de bordkeuze terug naar de feed
      const startURL = location.href;
      if (!openPin(item)) { diagnose(item, 'Link naar pin'); return; }
      toast('Save…', 6000);
      const btn = await waitFor(() => location.href !== startURL && findOutsideGrid(SAVE_SELECTORS, isSave), 6000);
      hideToast();
      if (!btn) { diagnose(document, 'Save-knop op de pinpagina'); return; }
      const pinURL = location.href;
      pressButton(btn);
      if (await waitFor(dialogOpen, 1500)) {
        await waitFor(() => !dialogOpen(), 180000, 200);
        await sleep(400);
      } else {
        await sleep(800);
      }
      if (location.href === pinURL) history.back();
    },

    // Hide: via het "…"-menu direct "See less" kiezen, zodat Pinterest er minder van laat zien
    async hide(item) {
      if (!(await viaPinMenu(item, LESS_OPTION, isLess, 'See less-optie'))) diagnose(item, '"…"-knop');
    }
  };

  // --- Het ronde menu ---

  // Icoontjes uit Googles Material-icoonset (Apache 2.0): punaise en doorgestreept oog
  const ICONS = {
    save: '<svg viewBox="0 0 24 24"><path d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"/></svg>',
    hide: '<svg viewBox="0 0 24 24"><path d="M12 7c2.76 0 5 2.24 5 5 0 .65-.13 1.26-.36 1.83l2.92 2.92c1.51-1.26 2.7-2.89 3.43-4.75-1.73-4.39-6-7.5-11-7.5-1.4 0-2.74.25-3.98.7l2.16 2.16C10.74 7.13 11.35 7 12 7zM2 4.27l2.28 2.28.46.46C3.08 8.3 1.78 10.02 1 12c1.73 4.39 6 7.5 11 7.5 1.55 0 3.03-.3 4.38-.84l.42.42L19.73 22 21 20.73 3.27 3 2 4.27zM7.53 9.8l1.55 1.55c-.05.21-.08.43-.08.65 0 1.66 1.34 3 3 3 .22 0 .44-.03.65-.08l1.55 1.55c-.67.33-1.41.53-2.2.53-2.76 0-5-2.24-5-5 0-.79.2-1.53.53-2.2zm4.31-.78l3.15 3.15.02-.16c0-1.66-1.34-3-3-3l-.17.01z"/></svg>'
  };
  const OPTIONS = [
    { key: 'save', text: 'Save' },
    { key: 'hide', text: 'Hide' }
  ];
  let menu = null;   // { el, item, opts: [{key, x, y, el, text}], hot, title }

  const openMenu = (item, x, y) => {
    native({ type: 'scroll', on: false });   // scrollen uit zolang het menu open is
    haptic();
    item.classList.remove('pf-press');
    const el = document.createElement('div');
    el.id = 'pf-menu';

    // Kopie van de pin-afbeelding die "opgetild" wordt
    const img = item.querySelector('img');
    if (img) {
      const r = img.getBoundingClientRect();
      const lift = document.createElement('img');
      lift.className = 'pf-lift';
      lift.src = img.currentSrc || img.src;
      Object.assign(lift.style, { left: r.left + 'px', top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
      el.appendChild(lift);
    }

    // Knoppen in een boog boven de vinger; bij de bovenrand eronder, bij de zijkant naar binnen
    const R = 80;
    const up = y > 170 ? -1 : 1;
    const side = x < 120 ? 1 : (x > innerWidth - 120 ? -1 : 0);
    const angles = side === 0 ? [-38, 38] : (side > 0 ? [15, 60] : [-60, -15]);
    const opts = OPTIONS.map((o, i) => {
      const a = angles[i] * Math.PI / 180;
      const ox = x + R * Math.sin(a), oy = y + up * R * Math.cos(a);
      const b = document.createElement('div');
      b.className = 'pf-opt';
      b.innerHTML = ICONS[o.key];
      b.style.left = ox + 'px'; b.style.top = oy + 'px';
      b.style.transitionDelay = (i * 35) + 'ms';
      el.appendChild(b);
      return { key: o.key, x: ox, y: oy, el: b, text: o.text };
    });

    // Label van de gekozen optie, boven de knoppen (of eronder als daar geen ruimte is)
    const title = document.createElement('div');
    title.className = 'pf-title';
    const topMost = Math.min(...opts.map((o) => o.y));
    const bottomMost = Math.max(...opts.map((o) => o.y));
    title.style.left = Math.min(Math.max(x, 60), innerWidth - 60) + 'px';
    title.style.top = (up < 0 ? Math.max(topMost - 72, 8) : bottomMost + 40) + 'px';
    el.appendChild(title);

    document.body.appendChild(el);
    requestAnimationFrame(() => requestAnimationFrame(() => el.classList.add('pf-in')));
    menu = { el, item, opts, hot: null, title };
  };

  const closeMenu = () => {
    if (menu) {
      const el = menu.el;
      el.classList.remove('pf-in');   // terug-animatie, daarna weghalen
      el.style.pointerEvents = 'none';
      setTimeout(() => el.remove(), 220);
      menu = null;
    }
    native({ type: 'scroll', on: true });
  };

  const setHot = (x, y) => {
    let hot = null;
    for (const o of menu.opts) if (Math.hypot(o.x - x, o.y - y) < 42) hot = o;
    if (hot !== menu.hot) {
      if (menu.hot) menu.hot.el.classList.remove('pf-hot');
      if (hot) { hot.el.classList.add('pf-hot'); haptic(); }
      menu.title.textContent = hot ? hot.text : '';
      menu.title.style.opacity = hot ? '1' : '0';
      menu.hot = hot;
    }
  };

  const run = (key, item) => {
    closeMenu();
    // Pas starten nadat het loslaten helemaal is afgehandeld, anders blokkeert
    // de klikblokkering hieronder ook de klik die de actie zelf doet
    setTimeout(() => actions[key](item).catch((e) => toast('Fout: ' + e)), 0);
  };

  // --- Aanraken ---
  // touchstart/touchmove zijn "passive": ze houden het scrollen nooit op. Alleen touchend mag
  // blokkeren, zodat loslaten op het menu niet ook nog de pin opent.

  let pending = null;       // { timer, x, y }
  let swallowClick = false; // voorkomt dat loslaten na het menu de pin opent

  // Indruk-effect pas na een korte vertraging, zodat het niet knippert als je gewoon scrolt
  let pressed = null, pressTimer = null;
  const pressStart = (item) => {
    pressEnd();
    pressTimer = setTimeout(() => { pressed = item; item.classList.add('pf-press'); }, 70);
  };
  const pressEnd = () => {
    clearTimeout(pressTimer);
    if (pressed) { pressed.classList.remove('pf-press'); pressed = null; }
  };

  // Pinterest heeft zelf ook een "lang indrukken"-menu. Zodra ons menu opengaat, vertellen we
  // Pinterest dat de aanraking is geannuleerd, zodat zijn eigen timer stopt.
  const cancelPageGesture = (target) => {
    try { target.dispatchEvent(new PointerEvent('pointercancel', { bubbles: true, pointerType: 'touch', isPrimary: true })); } catch (e) {}
    try {
      const ev = new Event('touchcancel', { bubbles: true, cancelable: false });
      for (const k of ['touches', 'targetTouches', 'changedTouches']) Object.defineProperty(ev, k, { value: [] });
      target.dispatchEvent(ev);
    } catch (e) {}
  };

  // Zolang ons menu open is, krijgt Pinterest de rest van de vingerbeweging niet te zien
  for (const type of ['pointermove', 'pointerup', 'pointerdown']) {
    document.addEventListener(type, (e) => { if (menu) e.stopPropagation(); }, true);
  }
  // Systeem-/paginamenu bij lang indrukken op een pin tegenhouden
  document.addEventListener('contextmenu', (e) => {
    if (menu || pending || (e.target.closest && e.target.closest('[data-grid-item]'))) { e.preventDefault(); e.stopPropagation(); }
  }, true);

  document.addEventListener('touchstart', (e) => {
    if (pending) { clearTimeout(pending.timer); pending = null; }
    if (e.touches.length !== 1) return;
    const t = e.touches[0];
    if (menu && !menu.el.isConnected) closeMenu();   // menu door de pagina weggehaald
    if (menu) {   // menu staat open en je tikt: optie kiezen of sluiten
      setHot(t.clientX, t.clientY);
      return;
    }
    const item = e.target.closest && e.target.closest('[data-grid-item]');
    if (!item) return;
    const x = t.clientX, y = t.clientY;
    const target = e.target;
    pressStart(item);
    pending = {
      x, y,
      timer: setTimeout(() => {
        pending = null;
        swallowClick = true;
        cancelPageGesture(target);
        pressEnd();
        openMenu(item, x, y);
      }, HOLD_MS)
    };
  }, { capture: true, passive: true });

  document.addEventListener('touchmove', (e) => {
    const t = e.touches[0];
    if (pending && Math.hypot(t.clientX - pending.x, t.clientY - pending.y) > MOVE_CANCEL) {
      clearTimeout(pending.timer); pending = null;   // gewoon scrollen
      pressEnd();
    }
    if (menu) { e.stopPropagation(); setHot(t.clientX, t.clientY); }
  }, { capture: true, passive: true });

  document.addEventListener('touchend', (e) => {
    if (pending) { clearTimeout(pending.timer); pending = null; }
    setTimeout(pressEnd, 60);   // heel even laten staan, zodat een snelle tik ook zichtbaar veert
    if (!menu) return;
    e.preventDefault();
    e.stopPropagation();
    if (menu.hot) run(menu.hot.key, menu.item);
    else if (!swallowClick) closeMenu();   // tik naast de opties: sluiten
    swallowClick = false;                  // na eerste keer loslaten blijft het menu open voor tikken
  }, { capture: true, passive: false });

  document.addEventListener('touchcancel', () => {
    if (pending) { clearTimeout(pending.timer); pending = null; }
    pressEnd();
  }, { capture: true, passive: true });

  // Klik die bij het loslaten hoort niet doorgeven aan de pin
  document.addEventListener('click', (e) => {
    if (menu || swallowClick) { e.preventDefault(); e.stopPropagation(); }
  }, true);
})();
"""#

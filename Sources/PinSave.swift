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
    private let generator = UIImpactFeedbackGenerator(style: .medium)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "haptic":
            generator.impactOccurred()
        case "scroll":
            webView?.scrollView.isScrollEnabled = (body["on"] as? Bool) ?? true
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
    '#pf-menu { position: fixed; inset: 0; z-index: 2147483646; background: rgba(0,0,0,.25); }' +
    '#pf-menu .pf-opt { position: fixed; width: 64px; height: 64px; margin: -32px 0 0 -32px; border-radius: 50%;' +
    '  background: #fff; color: #111; display: flex; align-items: center; justify-content: center; font-size: 26px;' +
    '  box-shadow: 0 4px 14px rgba(0,0,0,.3); transition: transform .12s, background .12s; }' +
    '#pf-menu .pf-opt.pf-hot { transform: scale(1.2); background: #111; color: #fff; }' +
    '#pf-menu .pf-label { position: fixed; transform: translateX(-50%); padding: 4px 10px; border-radius: 10px;' +
    '  background: #111; color: #fff; font: 600 14px -apple-system, sans-serif; white-space: nowrap; }' +
    '#pf-menu .pf-dot { position: fixed; width: 44px; height: 44px; margin: -22px 0 0 -22px; border-radius: 50%;' +
    '  border: 3px solid #fff; box-shadow: 0 0 8px rgba(0,0,0,.4); }' +
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
  const viaPinMenu = async (item, selectors, test, what) => {
    const menuBtn = pick(item, MENU_BUTTON_SELECTORS);
    if (!menuBtn) return false;
    const html = document.documentElement;
    html.classList.add('pf-quiet');
    try {
      pressButton(menuBtn);
      const option = await waitFor(() => pick(document, selectors, visible) ||
                                         clickables(document).find((b) => outsideGrid(b) && test(b)), 2500);
      if (!option) {
        html.classList.remove('pf-quiet');
        diagnose(document, what);
        return true;
      }
      pressButton(option);
      await sleep(250);
      // Staat het menu nog open (optie sloot het niet zelf)? Dan netjes sluiten
      if (pick(document, selectors, visible)) {
        const close = pick(document, CLOSE_MENU, visible);
        if (close) pressButton(close);
      }
      return true;
    } finally {
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

  const OPTIONS = [
    { key: 'save', icon: '📌', text: 'Save' },
    { key: 'hide', icon: '🚫', text: 'Hide' }
  ];
  let menu = null;   // { el, item, opts: [{key, x, y, el, labelEl}], hot }

  const openMenu = (item, x, y) => {
    native({ type: 'scroll', on: false });   // scrollen uit zolang het menu open is
    haptic();
    const el = document.createElement('div');
    el.id = 'pf-menu';
    const dot = document.createElement('div');
    dot.className = 'pf-dot'; dot.style.left = x + 'px'; dot.style.top = y + 'px';
    el.appendChild(dot);

    // Opties in een boog boven de vinger; bij de bovenrand eronder, bij de zijkant naar binnen
    const R = 95;
    const up = y > 180 ? -1 : 1;
    const side = x < 140 ? 1 : (x > innerWidth - 140 ? -1 : 0);
    const angles = side === 0 ? [-35, 35] : (side > 0 ? [10, 55] : [-55, -10]);
    const opts = OPTIONS.map((o, i) => {
      const a = angles[i] * Math.PI / 180;
      const ox = x + R * Math.sin(a), oy = y + up * R * Math.cos(a);
      const b = document.createElement('div');
      b.className = 'pf-opt'; b.textContent = o.icon;
      b.style.left = ox + 'px'; b.style.top = oy + 'px';
      const l = document.createElement('div');
      l.className = 'pf-label'; l.textContent = o.text;
      l.style.left = ox + 'px'; l.style.top = (oy + (up < 0 ? -62 : 40)) + 'px';
      l.style.visibility = 'hidden';
      el.appendChild(b); el.appendChild(l);
      return { key: o.key, x: ox, y: oy, el: b, labelEl: l };
    });
    document.body.appendChild(el);
    menu = { el, item, opts, hot: null };
  };

  const closeMenu = () => {
    if (menu) { menu.el.remove(); menu = null; }
    native({ type: 'scroll', on: true });
  };

  const setHot = (x, y) => {
    let hot = null;
    for (const o of menu.opts) if (Math.hypot(o.x - x, o.y - y) < 45) hot = o;
    if (hot !== menu.hot) {
      if (menu.hot) { menu.hot.el.classList.remove('pf-hot'); menu.hot.labelEl.style.visibility = 'hidden'; }
      if (hot) { hot.el.classList.add('pf-hot'); hot.labelEl.style.visibility = 'visible'; haptic(); }
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
    pending = {
      x, y,
      timer: setTimeout(() => { pending = null; swallowClick = true; openMenu(item, x, y); }, HOLD_MS)
    };
  }, { capture: true, passive: true });

  document.addEventListener('touchmove', (e) => {
    const t = e.touches[0];
    if (pending && Math.hypot(t.clientX - pending.x, t.clientY - pending.y) > MOVE_CANCEL) {
      clearTimeout(pending.timer); pending = null;   // gewoon scrollen
    }
    if (menu) setHot(t.clientX, t.clientY);
  }, { capture: true, passive: true });

  document.addEventListener('touchend', (e) => {
    if (pending) { clearTimeout(pending.timer); pending = null; }
    if (!menu) return;
    e.preventDefault();
    if (menu.hot) run(menu.hot.key, menu.item);
    else if (!swallowClick) closeMenu();   // tik naast de opties: sluiten
    swallowClick = false;                  // na eerste keer loslaten blijft het menu open voor tikken
  }, { capture: true, passive: false });

  document.addEventListener('touchcancel', () => {
    if (pending) { clearTimeout(pending.timer); pending = null; }
  }, { capture: true, passive: true });

  // Klik die bij het loslaten hoort niet doorgeven aan de pin
  document.addEventListener('click', (e) => {
    if (menu || swallowClick) { e.preventDefault(); e.stopPropagation(); }
  }, true);
})();
"""#

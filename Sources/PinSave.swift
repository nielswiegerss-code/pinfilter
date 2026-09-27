import UIKit
import WebKit

// Lang indrukken op een pin opent een rond menu, zoals in de Pinterest-app. Het menu zelf wordt
// door de app getekend (LongPressMenu.swift); dit script voert de gekozen actie uit.
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
  const MOVE_CANCEL = 10;   // zoveel pixels bewegen = scrollen, geen indrukken

  // iOS-"afbeelding bewaren" en tekstselectie uitzetten op pins (erft door naar alles erin)
  const style = document.createElement('style');
  style.textContent =
    '[data-grid-item] { -webkit-touch-callout: none !important; -webkit-user-select: none !important; user-select: none !important; }' +
    // Indruk-effect: de pin veert iets in zolang je hem aanraakt
    '[data-grid-item] > * { transition: transform .2s cubic-bezier(.2,.8,.3,1); }' +
    '[data-grid-item].pf-press > * { transform: scale(.96); }' +
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

  // --- Samenwerking met het lang-indrukken-menu van de app (LongPressMenu.swift) ---
  // De app tekent het menu zelf en volgt de vinger. Hier alleen: welke pin zit onder de vinger,
  // Pinterest de aanraking afpakken, en de gekozen actie uitvoeren.

  let menuItem = null;      // pin waarvoor het menu open is
  let menuTouch = false;    // de aanraking die het menu opende loopt nog: niet aan Pinterest geven
  let swallowClick = false; // een tik direct na het menu niet als "pin openen" laten tellen

  // Pinterest heeft zelf ook een "lang indrukken"-menu: vertel het dat de aanraking is geannuleerd
  const cancelPageGesture = (target) => {
    try { target.dispatchEvent(new PointerEvent('pointercancel', { bubbles: true, pointerType: 'touch', isPrimary: true })); } catch (e) {}
    try {
      const ev = new Event('touchcancel', { bubbles: true, cancelable: false });
      for (const k of ['touches', 'targetTouches', 'changedTouches']) Object.defineProperty(ev, k, { value: [] });
      target.dispatchEvent(ev);
    } catch (e) {}
  };

  const releaseSoon = () => setTimeout(() => { swallowClick = false; }, 400);

  // De app vraagt: zit er een pin op dit punt (in punten van de webview)? Zo ja: waar staat de afbeelding?
  window.__pfMenuAt = (x, y) => {
    const s = (window.visualViewport && visualViewport.scale) || 1;
    const el = document.elementFromPoint(x / s, y / s);
    const item = el && el.closest && el.closest('[data-grid-item]');
    const img = item && item.querySelector('img');
    if (!img) return '';
    menuItem = item;
    menuTouch = true;
    swallowClick = true;
    pressEnd();
    cancelPageGesture(el);
    const r = img.getBoundingClientRect();
    return JSON.stringify({ x: r.left * s, y: r.top * s, w: r.width * s, h: r.height * s });
  };

  window.__pfMenuClose = () => { menuItem = null; menuTouch = false; releaseSoon(); return 'ok'; };

  window.__pfRun = (key) => {
    const item = menuItem;
    menuItem = null;
    menuTouch = false;
    releaseSoon();
    if (item && actions[key]) setTimeout(() => actions[key](item).catch((e) => toast('Fout: ' + e)), 0);
    return 'ok';
  };

  // --- Aanraken: alleen nog het indruk-effect en het afschermen van Pinterest ---
  // touchstart/touchmove zijn "passive": ze houden het scrollen nooit op.

  let pressed = null, pressTimer = null, startX = 0, startY = 0;
  const pressEnd = () => {
    clearTimeout(pressTimer);
    if (pressed) { pressed.classList.remove('pf-press'); pressed = null; }
  };
  // Indruk-effect pas na een korte vertraging, zodat het niet knippert als je gewoon scrolt
  const pressStart = (item) => {
    pressEnd();
    pressTimer = setTimeout(() => { pressed = item; item.classList.add('pf-press'); }, 70);
  };

  document.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 1) { pressEnd(); return; }
    const t = e.touches[0];
    const item = e.target.closest && e.target.closest('[data-grid-item]');
    if (!item) return;
    startX = t.clientX; startY = t.clientY;
    pressStart(item);
  }, { capture: true, passive: true });

  document.addEventListener('touchmove', (e) => {
    if (menuTouch) { e.stopPropagation(); return; }
    const t = e.touches[0];
    if (t && Math.hypot(t.clientX - startX, t.clientY - startY) > MOVE_CANCEL) pressEnd();
  }, { capture: true, passive: true });

  document.addEventListener('touchend', (e) => {
    setTimeout(pressEnd, 60);   // heel even laten staan, zodat een snelle tik ook zichtbaar veert
    if (menuTouch) { menuTouch = false; e.preventDefault(); e.stopPropagation(); }
  }, { capture: true, passive: false });

  document.addEventListener('touchcancel', (e) => {
    pressEnd();
    if (e.isTrusted) menuTouch = false;
  }, { capture: true, passive: true });

  // Zolang het menu open is, krijgt Pinterest de vingerbeweging niet te zien
  for (const type of ['pointermove', 'pointerup', 'pointerdown']) {
    document.addEventListener(type, (e) => { if (menuTouch) e.stopPropagation(); }, true);
  }
  // Systeem-/paginamenu bij lang indrukken op een pin tegenhouden
  document.addEventListener('contextmenu', (e) => {
    if (menuTouch || (e.target.closest && e.target.closest('[data-grid-item]'))) { e.preventDefault(); e.stopPropagation(); }
  }, true);

  // Een echte tik direct na het menu niet doorgeven (klikken van onze eigen acties wel)
  document.addEventListener('click', (e) => {
    if (swallowClick && e.isTrusted) { e.preventDefault(); e.stopPropagation(); }
  }, true);
})();
"""#

import UIKit
import WebKit

// Lang indrukken op een pin opent een rond menu, zoals in de Pinterest-app.
// Sleep naar een optie en laat los (of tik erop). Het opslaan gebruikt Pinterests eigen
// "Opslaan"-knop: we laten de pin denken dat de muis erboven hangt en klikken dan op die knop.

// Trilt kort als het menu verschijnt (aangeroepen vanuit JavaScript)
final class HapticHandler: NSObject, WKScriptMessageHandler {
    private let generator = UIImpactFeedbackGenerator(style: .medium)

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        generator.impactOccurred()
    }
}

let pinSaveJS = #"""
(() => {
  'use strict';
  const HOLD_MS = 450;      // hoe lang indrukken voordat het menu verschijnt
  const MOVE_CANCEL = 10;   // zoveel pixels bewegen = scrollen, geen lang indrukken

  // iOS-linkvoorbeeld, "afbeelding bewaren" en tekstselectie uitzetten op pins
  const style = document.createElement('style');
  style.textContent =
    '[data-grid-item], [data-grid-item] * { -webkit-touch-callout: none !important; -webkit-user-select: none !important; user-select: none !important; }' +
    '#pf-menu { position: fixed; inset: 0; z-index: 2147483646; background: rgba(0,0,0,.25); }' +
    '#pf-menu .pf-opt { position: fixed; width: 64px; height: 64px; margin: -32px 0 0 -32px; border-radius: 50%;' +
    '  background: #fff; color: #111; display: flex; align-items: center; justify-content: center; font-size: 26px;' +
    '  box-shadow: 0 4px 14px rgba(0,0,0,.3); transition: transform .12s, background .12s; }' +
    '#pf-menu .pf-opt.pf-hot { transform: scale(1.2); background: #111; color: #fff; }' +
    '#pf-menu .pf-label { position: fixed; transform: translateX(-50%); padding: 4px 10px; border-radius: 10px;' +
    '  background: #111; color: #fff; font: 600 14px -apple-system, sans-serif; white-space: nowrap; }' +
    '#pf-menu .pf-dot { position: fixed; width: 44px; height: 44px; margin: -22px 0 0 -22px; border-radius: 50%;' +
    '  border: 3px solid #fff; box-shadow: 0 0 8px rgba(0,0,0,.4); }' +
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

  const haptic = () => { try { webkit.messageHandlers.pfHaptic.postMessage(1); } catch (e) {} };
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // --- Pinterests eigen knoppen tevoorschijn halen en vinden ---

  // Laat React denken dat de muis boven de pin hangt, zodat de hover-knoppen verschijnen
  const hover = (item) => {
    const target = item.querySelector('a[href*="/pin/"]') || item;
    const r = target.getBoundingClientRect();
    const opts = { bubbles: true, cancelable: true, clientX: r.left + r.width / 2, clientY: r.top + r.height / 2, view: window };
    for (const el of [item, target]) {
      el.dispatchEvent(new PointerEvent('pointerover', { ...opts, pointerType: 'mouse' }));
      el.dispatchEvent(new PointerEvent('pointerenter', { ...opts, pointerType: 'mouse', bubbles: false }));
      el.dispatchEvent(new MouseEvent('mouseover', opts));
      el.dispatchEvent(new MouseEvent('mouseenter', { ...opts, bubbles: false }));
      el.dispatchEvent(new MouseEvent('mousemove', opts));
    }
  };
  const unhover = (item) => {
    const opts = { bubbles: true, view: window };
    item.dispatchEvent(new MouseEvent('mouseout', opts));
    item.dispatchEvent(new MouseEvent('mouseleave', { ...opts, bubbles: false }));
    item.dispatchEvent(new PointerEvent('pointerout', { ...opts, pointerType: 'mouse' }));
  };

  const label = (el) => ((el.getAttribute('aria-label') || '') + ' ' + (el.textContent || '')).trim().toLowerCase();

  const findSaveButton = (item) => {
    const direct = item.querySelector(
      '[data-test-id="PinBetterSaveButton"], [data-test-id="pin-save-button"], [data-test-id="save-button"],' +
      '[aria-label="Opslaan"], [aria-label="Save"]');
    if (direct) return direct;
    return [...item.querySelectorAll('button, [role="button"]')]
      .find((b) => /^(opslaan|save)$/.test(label(b)));
  };

  const findBoardDropdown = (item) => {
    const direct = item.querySelector(
      '[data-test-id="board-dropdown-select-button"], [data-test-id="boardSelectionDropdown"],' +
      '[data-test-id="board-dropdown"], [data-test-id="PinBetterSaveDropdown"]');
    if (direct) return direct;
    return [...item.querySelectorAll('button, [role="button"]')]
      .find((b) => /bord|board/.test(label(b)) && !/^(opslaan|save)$/.test(label(b)));
  };

  // Wacht tot een knop verschijnt (Pinterest tekent hover-knoppen pas na de hover)
  const waitFor = async (fn, ms = 1200) => {
    for (let t = 0; t < ms; t += 100) { const el = fn(); if (el) return el; await sleep(100); }
    return null;
  };

  // Als iets niet lukt: laat zien welke knoppen er wél zijn, zodat het te repareren is
  const diagnose = (item, what) => {
    const found = [...item.querySelectorAll('button, [role="button"], [data-test-id]')]
      .map((b) => b.getAttribute('data-test-id') || b.getAttribute('aria-label') || (b.textContent || '').trim().slice(0, 20))
      .filter(Boolean);
    toast(what + ' niet gevonden. Maak een screenshot voor Claude:\n' + [...new Set(found)].slice(0, 25).join(' · '), 12000);
  };

  const pressButton = (el) => {
    const opts = { bubbles: true, cancelable: true, view: window };
    el.dispatchEvent(new PointerEvent('pointerdown', { ...opts, pointerType: 'mouse' }));
    el.dispatchEvent(new MouseEvent('mousedown', opts));
    el.dispatchEvent(new PointerEvent('pointerup', { ...opts, pointerType: 'mouse' }));
    el.dispatchEvent(new MouseEvent('mouseup', opts));
    el.click();
  };

  const actions = {
    async save(item) {
      hover(item);
      const btn = await waitFor(() => findSaveButton(item));
      if (!btn) { diagnose(item, 'Opslaan-knop'); return; }
      pressButton(btn);
      setTimeout(() => unhover(item), 1500);
    },
    async board(item) {
      hover(item);
      const dd = await waitFor(() => findBoardDropdown(item));
      if (dd) { pressButton(dd); return; }
      // Geen bordkeuze in het raster: open de pin, daar kun je een bord kiezen
      const a = item.querySelector('a[href*="/pin/"]');
      if (a) location.href = a.href; else diagnose(item, 'Bordkeuze');
    }
  };

  // --- Het ronde menu ---

  const OPTIONS = [
    { key: 'save', icon: '📌', text: 'Opslaan' },
    { key: 'board', icon: '🗂️', text: 'Bord kiezen' }
  ];
  let menu = null;   // { el, item, opts: [{key, x, y, el, labelEl}], hot }

  const openMenu = (item, x, y) => {
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

  const closeMenu = () => { if (menu) { menu.el.remove(); menu = null; } };

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
    actions[key](item).catch((e) => toast('Fout: ' + e));
  };

  // --- Aanraken ---

  let pending = null;       // { timer, x, y, item }
  let swallowClick = false; // voorkomt dat loslaten na het menu de pin opent

  document.addEventListener('touchstart', (e) => {
    if (e.touches.length !== 1) { if (pending) clearTimeout(pending.timer); pending = null; return; }
    const t = e.touches[0];
    if (menu && !menu.el.isConnected) menu = null;   // menu door de pagina weggehaald
    if (menu) {   // menu staat open en je tikt: optie kiezen of sluiten
      setHot(t.clientX, t.clientY);
      return;
    }
    if (pending) { clearTimeout(pending.timer); pending = null; }
    const item = e.target.closest && e.target.closest('[data-grid-item]');
    if (!item) return;
    const x = t.clientX, y = t.clientY;
    pending = {
      x, y, item,
      timer: setTimeout(() => { pending = null; swallowClick = true; openMenu(item, x, y); }, HOLD_MS)
    };
  }, { capture: true, passive: true });

  document.addEventListener('touchmove', (e) => {
    const t = e.touches[0];
    if (pending && Math.hypot(t.clientX - pending.x, t.clientY - pending.y) > MOVE_CANCEL) {
      clearTimeout(pending.timer); pending = null;   // gewoon scrollen
    }
    if (menu) { e.preventDefault(); setHot(t.clientX, t.clientY); }
  }, { capture: true, passive: false });

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

import Foundation

// Kleine aanpassingen aan Pinterests pagina-indeling.
// - De inbox-knop (berichten en meldingen) in de balk onderin verbergen.
let pageTweaksJS = #"""
(() => {
  'use strict';
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

  // Pinterest bouwt de balk later op en ververst hem af en toe. Nakijken bij veranderingen,
  // maar hooguit twee keer per seconde, zodat scrollen er niet trager van wordt.
  let queued = false;
  const schedule = () => {
    if (queued || (hidden && hidden.isConnected)) return;
    queued = true;
    setTimeout(() => { queued = false; hideInbox(); }, 500);
  };
  new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true });
  window.addEventListener('resize', schedule);
  hideInbox();
})();
"""#

// Regressietest van het advertentiefilter (adFilterJS in Sources/ContentView.swift).
// Draait het script in een node-vm met nagebootste browser-objecten (document, XMLHttpRequest, Response)
// en controleert dat advertenties verdwijnen en gewone pins blijven staan.
// Gebruik: node scripts/test_adfilter.js <pad/naar/adfilter.js>   (check_js.py doet dat voor je)
'use strict';
const fs = require('fs');
const vm = require('vm');

const file = process.argv[2];
if (!file) { console.error('Gebruik: node test_adfilter.js <adfilter.js>'); process.exit(2); }
const code = fs.readFileSync(file, 'utf8');

let failed = 0, passed = 0;
const check = (name, ok, extra) => {
  if (ok) { passed++; console.log('  ok     ' + name); }
  else { failed++; console.log('FOUT   ' + name + (extra ? '\n         ' + extra : '')); }
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

// Een verse omgeving per test, zodat de teller en de JSON.parse-omleiding niet doorlekken
function makeEnv() {
  const listeners = {};
  const appended = [];
  const document = {
    body: null,
    addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
    createElement() { return { style: {}, textContent: '' }; },
  };
  class XMLHttpRequest {}
  Object.defineProperty(XMLHttpRequest.prototype, 'response', {
    configurable: true, enumerable: true, get() { return this._r; },
  });
  class Response {
    constructor(t) { this._t = t; }
    text() { return Promise.resolve(this._t); }
  }
  const ctx = vm.createContext({ document, XMLHttpRequest, Response, console });
  vm.runInContext(code, ctx, { filename: 'adfilter.js' });
  return { ctx, document, listeners, appended, XMLHttpRequest, Response,
           parse: (text, reviver) => vm.runInContext('JSON.parse', ctx)(text, reviver) };
}

const normal = (id) => ({ id: String(id), type: 'pin', title: 'gewone pin ' + id, is_promoted: false,
                          promoter: null, adData: null, pinPromotionId: null, pin_promotion_id: null });

// De verschillende manieren waarop Pinterest een advertentie markeert
const AD_VARIANTS = {
  'pin_promotion_id':            { id: 'ad', pin_promotion_id: '5551234' },
  'is_promoted: true':           { id: 'ad', is_promoted: true },
  'isPromoted: true':            { id: 'ad', isPromoted: true },
  'pinPromotionId':              { id: 'ad', pinPromotionId: '5551234' },
  'promoter (object)':           { id: 'ad', promoter: { id: '77', name: 'Adverteerder' } },
  'is_downstream_promotion':     { id: 'ad', is_downstream_promotion: true },
  'isDownstreamPromotion':       { id: 'ad', isDownstreamPromotion: true },
  'adData (object)':             { id: 'ad', adData: { campaign: 1 } },
  'ad_data (object)':            { id: 'ad', ad_data: { campaign: 1 } },
  'via .node (GraphQL-edge)':    { node: { id: 'ad', isPromoted: true } },
  'via .node met promoter':      { node: { id: 'ad', promoter: { id: '1' } } },
};

console.log('Advertenties uit lijsten:');
for (const [name, ad] of Object.entries(AD_VARIANTS)) {
  const { parse } = makeEnv();
  const doc = { data: { pins: [normal(1), ad, normal(2)] }, nested: { a: [{ b: [ad, normal(3)] }] } };
  const out = parse(JSON.stringify(doc));
  check(name + ': advertentie weg, gewone pins blijven',
    same(out.data.pins, [normal(1), normal(2)]) && same(out.nested.a[0].b, [normal(3)]),
    'kreeg ' + JSON.stringify(out));
}

console.log('Advertenties uit lijsten op pin-ID:');
{
  const { parse } = makeEnv();
  const doc = { pins: { '111': { id: '111', is_promoted: true }, '222': normal(222),
                        '333': { node: { id: '333', pinPromotionId: '9' } }, name: { title: 'x' } } };
  const out = parse(JSON.stringify(doc));
  check('map op pin-ID: advertenties weg, gewone pin en andere sleutels blijven',
    same(Object.keys(out.pins), ['222', 'name']) && same(out.pins['222'], normal(222)), 'kreeg ' + JSON.stringify(out));
}

console.log('Gewone pins blijven ongemoeid:');
{
  const { parse } = makeEnv();
  // De advertentie zorgt dat het filter draait; de gewone pins hebben allerlei "nee"-waarden
  const pins = [normal(1), normal(2), { id: '3', promoter: null, isPromoted: false, sponsorship: { name: 'partner' } }];
  const out = parse(JSON.stringify({ items: [...pins, AD_VARIANTS['is_promoted: true']] }));
  check('null/false-markeringen en sponsorship worden niet weggehaald', same(out.items, pins), 'kreeg ' + JSON.stringify(out));
}
{
  const { parse } = makeEnv();
  const text = JSON.stringify({ items: [normal(1), normal(2)] });
  check('tekst zonder advertentiemarkeringen komt ongewijzigd terug', same(parse(text), JSON.parse(text)));
  const out = parse('{"a":1,"b":[2]}', (k, v) => (typeof v === 'number' ? v + 1 : v));
  check('reviver blijft werken', out.a === 2 && out.b[0] === 3);
  let threw = false;
  try { parse('{kapot'); } catch (e) { threw = true; }
  check('ongeldige JSON geeft nog steeds een fout', threw);
}

console.log('Andere routes (fetch, XMLHttpRequest, teller):');
(async () => {
  {
    const env = makeEnv();
    const r = new env.Response(JSON.stringify({ pins: [normal(1), AD_VARIANTS['isPromoted: true'], normal(2)] }));
    const out = await r.json();
    check('Response.json(): advertentie weg', same(out.pins, [normal(1), normal(2)]), 'kreeg ' + JSON.stringify(out));
  }
  {
    const env = makeEnv();
    const x = new env.XMLHttpRequest();
    x.responseType = 'json';
    x._r = { pins: [normal(1), AD_VARIANTS['promoter (object)'], normal(2)] };
    check('XMLHttpRequest (responseType json): advertentie weg', same(x.response.pins, [normal(1), normal(2)]),
      'kreeg ' + JSON.stringify(x.response));
    const y = new env.XMLHttpRequest();
    y.responseType = 'text';
    y._r = 'tekst';
    check('XMLHttpRequest met andere responseType blijft ongewijzigd', y.response === 'tekst');
  }
  {
    const env = makeEnv();
    const body = { children: [], appendChild(el) { this.children.push(el); } };
    env.document.body = body;
    env.parse(JSON.stringify({ a: [AD_VARIANTS['is_promoted: true'], AD_VARIANTS['isDownstreamPromotion'], normal(1)] }));
    const badge = body.children[0];
    check('teller linksonder telt 2 weggehaalde advertenties',
      !!badge && badge.textContent === 'Advertenties weggefilterd: 2', 'badge = ' + JSON.stringify(badge && badge.textContent));
    check('DOMContentLoaded-listener is geregistreerd', (env.listeners['DOMContentLoaded'] || []).length === 1);
  }

  console.log(`\nAdvertentiefilter: ${passed} ok, ${failed} fout`);
  process.exit(failed ? 1 : 0);
})().catch((e) => { console.error('FOUT in de test zelf:', e); process.exit(1); });

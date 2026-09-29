import SwiftUI
import WebKit

// Aantal kolommen in liggende stand: 5 is Pinterests eigen keuze, 4 geeft grotere pins zoals in de app.
//
// Hoe het werkt: via de viewport-instelling van de pagina zeggen we "het scherm is smaller"
// (1180 / 1.25 = 944 breed). Pinterest bouwt daar zelf 4 kolommen voor, en iOS schaalt het
// scherp op naar de volle breedte. (Inzoomen met de app zelf werkte niet: Pinterest bleef dan
// voor de oude breedte bouwen, met overlappende pins als gevolg.)
// Op een geopende pin geldt Pinterests eigen viewport-regel (breedte = venster), zie columnsJS.
@MainActor
final class ColumnSetting: ObservableObject {
    static let shared = ColumnSetting()

    @Published private(set) var columns: Int
    weak var webView: WKWebView? {
        didSet { observeURL() }
    }
    private var urlObservation: NSKeyValueObservation?

    private init() {
        columns = UserDefaults.standard.integer(forKey: "columns") == 5 ? 5 : 4
    }

    // Hoeveel de pagina liggend wordt opgeschaald
    var zoomFactor: Double { columns == 4 ? 1.25 : 1.0 }

    func toggle() {
        columns = columns == 4 ? 5 : 4
        UserDefaults.standard.set(columns, forKey: "columns")
        // Direct in de open pagina omschakelen; alleen als dat niet lukt opslaan en herladen
        let zoom = zoomFactor
        webView?.evaluateJavaScript("window.__pfSetZoom ? window.__pfSetZoom(\(zoom)) : ''") { [weak self] result, _ in
            guard (result as? String) != "ok" else { return }
            self?.webView?.evaluateJavaScript("localStorage.setItem('pfZoom', '\(zoom)')") { _, _ in
                self?.webView?.reload()
            }
        }
    }

    // De app is de enige waarheid over het aantal kolommen. De pagina onthoudt het in localStorage
    // (per adres) en kent verder alleen de waarde van het opstarten. Wisselt Pinterest van adres
    // (nl. naar www., of via inloggen), dan zetten we de pagina hier weer gelijk met de app.
    private func observeURL() {
        urlObservation = webView?.observe(\.url) { [weak self] _, _ in
            Task { @MainActor in self?.syncPage() }
        }
    }

    private func syncPage() {
        webView?.evaluateJavaScript("window.__pfSetZoom && window.__pfSetZoom(\(zoomFactor))", completionHandler: nil)
    }

    // Script dat de viewport-instelling van Pinterest steeds overschrijft
    var script: WKUserScript {
        WKUserScript(source: "const PF_APP_ZOOM = \(zoomFactor);\n" + columnsJS,
                     injectionTime: .atDocumentStart,
                     forMainFrameOnly: true)
    }
}

// Knopje rechtsonder (alleen liggend) om te wisselen tussen 4 en 5 kolommen.
// Verborgen extra: lang indrukken toont een analyse van de pagina (voor Claude, om de layout aan te passen).
struct ColumnButton: View {
    @ObservedObject var setting = ColumnSetting.shared
    @State private var report: String?

    var body: some View {
        Label("\(setting.columns) kolommen", systemImage: "square.grid.3x3")
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .contentShape(Capsule())
            .onTapGesture { setting.toggle() }
            .onLongPressGesture(minimumDuration: 0.8) {
                Task { report = await PageReport.make(webView: setting.webView) }
            }
            .padding(12)
            .reportSheet($report)
    }
}

// Klein, bijna onzichtbaar vlak (44 pt) waarmee de pagina-analyse in elke stand en op elke pagina
// te openen is (lang indrukken, 0,8 s), ook staand en op een geopende pin waar de kolommenknop
// ontbreekt. Plaats het in een hoek waar Pinterest zelf niets heeft.
struct ReportHotspot: View {
    @State private var report: String?

    var body: some View {
        Color.clear
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.8) {
                Task { report = await PageReport.make(webView: ColumnSetting.shared.webView) }
            }
            .reportSheet($report)
    }
}

extension View {
    // Toont de pagina-analyse als sheet zolang `report` gevuld is
    func reportSheet(_ report: Binding<String?>) -> some View {
        sheet(isPresented: Binding(get: { report.wrappedValue != nil }, set: { if !$0 { report.wrappedValue = nil } })) {
            NavigationStack {
                ScrollView {
                    Text(report.wrappedValue ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Pagina-analyse")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Sluit") { report.wrappedValue = nil } }
                }
            }
        }
    }
}

// Overzicht van hoe de huidige pagina is opgebouwd. Bovenaan staat een OORDEEL (eerste regel die past),
// zodat één screenshot genoeg is om een afgesneden pin te duiden: viewport niet goed, zoom, iets buiten
// het scherm, afgeknipt door een ouder, of zijwaarts scrollbaar. Daaronder de gegevens waarop dat
// gebaseerd is, een korte gebeurtenissenlijst en de blokken met een data-test-id (Pinterests eigen namen).
@MainActor
enum PageReport {
    static func make(webView: WKWebView?) async -> String {
        guard let webView else { return "Geen webview" }
        let sv = webView.scrollView
        let window = webView.window
        let screen = window?.windowScene?.screen.bounds ?? .zero
        let winSize = window?.bounds.size ?? .zero
        // Staat de app niet schermvullend (iPadOS-venster, Split View), dan wijkt het venster af van het scherm
        let fullScreen = abs(winSize.width - screen.width) < 1 && abs(winSize.height - screen.height) < 1
        let inset = sv.adjustedContentInset
        let safe = webView.safeAreaInsets
        var native: [String] = []
        native.append(String(format: "app: venster %.0fx%.0f  scherm %.0fx%.0f  %@  webview %.0fx%.0f",
                             winSize.width, winSize.height, screen.width, screen.height,
                             fullScreen ? "schermvullend" : "NIET schermvullend",
                             webView.bounds.width, webView.bounds.height))
        native.append(String(format: "app: zoom %.2f (min %.2f max %.2f)  offset %.0f,%.0f  inhoud %.0fx%.0f  sleept %@",
                             sv.zoomScale, sv.minimumZoomScale, sv.maximumZoomScale,
                             sv.contentOffset.x, sv.contentOffset.y, sv.contentSize.width, sv.contentSize.height,
                             sv.isDragging ? "ja" : "nee"))
        native.append(String(format: "app: veilig %.0f/%.0f/%.0f/%.0f  inset %.0f/%.0f/%.0f/%.0f",
                             safe.top, safe.left, safe.bottom, safe.right,
                             inset.top, inset.left, inset.bottom, inset.right))
        let script = "(" + reportJS + ")(\(Int(webView.bounds.width.rounded())))"
        let page = (try? await webView.evaluateJavaScript(script) as? String) ?? "(pagina gaf geen antwoord)"
        // Eerst het oordeel en de opmaak-uitkomst uit de pagina, dan de app-regels, dan de rest
        var pageLines = page.components(separatedBy: "\n")
        let head = pageLines.isEmpty ? [] : [pageLines.removeFirst()]
        return (head + native + pageLines).joined(separator: "\n")
    }

    // Argument: breedte van de webview in punten (de pagina moet daar met innerWidth * schaal op uitkomen)
    private static let reportJS = #"""
    (PF_NATIVE_W) => {
      const NL = String.fromCharCode(10);
      const R = Math.round;
      const d = document.documentElement, vv = window.visualViewport;
      const iw = innerWidth, vs = vv ? vv.scale : 1;
      const onPin = location.pathname.includes('/pin/');
      const tid = (el) => (el.getAttribute && el.getAttribute('data-test-id')) || el.id || el.tagName.toLowerCase();
      const P = window.__pfVP || {};
      const L = window.__pfLayout || null;
      const lines = [];
      const findings = [];

      // 1. Viewport: is de breedte die Pinterest ziet wel wat we bedoelden?
      const pts = iw * vs;
      const stale = [];
      if (P.pending) stale.push('wisselt nog');
      if (P.target && Math.abs(iw - P.target.iw) > 1) stale.push('iw ' + iw + ' verwacht ' + P.target.iw);
      if (PF_NATIVE_W && Math.abs(pts - PF_NATIVE_W) > 3) stale.push('iw*schaal ' + R(pts) + ' != app ' + PF_NATIVE_W);
      if (stale.length) findings.push('VIEWPORT STALE ' + stale.join(', '));
      if (onPin && Math.abs(vs - 1) > 0.02) findings.push('ZOOM vv=' + vs.toFixed(2) + ' op pin');

      // 2. Elementen (buiten het raster) die buiten het scherm steken, links of rechts
      const wide = [];
      for (const el of document.querySelectorAll('[data-test-id]')) {
        if (el.closest('[data-grid-item]')) continue;
        const r = el.getBoundingClientRect();
        if (r.width === 0 && r.height === 0) continue;
        const over = Math.max(r.right - iw, -r.left);
        if (over > 2) wide.push({ id: tid(el), over: R(over), l: R(r.left), r: R(r.right) });
      }
      wide.sort((a, b) => b.over - a.over);
      if (onPin && wide.length) {
        const w = wide[0];
        findings.push('BUITEN: ' + w.id + (w.r - iw >= -w.l ? ' right=' + w.r + ' > ' + iw : ' left=' + w.l + ' < 0'));
      }

      // 3. Het pinblok en zijn ouders: knipt er iemand de (verschoven) afbeelding af?
      const cont = document.querySelector('[data-test-id="closeup-container"]');
      let img = null, area = 0;
      if (cont) for (const im of cont.querySelectorAll('img')) {
        const r = im.getBoundingClientRect();
        if (r.width * r.height > area) { img = im; area = r.width * r.height; }
      }
      const focus = img || cont;
      const chain = [];
      const clipped = [];
      let plain = 0;
      let hit = '';
      if (focus) {
        const tr = focus.getBoundingClientRect();
        for (let a = focus.parentElement; a; a = a.parentElement) {
          const cs = getComputedStyle(a);
          const r = a.getBoundingClientRect();
          const clips = cs.overflowX !== 'visible' || cs.overflowY !== 'visible' || cs.clipPath !== 'none' || /paint|strict|content/.test(cs.contain);
          const sides = [['links', r.left - tr.left], ['rechts', tr.right - r.right], ['boven', r.top - tr.top], ['onder', tr.bottom - r.bottom]];
          sides.sort((x, y) => y[1] - x[1]);
          const stick = R(sides[0][1]);
          const knipt = clips && stick > 1 && a !== d && a !== document.body;
          const interesting = clips || cs.transform !== 'none' || cs.contain !== 'none' || cs.position !== 'static' || cs.borderRadius !== '0px';
          if (knipt) clipped.push(tid(a) + ' ' + sides[0][0] + ' ' + stick + ' px');
          if (interesting && chain.length < 9) {
            chain.push('  ' + tid(a) + ' ov ' + cs.overflowX + '/' + cs.overflowY + (cs.position !== 'static' ? ' ' + cs.position : '') +
                       (cs.transform !== 'none' ? ' tf' : '') + (cs.contain !== 'none' ? ' ctn ' + cs.contain : '') +
                       (cs.clipPath !== 'none' ? ' clip' : '') + (cs.borderRadius !== '0px' ? ' rond' : '') +
                       ' ' + R(r.left) + '..' + R(r.right) + (knipt ? '  KNIPT ' + stick + ' px' : ''));
          } else if (!interesting) plain++;
        }
        // Raakt een vinger de afbeelding op links/rechts/onder/boven/midden? Zo niet: afgeknipt of bedekt.
        const pts6 = [['L', tr.left + 6, (tr.top + tr.bottom) / 2], ['R', tr.right - 6, (tr.top + tr.bottom) / 2],
                      ['O', (tr.left + tr.right) / 2, tr.bottom - 6], ['B', (tr.left + tr.right) / 2, tr.top + 6],
                      ['M', (tr.left + tr.right) / 2, (tr.top + tr.bottom) / 2]];
        for (const [name, x, y] of pts6) {
          if (x < 0 || y < 0 || x > iw || y > innerHeight) { hit += name + '- '; continue; }
          const h = document.elementFromPoint(x, y);
          hit += name + (h && (focus.contains(h) || (cont && cont.contains(h))) ? 'ok' : 'MIS(' + (h ? tid(h) : '?') + ')') + ' ';
        }
      }
      if (clipped.length) findings.push('GEKNIPT: ' + clipped[0]);
      if (d.scrollWidth > iw + 1 || Math.abs(scrollX) > 1 || (vv && (Math.abs(vv.pageLeft) > 1 || Math.abs(vv.offsetLeft) > 1))) {
        findings.push('HORIZONTAAL SCROLLBAAR scrollWidth ' + d.scrollWidth + ' scrollX ' + R(scrollX) + (vv ? ' vv.pageLeft ' + R(vv.pageLeft) : ''));
      }

      // Oordeel bovenaan (de eerste regel die past), en wat de app-opmaak besloot
      lines.push('OORDEEL: ' + (findings.length ? findings[0] + (findings.length > 1 ? '   (+' + (findings.length - 1) + ' meer: ' + findings.slice(1).map((f) => f.split(' ')[0]).join(', ') + ')' : '') : 'geen probleem gemeten'));
      if (L) {
        lines.push('opmaak: ' + L.status + (L.reason ? ' (' + L.reason + ')' : '') + '  ' + L.path + ' bij iw ' + L.iw +
                   (L.scale ? '  schaal ' + L.scale + ' dx ' + L.dx + ' detailsDx ' + L.detailsDx + ' rechts ' + L.imageRight : '') +
                   (L.ir ? '  ir ' + L.ir.join(',') : '') + (L.dr ? ' dr ' + L.dr.join(',') : '') + (L.img ? ' beeld ' + L.img.join(',') : ''));
      } else {
        lines.push('opmaak: nog niets besloten (geen pin geopend, of script niet actief)');
      }
      lines.push('pad ' + location.pathname);
      lines.push('viewport ' + [...document.querySelectorAll('meta[name="viewport"]')].map((m) => m.content).join(' | '));
      lines.push('  eigen regel van Pinterest: ' + ([...document.querySelectorAll('meta[name="viewport"]')].map((m) => m.dataset.pfOriginal || '-').join(' | ')) +
                 '  stand ' + (P.mode || '-') + (P.target ? ' verwacht ' + P.target.iw + '@' + P.target.s : ''));
      lines.push('breed ' + iw + ' client ' + d.clientWidth + ' scroll ' + d.scrollWidth + ' hoogte ' + innerHeight + ' buiten ' + outerWidth +
                 ' vv ' + (vv ? R(vv.width) + '@' + vs.toFixed(2) + ' links ' + R(vv.offsetLeft) + ' pagina ' + R(vv.pageLeft) : '-') +
                 ' scrollX ' + R(scrollX));
      lines.push('scherm ' + screen.width + 'x' + screen.height + ' dpr ' + devicePixelRatio + ' ' + ((screen.orientation && screen.orientation.type) || '-') +
                 (P.settled ? '  laatst gezet: ' + P.settled.iw + '@' + P.settled.s.toFixed(2) + ' na ' + P.settled.ms + ' ms (' + P.settled.how + ')' : ''));

      // Te breed, en de drie hoofdblokken van een pin
      lines.push('te breed: ' + (wide.slice(0, 5).map((w) => w.id + ' ' + w.l + '..' + w.r).join(' · ') || 'niets'));
      for (const id of ['closeup-body-landscape', 'closeup-container', 'CloseupDetails']) {
        const el = document.querySelector('[data-test-id="' + id + '"]');
        if (!el) continue;
        const r = el.getBoundingClientRect();
        lines.push('  ' + id + ' ' + R(r.left) + '..' + R(r.right) + ' (' + R(r.width) + ') ' + (r.right > iw + 2 || r.left < -2 ? 'BUITEN' : 'binnen') +
                   (el.style.transform ? ' tf ' + el.style.transform : ''));
      }
      if (chain.length || plain) {
        lines.push('ouders van de afbeelding (alleen opvallende, ' + plain + ' gewone niet getoond):');
        for (const c of chain) lines.push(c);
      }
      if (hit) lines.push('aanraking op de afbeelding: ' + hit);

      // Advertentievelden van deze pin (door het filter heen gekomen), zie adProbeJS
      const pinId = (location.pathname.split('/pin/')[1] || '').split('/')[0];
      const ad = pinId && window.__pfAdScan ? window.__pfAdScan(pinId) : null;
      lines.push('advertentievelden: ' + (pinId ? (ad && ad.length ? ad.join(' · ') : 'geen') : '-'));

      // Gebeurtenissen (viewport, opmaak), laatste 10
      const events = (window.__pfLog || []).slice(-10);
      lines.push('gebeurtenissen:');
      for (const e of events) lines.push('  ' + e);
      lines.push('');

      // Boom van blokken met een data-test-id, buiten het raster (op een pin kort: het oordeel is al gegeven)
      const cap = lines.length + (onPin ? 30 : 70);
      const walk = (el, depth) => {
        if (lines.length > cap) return;
        const id = el.getAttribute && el.getAttribute('data-test-id');
        let next = depth;
        if (id) {
          const r = el.getBoundingClientRect();
          const cs = getComputedStyle(el);
          const extra = [];
          if (cs.backgroundColor !== 'rgba(0, 0, 0, 0)') extra.push('bg ' + cs.backgroundColor);
          if (cs.borderRadius !== '0px') extra.push('rond ' + cs.borderRadius);
          if (cs.boxShadow !== 'none') extra.push('schaduw');
          if (cs.position === 'fixed' || cs.position === 'sticky') extra.push(cs.position);
          lines.push('  '.repeat(depth) + id + '  ' + R(r.left) + ',' + R(r.top) + ' ' +
                     R(r.width) + 'x' + R(r.height) + (extra.length ? '  [' + extra.join(', ') + ']' : ''));
          next = depth + 1;
        }
        for (const c of el.children) {
          if (c.hasAttribute && c.hasAttribute('data-grid-item')) continue;
          walk(c, next);
        }
      };
      walk(document.body, 0);
      return lines.join(NL);
    }
    """#
}

// Viewport voor 4 of 5 kolommen. Eén eigenaar, één ontwerp:
// - Feed liggend met 4 kolommen: wij zetten 'width=944, initial-scale=1.25' (zoals altijd).
// - Alles anders (5 kolommen, geopende pin): Pinterests eigen viewport-regel, dus breedte = venster.
//   Op een pin rekenen we dus niet meer met de schermbreedte (screen.width), wat in een kleiner
//   iPadOS-venster niet klopt.
// - Na elke wijziging wachten we tot de viewport ECHT veranderd is (innerWidth en schaal peilen
//   we elke 50 ms, maximaal 2 s) en pas dan sturen we het "resize"-signaal waarop Pinterest zijn
//   opmaak kiest; bij een time-out sturen we het toch, zodat niets blijft hangen. De uitkomst gaat
//   als "viewportSettled" naar de app en de pinopmaak (PageTweaks.swift) meet pas daarna.
// Niet gedaan (bewust uit): de viewport al vóór de klik wisselen (window.__pfPinMode, achter een
// localStorage-vlag "pfPreflip"). Dat scheelt naar schatting 150-300 ms, maar verandert de volgorde
// van gebeurtenissen; eerst moet deze versie op de iPad bewezen stabiel zijn.
private let columnsJS = #"""
(() => {
  let factor = PF_APP_ZOOM;
  try { const v = parseFloat(localStorage.getItem('pfZoom')); if (v) factor = v; } catch (e) {}

  const R = Math.round;
  const state = () => ({ iw: innerWidth, s: (window.visualViewport && visualViewport.scale) || 1 });
  // Korte gebeurtenissenlijst voor de pagina-analyse (ook door PageTweaks gevuld)
  const log = (m) => {
    try {
      const a = (window.__pfLog = window.__pfLog || []);
      const st = state();
      a.push(R(performance.now()) + ' ' + m + ' iw=' + st.iw + ' vv=' + st.s.toFixed(2));
      if (a.length > 24) a.shift();
    } catch (e) {}
  };
  const native = (m) => { try { webkit.messageHandlers.pfLayout.postMessage(m); } catch (e) {} };
  // Toestand van de viewport, gelezen door PageTweaks (pending) en de pagina-analyse
  const VP = window.__pfVP = { pending: false, before: null, target: null, settled: null, mode: '' };

  const isLandscape = () => {
    const o = screen.orientation && screen.orientation.type;
    if (o) return o.startsWith('landscape');
    return Math.abs(window.orientation || 0) === 90;
  };
  const onPinPage = () => location.pathname.includes('/pin/');
  // Onze eigen regel alleen op de feed en alleen als er 4 kolommen zijn gekozen
  const ownWanted = () => factor !== 1 && !onPinPage();
  const content = () => {
    const long = Math.max(screen.width, screen.height), short = Math.min(screen.width, screen.height);
    if (!short) return null;   // schermmaat onbekend: niets aanpassen
    const f = isLandscape() ? factor : 1;
    const width = Math.round((isLandscape() ? long : short) / f);
    return { str: 'width=' + width + ', initial-scale=' + f + ', minimum-scale=' + f + ', maximum-scale=' + f + ', user-scalable=no',
             iw: width, s: f };
  };

  // Wacht tot de viewport echt gewisseld is, en geef Pinterest dan het "resize"-signaal (twee keer,
  // omdat Pinterest even wacht). `target` (of de hint) is de verwachte stand als die bekend is;
  // anders volstaat "veranderd ten opzichte van voor de wijziging en twee peilingen achter elkaar gelijk".
  let token = 0;
  const fire = () => window.dispatchEvent(new Event('resize'));
  const startSettle = (before, target, hint, why) => {
    const my = ++token;
    VP.pending = true;
    VP.before = before;
    const t0 = performance.now();
    log('viewport ' + why + ' -> ' + (target ? target.iw + '@' + target.s : (hint ? '~' + hint.iw : '?')));
    let last = null, soft = false;
    const matches = (cur, t) => t && Math.abs(cur.iw - t.iw) <= 1 && Math.abs(cur.s - t.s) < 0.02;
    const finish = (how) => {
      const cur = state();
      VP.pending = false;
      VP.settled = { iw: cur.iw, s: cur.s, ms: R(performance.now() - t0), how };
      log('viewport klaar (' + how + ')');
      fire();
      setTimeout(fire, 150);
      native({ type: 'viewportSettled', iw: cur.iw, scale: cur.s, how });
      setTimeout(apply, 200);   // is de stand nog wat we willen? (bijv. schermmaat na draaien)
    };
    const poll = () => {
      if (my !== token) return;
      const cur = state();
      const el = performance.now() - t0;
      const moved = cur.iw !== before.iw || Math.abs(cur.s - before.s) > 0.01;
      const stable = last && last.iw === cur.iw && Math.abs(last.s - cur.s) < 0.01;
      if (target ? matches(cur, target) : (matches(cur, hint) || (moved && stable))) { finish('ok'); return; }
      if (el > 2000) { finish('time-out'); return; }
      // Geen zichtbare verandering na een halve seconde: één signaal vast sturen, en blijven peilen
      if (!soft && el > 500 && !moved) { soft = true; fire(); log('viewport: vroeg signaal'); }
      last = cur;
      setTimeout(poll, 50);
    };
    setTimeout(poll, 30);
  };

  const apply = () => {
    if (!document.head) return;
    let metas = [...document.head.querySelectorAll('meta[name="viewport"]')];
    // Heeft Pinterest de regel zelf veranderd? Dan is dat de nieuwe "eigen" waarde van Pinterest
    for (const m of metas) if (m.dataset.pfSet !== undefined && m.content !== m.dataset.pfSet) m.dataset.pfOriginal = m.content;
    // Staat een eerdere wijziging nog te landen, dan blijft de stand van vóór die wijziging het vergelijkingspunt
    const before = VP.pending && VP.before ? VP.before : state();

    // 5 kolommen of een geopende pin: Pinterests eigen regel (terugzetten als wij hem eerder veranderden)
    if (!ownWanted()) {
      VP.mode = 'pinterest';
      VP.target = null;
      let changed = false;
      for (const m of metas) {
        if (m.dataset.pfOriginal !== undefined && m.content !== m.dataset.pfOriginal) {
          m.content = m.dataset.pfSet = m.dataset.pfOriginal;
          changed = true;
        }
      }
      // Kwamen we uit onze eigen regel, dan is de echte breedte (in punten) al bekend: innerWidth * schaal
      if (changed) startSettle(before, null, before.s !== 1 ? { iw: R(before.iw * before.s), s: 1 } : null, 'pinterest-regel');
      return;
    }

    const c = content();
    if (!c) return;
    VP.mode = 'eigen';
    VP.target = { iw: c.iw, s: c.s };
    if (!metas.length) {
      const m = document.createElement('meta');
      m.name = 'viewport';
      m.dataset.pfOriginal = 'width=device-width, initial-scale=1';
      document.head.appendChild(m);
      metas = [m];
    }
    let changed = false;
    for (const m of metas) {
      if (m.dataset.pfOriginal === undefined) m.dataset.pfOriginal = m.content;
      if (m.content !== c.str) { m.content = c.str; changed = true; }
      m.dataset.pfSet = c.str;
    }
    // Pinterest kiest zijn opmaak (smal of breed) opnieuw bij een "resize"-signaal, maar een
    // gewijzigde viewport geeft dat signaal niet vanzelf. Zonder dit bleef een geopende pin in de
    // smalle opmaak staan en werd de afbeelding afgesneden.
    if (changed) startSettle(before, VP.target, null, 'eigen-regel');
  };

  // Pinterest zet zijn eigen viewport-regel; die overschrijven we steeds opnieuw
  let headObserver = null;
  const watchHead = () => {
    if (headObserver || !document.head) return;
    headObserver = new MutationObserver(apply);
    headObserver.observe(document.head, { childList: true, subtree: true, attributes: true, attributeFilter: ['content'] });
    apply();
  };
  const docObserver = new MutationObserver(() => { if (document.head) { watchHead(); docObserver.disconnect(); } });
  docObserver.observe(document, { childList: true, subtree: true });
  document.addEventListener('DOMContentLoaded', () => { watchHead(); apply(); });
  // Na draaien is de schermmaat soms pas later goed: nog een keer controleren
  const reapplyLater = () => { setTimeout(apply, 50); setTimeout(apply, 400); };
  window.addEventListener('orientationchange', reapplyLater);
  // Pinterest wisselt van pagina zonder te herladen: na elke paginawissel opnieuw toepassen
  for (const fn of ['pushState', 'replaceState']) {
    const original = history[fn];
    history[fn] = function (...args) { const r = original.apply(this, args); log(fn + ' ' + location.pathname); apply(); return r; };
  }
  window.addEventListener('popstate', () => { log('popstate ' + location.pathname); apply(); });
  if (screen.orientation) screen.orientation.addEventListener('change', reapplyLater);

  // Wisselen tussen 4 en 5 kolommen zonder de pagina te herladen (geen witte flits).
  // De app roept dit ook aan na een adreswissel, zodat pagina en app hetzelfde aantal kolommen hebben.
  window.__pfSetZoom = (f) => {
    if (f === factor) return 'ok';
    factor = f;
    try { localStorage.setItem('pfZoom', String(f)); } catch (e) {}
    apply();
    return 'ok';
  };

  // Voor de bewaker in PageTweaks: past de pagina niet in de breedte, dan Pinterest opnieuw laten opmaken
  window.__pfRecheckViewport = () => {
    log('viewport: herstart gevraagd');
    apply();
    fire();
    setTimeout(fire, 150);
  };
})();
"""#

// Voor de pagina-analyse: welke advertentie-achtige velden (met een echte waarde) er in de data van een
// pin zaten, NA het advertentiefilter. Zo is te zien waarom een "Ad" erdoor glipte.
// Draait na het filter, dus ziet alleen wat het filter heeft laten staan.
// Lui: tijdens het laden bewaren we alleen een verwijzing naar de laatste gegevens (geen regex, geen
// scan). De scan gebeurt pas als de pagina-analyse erom vraagt (window.__pfAdScan), niet bij elke fetch.
let adProbeJS = #"""
(() => {
  const AD_KEY = /promot|sponsor|advertis|campaign|^ad[A-Z_]|^ad$|_ad$|isAd|is_ad/i;
  const recent = [];
  const parse = JSON.parse;
  JSON.parse = function (text, reviver) {
    const result = parse.call(this, text, reviver);
    if (typeof text === 'string' && text.length > 2000 && result && typeof result === 'object') {
      recent.push(result);
      if (recent.length > 8) recent.shift();
    }
    return result;
  };
  window.__pfAdScan = (pinId) => {
    const flags = new Set();
    let visited = 0;
    const scan = (node, depth) => {
      if (!node || typeof node !== 'object' || depth > 14 || visited++ > 400000) return;
      if (Array.isArray(node)) { for (const x of node) scan(x, depth + 1); return; }
      const keys = Object.keys(node);
      if (node.id === pinId) {
        for (const k of keys) {
          const v = node[k];
          if (AD_KEY.test(k) && v && v !== '0') flags.add(k + '=' + (typeof v === 'object' ? '{…}' : String(v).slice(0, 20)));
        }
      }
      for (const k of keys) { const v = node[k]; if (v && typeof v === 'object') scan(v, depth + 1); }
    };
    try { for (const r of recent) scan(r, 0); } catch (e) {}
    return [...flags];
  };
})();
"""#

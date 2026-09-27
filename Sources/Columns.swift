import SwiftUI
import WebKit

// Aantal kolommen in liggende stand: 5 is Pinterests eigen keuze, 4 geeft grotere pins zoals in de app.
//
// Hoe het werkt: via de viewport-instelling van de pagina zeggen we "het scherm is smaller"
// (1180 / 1.25 = 944 breed). Pinterest bouwt daar zelf 4 kolommen voor, en iOS schaalt het
// scherp op naar de volle breedte. (Inzoomen met de app zelf werkte niet: Pinterest bleef dan
// voor de oude breedte bouwen, met overlappende pins als gevolg.)
@MainActor
final class ColumnSetting: ObservableObject {
    static let shared = ColumnSetting()

    @Published private(set) var columns: Int
    weak var webView: WKWebView?

    private init() {
        columns = UserDefaults.standard.integer(forKey: "columns") == 5 ? 5 : 4
    }

    // Hoeveel de pagina liggend wordt opgeschaald
    var zoomFactor: Double { columns == 4 ? 1.25 : 1.0 }

    func toggle() {
        columns = columns == 4 ? 5 : 4
        UserDefaults.standard.set(columns, forKey: "columns")
        // Het script in de pagina leest de waarde bij het laden, dus opslaan en herladen
        webView?.evaluateJavaScript("localStorage.setItem('pfZoom', '\(zoomFactor)')") { [weak self] _, _ in
            self?.webView?.reload()
        }
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
            .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
                NavigationStack {
                    ScrollView {
                        Text(report ?? "")
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("Pagina-analyse")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("Sluit") { report = nil } }
                    }
                }
            }
    }
}

// Overzicht van hoe de huidige pagina is opgebouwd: maten, viewport en de blokken met een
// data-test-id (Pinterests eigen namen). Niels maakt er een screenshot van voor Claude.
@MainActor
enum PageReport {
    static func make(webView: WKWebView?) async -> String {
        guard let webView else { return "Geen webview" }
        let sv = webView.scrollView
        let native = String(format: "app: zoom %.2f  offset %.0f,%.0f  inhoud %.0fx%.0f  scherm %.0fx%.0f",
                            sv.zoomScale, sv.contentOffset.x, sv.contentOffset.y,
                            sv.contentSize.width, sv.contentSize.height, sv.bounds.width, sv.bounds.height)
        let page = (try? await webView.evaluateJavaScript(reportJS) as? String) ?? "(pagina gaf geen antwoord)"
        return native + "\n" + page
    }

    private static let reportJS = #"""
    (() => {
      const NL = String.fromCharCode(10);
      const d = document.documentElement, vv = window.visualViewport;
      const lines = [];
      lines.push('pad ' + location.pathname);
      lines.push('viewport ' + [...document.querySelectorAll('meta[name="viewport"]')].map((m) => m.content).join(' | '));
      lines.push('breed ' + innerWidth + ' client ' + d.clientWidth + ' scroll ' + d.scrollWidth +
                 ' vv ' + (vv ? Math.round(vv.width) + '@' + vv.scale.toFixed(2) + ' links ' + Math.round(vv.offsetLeft) : '-'));

      // Elementen die breder zijn dan het scherm (oorzaak van afsnijden)
      const wide = [];
      for (const el of document.querySelectorAll('body *')) {
        if (wide.length >= 6) break;
        if (el.closest('[data-grid-item]')) continue;
        const r = el.getBoundingClientRect();
        if (r.width > innerWidth + 5 || r.left < -5) {
          wide.push((el.getAttribute('data-test-id') || el.tagName.toLowerCase()) + ' ' + Math.round(r.left) + '+' + Math.round(r.width));
        }
      }
      lines.push('te breed: ' + (wide.join(' · ') || 'niets'));
      lines.push('');

      // Boom van blokken met een data-test-id, buiten het raster
      const walk = (el, depth) => {
        if (lines.length > 110) return;
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
          lines.push('  '.repeat(depth) + id + '  ' + Math.round(r.left) + ',' + Math.round(r.top) + ' ' +
                     Math.round(r.width) + 'x' + Math.round(r.height) + (extra.length ? '  [' + extra.join(', ') + ']' : ''));
          next = depth + 1;
        }
        for (const c of el.children) {
          if (c.hasAttribute && c.hasAttribute('data-grid-item')) continue;
          walk(c, next);
        }
      };
      walk(document.body, 0);
      return lines.join(NL);
    })()
    """#
}

private let columnsJS = #"""
(() => {
  let factor = PF_APP_ZOOM;
  try { const v = parseFloat(localStorage.getItem('pfZoom')); if (v) factor = v; } catch (e) {}
  if (factor === 1) return;   // 5 kolommen: Pinterest gewoon zijn gang laten gaan

  const isLandscape = () => {
    const o = screen.orientation && screen.orientation.type;
    if (o) return o.startsWith('landscape');
    return Math.abs(window.orientation || 0) === 90;
  };
  const content = () => {
    const long = Math.max(screen.width, screen.height), short = Math.min(screen.width, screen.height);
    if (!short) return null;   // schermmaat onbekend: niets aanpassen
    // Alleen het raster verkleinen; een geopende pin rekent met de echte breedte en viel anders buiten beeld
    const onPinPage = location.pathname.includes('/pin/');
    const f = isLandscape() && !onPinPage ? factor : 1;
    const width = Math.round((isLandscape() ? long : short) / f);
    return 'width=' + width + ', initial-scale=' + f + ', minimum-scale=' + f + ', maximum-scale=' + f + ', user-scalable=no';
  };
  const apply = () => {
    const c = content();
    if (!document.head || !c) return;
    let metas = [...document.head.querySelectorAll('meta[name="viewport"]')];
    if (!metas.length) {
      const m = document.createElement('meta');
      m.name = 'viewport';
      document.head.appendChild(m);
      metas = [m];
    }
    for (const m of metas) if (m.content !== c) m.content = c;
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
  window.addEventListener('orientationchange', () => setTimeout(apply, 50));
  // Pinterest wisselt van pagina zonder te herladen: na elke paginawissel opnieuw toepassen
  for (const fn of ['pushState', 'replaceState']) {
    const original = history[fn];
    history[fn] = function (...args) { const r = original.apply(this, args); apply(); return r; };
  }
  window.addEventListener('popstate', apply);
  if (screen.orientation) screen.orientation.addEventListener('change', () => setTimeout(apply, 50));
})();
"""#

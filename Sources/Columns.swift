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

// Knopje rechtsonder (alleen liggend) om te wisselen tussen 4 en 5 kolommen
struct ColumnButton: View {
    @ObservedObject var setting = ColumnSetting.shared

    var body: some View {
        Button { setting.toggle() } label: {
            Label("\(setting.columns) kolommen", systemImage: "square.grid.3x3")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
        .foregroundStyle(.primary)
        .padding(12)
    }
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

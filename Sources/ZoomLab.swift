import SwiftUI
import WebKit

// TIJDELIJK proefpaneel om uit te zoeken hoe Pinterest 4 kolommen krijgt.
// Wordt weer verwijderd zodra de goede instelling bekend is.
// De keuzes worden bewaard (UserDefaults), zodat ze een herstart van de app overleven.
@MainActor
final class ZoomLab: ObservableObject {
    static let shared = ZoomLab()

    enum Method: String { case pageZoom, viewport }

    @Published var landscapeZoom: CGFloat
    @Published var mobile: Bool
    @Published var method: Method
    @Published var widthFix: Bool
    @Published var info = "Tik op Meet"
    weak var webView: WKWebView?

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        landscapeZoom = CGFloat(d.object(forKey: "lab.zoom") as? Double ?? 1.0)
        mobile = d.object(forKey: "lab.mobile") as? Bool ?? true   // tablet-site standaard aan
        method = Method(rawValue: d.string(forKey: "lab.method") ?? "") ?? .pageZoom
        widthFix = d.object(forKey: "lab.widthFix") as? Bool ?? true
    }

    // pageZoom van de app zelf; alleen bij methode "pageZoom" en alleen liggend
    var effectivePageZoom: CGFloat { method == .pageZoom ? landscapeZoom : 1.0 }

    func set(zoom: CGFloat) { landscapeZoom = zoom; applyAndReload() }
    func toggleMobile() { mobile.toggle(); applyAndReload() }
    func toggleMethod() { method = method == .pageZoom ? .viewport : .pageZoom; applyAndReload() }
    func toggleWidthFix() { widthFix.toggle(); applyAndReload() }

    private func applyAndReload() {
        defaults.set(Double(landscapeZoom), forKey: "lab.zoom")
        defaults.set(mobile, forKey: "lab.mobile")
        defaults.set(method.rawValue, forKey: "lab.method")
        defaults.set(widthFix, forKey: "lab.widthFix")
        guard let webView else { return }
        // De scripts in de pagina lezen deze waarden bij het laden
        let viewportZoom = method == .viewport ? Double(landscapeZoom) : 1.0
        let js = "localStorage.setItem('pfVpZoom', '\(viewportZoom)'); localStorage.setItem('pfWidthFix', '\(widthFix ? "1" : "0")')"
        webView.evaluateJavaScript(js) { _, _ in
            webView.setNeedsLayout()
            webView.layoutIfNeeded()   // zet eerst de nieuwe zoom, pas dan herladen
            webView.reload()
        }
    }

    func measure() {
        let js = """
        (() => {
          const items = [...document.querySelectorAll('[data-grid-item]')];
          const cols = new Set(items.map(i => Math.round(i.getBoundingClientRect().left))).size;
          const w = items[0] ? Math.round(items[0].getBoundingClientRect().width) : 0;
          const d = document.documentElement;
          const p = window.__pf || {};
          const reads = Object.entries(p.counts || {}).map(([k, v]) => k + ' ' + v).join(', ');
          const vv = window.visualViewport;
          const name = (el) => el.getAttribute('data-test-id') ||
            (el.tagName.toLowerCase() + (typeof el.className === 'string' && el.className ? '.' + el.className.split(' ')[0] : ''));
          const wide = [];
          for (let el = items[0]; el && el !== d; el = el.parentElement) {
            const r = el.getBoundingClientRect();
            if (r.width > innerWidth + 5) {
              const cs = getComputedStyle(el);
              wide.push(name(el) + ' ' + Math.round(r.width) +
                (el.style.width ? ' w=' + el.style.width : '') +
                (el.style.minWidth ? ' minw=' + el.style.minWidth : '') +
                (cs.minWidth !== '0px' && cs.minWidth !== 'auto' ? ' cssmin=' + cs.minWidth : ''));
            }
          }
          const meta = [...document.querySelectorAll('meta[name="viewport"]')].map(m => m.content).join(' | ');
          return 'breed ' + innerWidth + ' / ' + d.clientWidth + ' / scroll ' + d.scrollWidth +
                 ' · vv ' + (vv ? Math.round(vv.width) + '@' + vv.scale.toFixed(2) : '-') +
                 ' · kolommen ' + cols + ' · pin ' + w +
                 ' · ' + (navigator.userAgent.includes('iPad') ? 'tablet' : 'desktop') +
                 ' ¶ te breed (buiten→binnen): ' + (wide.reverse().slice(0, 6).join(' > ') || 'niets') +
                 ' ¶ viewport: ' + meta + ' ¶ gelezen: ' + reads;
        })()
        """
        webView?.evaluateJavaScript(js) { [weak self] result, error in
            self?.info = (result as? String) ?? "fout: \(error?.localizedDescription ?? "?")"
        }
    }
}

struct ZoomLabPanel: View {
    @ObservedObject var lab = ZoomLab.shared
    @State private var open = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Zoom liggend: " + String(format: "%.2f", Double(lab.landscapeZoom)))
                    HStack {
                        ForEach([1.0, 1.1, 1.15, 1.2, 1.25], id: \.self) { z in
                            Button(String(format: "%.2f", z)) { lab.set(zoom: z) }
                                .buttonStyle(.bordered)
                        }
                    }
                    HStack {
                        Button(lab.method == .pageZoom ? "Methode: app-zoom" : "Methode: viewport") { lab.toggleMethod() }
                            .buttonStyle(.bordered)
                        Button(lab.mobile ? "Tablet-site: AAN" : "Tablet-site: UIT") { lab.toggleMobile() }
                            .buttonStyle(.bordered)
                        Button(lab.widthFix ? "Breedte-fix: AAN" : "Breedte-fix: UIT") { lab.toggleWidthFix() }
                            .buttonStyle(.bordered)
                        Button("Meet") { lab.measure() }
                            .buttonStyle(.borderedProminent)
                    }
                    Text(lab.info).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: 560, alignment: .leading)
                }
                .padding(10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            Button(open ? "✕" : "🔧") { open.toggle() }
                .font(.title2)
                .padding(8)
                .background(.regularMaterial, in: Circle())
        }
        .padding(12)
    }
}

// TIJDELIJK: telt welke breedte-eigenschappen Pinterest uitleest, en laat outerWidth/outerHeight
// meezoomen (die blijven anders op de echte schermbreedte staan, ook als de pagina is ingezoomd).
let widthProbeJS = #"""
(() => {
  const P = window.__pf = { counts: {} };
  try { P.fixOn = localStorage.getItem('pfWidthFix') !== '0'; } catch (e) { P.fixOn = true; }

  const spy = (obj, prop, name, replacement) => {
    const d = Object.getOwnPropertyDescriptor(obj, prop) ||
              Object.getOwnPropertyDescriptor(Object.getPrototypeOf(obj), prop);
    if (!d || !d.get) return null;
    Object.defineProperty(obj, prop, {
      configurable: true, enumerable: d.enumerable,
      get() {
        P.counts[name] = (P.counts[name] || 0) + 1;
        return (replacement && P.fixOn) ? replacement() : d.get.call(this);
      }
    });
    return () => d.get.call(obj);
  };

  spy(window, 'outerWidth', 'outerWidth', () => window.innerWidth);
  spy(window, 'outerHeight', 'outerHeight', () => window.innerHeight);
  spy(window, 'innerWidth', 'innerWidth');
  spy(Screen.prototype, 'width', 'screen.width');
  spy(Screen.prototype, 'height', 'screen.height');
})();
"""#

// TIJDELIJK: tweede zoommethode. In plaats van de app-zoom vertellen we de pagina via de
// viewport-instelling "doe alsof het scherm smaller is" (width=944 bij 1180 breed), en laten iOS
// het scherp opschalen. Staat uit als pfVpZoom 1 is.
let viewportZoomJS = #"""
(() => {
  let factor = 1;
  try { factor = parseFloat(localStorage.getItem('pfVpZoom') || '1') || 1; } catch (e) {}
  if (factor === 1) return;

  const isLandscape = () => {
    const o = screen.orientation && screen.orientation.type;
    if (o) return o.startsWith('landscape');
    return Math.abs(window.orientation || 0) === 90;
  };
  const content = () => {
    const long = Math.max(screen.width, screen.height), short = Math.min(screen.width, screen.height);
    if (!short) return null;   // schermmaat onbekend: niets aanpassen
    const f = isLandscape() ? factor : 1;
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
  if (screen.orientation) screen.orientation.addEventListener('change', () => setTimeout(apply, 50));
})();
"""#

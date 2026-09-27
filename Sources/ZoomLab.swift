import SwiftUI
import WebKit

// TIJDELIJK proefpaneel om uit te zoeken hoe Pinterest 4 kolommen krijgt.
// Wordt weer verwijderd zodra de goede instelling bekend is.
@MainActor
final class ZoomLab: ObservableObject {
    static let shared = ZoomLab()

    @Published var landscapeZoom: CGFloat = 1.0
    @Published var mobile = false
    @Published var widthFix = true
    @Published var info = "Tik op Meet"
    weak var webView: WKWebView?

    func set(zoom: CGFloat) {
        landscapeZoom = zoom
        reloadWithSettings()
    }

    func toggleMobile() {
        mobile.toggle()
        reloadWithSettings()
    }

    func toggleWidthFix() {
        widthFix.toggle()
        // Het meetscript leest deze waarde bij het laden van de pagina
        webView?.evaluateJavaScript("localStorage.setItem('pfWidthFix', '\(widthFix ? "1" : "0")')") { [weak self] _, _ in
            self?.reloadWithSettings()
        }
    }

    private func reloadWithSettings() {
        guard let webView else { return }
        webView.setNeedsLayout()
        webView.layoutIfNeeded()   // zet eerst de nieuwe zoom, pas dan herladen
        webView.reload()
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
          const mq = Object.entries(p.mq || {}).sort((a, b) => b[1] - a[1]).slice(0, 4)
                       .map(([k, v]) => k + ' ×' + v).join(' | ');
          const vv = window.visualViewport;
          return 'breed ' + innerWidth + ' / ' + d.clientWidth + ' / scroll ' + d.scrollWidth +
                 ' · outer ' + (p.rawOuter ? p.rawOuter() : '?') + '→' + outerWidth +
                 ' · vv ' + (vv ? Math.round(vv.width) + '@' + vv.scale.toFixed(2) : '-') +
                 ' · scherm ' + screen.width + ' · kolommen ' + cols + ' · pin ' + w +
                 ' · ' + (navigator.userAgent.includes('iPad') ? 'tablet' : 'desktop') +
                 ' · fix ' + (p.fixOn ? 'aan' : 'uit') +
                 ' ¶ gelezen: ' + reads + ' ¶ media: ' + mq;
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
                        Button(lab.mobile ? "Tablet-site: AAN" : "Tablet-site: UIT") { lab.toggleMobile() }
                            .buttonStyle(.bordered)
                        Button(lab.widthFix ? "Breedte-fix: AAN" : "Breedte-fix: UIT") { lab.toggleWidthFix() }
                            .buttonStyle(.bordered)
                        Button("Meet") { lab.measure() }
                            .buttonStyle(.borderedProminent)
                    }
                    Text(lab.info).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: 520, alignment: .leading)
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
  const P = window.__pf = { counts: {}, mq: {} };
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

  P.rawOuter = spy(window, 'outerWidth', 'outerWidth', () => window.innerWidth);
  spy(window, 'outerHeight', 'outerHeight', () => window.innerHeight);
  spy(window, 'innerWidth', 'innerWidth');
  spy(Screen.prototype, 'width', 'screen.width');
  spy(Screen.prototype, 'availWidth', 'screen.availWidth');
  if (window.VisualViewport) spy(VisualViewport.prototype, 'width', 'vv.width');

  const mm = window.matchMedia;
  window.matchMedia = function (q) { P.mq[q] = (P.mq[q] || 0) + 1; return mm.call(this, q); };
})();
"""#

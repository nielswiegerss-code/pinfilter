import SwiftUI
import WebKit

// TIJDELIJK proefpaneel om uit te zoeken hoe Pinterest 4 kolommen krijgt.
// Wordt weer verwijderd zodra de goede instelling bekend is.
@MainActor
final class ZoomLab: ObservableObject {
    static let shared = ZoomLab()

    @Published var landscapeZoom: CGFloat = 1.0
    @Published var mobile = false
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
          return 'breed ' + innerWidth + ' / ' + d.clientWidth + ' / scroll ' + d.scrollWidth +
                 ' · scherm ' + screen.width + ' · kolommen ' + cols + ' · pin ' + w +
                 ' · ' + (navigator.userAgent.includes('iPad') ? 'tablet' : 'desktop');
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
                        Button("Meet") { lab.measure() }
                            .buttonStyle(.borderedProminent)
                    }
                    Text(lab.info).font(.caption).textSelection(.enabled)
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

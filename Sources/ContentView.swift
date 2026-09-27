import SwiftUI
import WebKit

// Pinterest zonder advertenties.
// Werkende versie uit Swift Playgrounds (getest op iPad).

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geo in
            PinterestView()
                .ignoresSafeArea(edges: .bottom)
                .overlay(alignment: .bottomTrailing) {
                    // Kolommenknop alleen liggend; staand bepaalt Pinterest het zelf
                    if geo.size.width > geo.size.height { ColumnButton() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
                // .inactive komt vóór .background, dus er is nog tijd om de cookies te bewaren
                if phase != .active { CookieVault.saveBeforeSuspend() }
            }
    }
}

struct PinterestView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // onthoudt je login
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"   // doe je voor als Safari
        // Tablet-site: Pinterest stuurt zijn aanraakversie (balk onderin, "…"-menu op pins)
        config.defaultWebpagePreferences.preferredContentMode = .mobile

        // Het filter draait vóór alle code van Pinterest zelf
        let script = WKUserScript(source: adFilterJS,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true)
        config.userContentController.addUserScript(script)

        // Lang indrukken op een pin = rond menu om op te slaan (los van het advertentiefilter)
        config.userContentController.addUserScript(WKUserScript(source: pinSaveJS,
                                                                injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true))
        let bridge = NativeBridge()
        config.userContentController.add(bridge, name: "pfNative")

        // Kleine layoutaanpassingen, zoals de inbox-knop verbergen (zie PageTweaks.swift)
        config.userContentController.addUserScript(WKUserScript(source: pageTweaksJS,
                                                                injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true))
        // Open-animatie: tik op een pin even vasthouden en de app laten animeren (zie Transitions.swift).
        // Na pinSaveJS, zodat het lang-indrukken-menu een klik eerst kan tegenhouden.
        config.userContentController.addUserScript(WKUserScript(source: transitionsJS,
                                                                injectionTime: .atDocumentEnd,
                                                                forMainFrameOnly: true))
        // 4 of 5 kolommen in liggende stand (zie Columns.swift)
        config.userContentController.addUserScript(ColumnSetting.shared.script)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true   // veeg terug zoals in een app
        webView.allowsLinkPreview = false   // lang indrukken is voor ons eigen menu, niet voor iOS-linkvoorbeeld
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator

        // Omlaag trekken om te verversen
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator,
                          action: #selector(Coordinator.reload(_:)),
                          for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        context.coordinator.attach(webView, refresh: refresh)
        bridge.webView = webView
        bridge.transitions = context.coordinator.transitions
        ColumnSetting.shared.webView = webView

        // Eerst de bewaarde login terugzetten, pas daarna de pagina laden
        Task {
            await CookieVault.restore()
            webView.load(URLRequest(url: URL(string: "https://nl.pinterest.com/")!))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        weak var webView: WKWebView?
        let transitions = PinTransitions()
        private var refresh: UIRefreshControl?
        private var urlObservation: NSKeyValueObservation?
        private var panStartedAtTop = false

        func attach(_ webView: WKWebView, refresh: UIRefreshControl) {
            self.webView = webView
            self.refresh = refresh
            transitions.webView = webView
            // Pinterest wisselt van pagina zonder te herladen; de URL volgen we daarom zo
            urlObservation = webView.observe(\.url) { [weak self] _, _ in
                Task { @MainActor in self?.updateForPage() }
            }
            webView.scrollView.panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
        }

        private var isPinPage: Bool { webView?.url?.path.contains("/pin/") == true }

        // Op een geopende pin is omlaag trekken "sluiten", dus daar geen verversen
        private func updateForPage() {
            guard let webView else { return }
            let wanted = isPinPage ? nil : refresh
            if webView.scrollView.refreshControl !== wanted { webView.scrollView.refreshControl = wanted }
            transitions.pageChanged()

            // Na de kolommenwissel (andere viewport) kan de pagina zijwaarts verschoven blijven staan,
            // waardoor een pin aan de zijkant afgesneden lijkt. Dan terugzetten naar de linkerrand.
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                let scrollView = webView.scrollView
                let fits = scrollView.contentSize.width <= scrollView.bounds.width + 1
                if fits && abs(scrollView.contentOffset.x) > 0.5 {
                    scrollView.setContentOffset(CGPoint(x: 0, y: scrollView.contentOffset.y), animated: false)
                }
            }
        }

        // Geopende pin sluiten door bovenaan naar beneden te swipen
        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let webView, isPinPage else { return }
            let scrollView = webView.scrollView
            let atTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
            switch pan.state {
            case .began:
                panStartedAtTop = atTop
            case .ended:
                let move = pan.translation(in: scrollView)
                let pulled = -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top)
                let downward = move.y > 100 && abs(move.x) < move.y * 0.6
                if panStartedAtTop && downward && pulled > 60 && webView.canGoBack {
                    transitions.dismissPin(pulled: pulled)   // met terugvlieg-animatie
                }
            default:
                break
            }
        }

        @objc func reload(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        // Na elke geladen pagina de cookies bewaren (dus ook direct na het inloggen)
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await CookieVault.save() }
            updateForPage()
        }

        // Links die een nieuw venster willen openen, gewoon in dezelfde weergave laden
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

// JavaScript-filter: haalt advertentie-pins uit de data vóórdat Pinterest het raster bouwt.
// Zet SHOW_COUNTER op false als je de teller linksonder niet meer wilt zien.
let adFilterJS = #"""
(() => {
  'use strict';
  const SHOW_COUNTER = true;
  let removed = 0;

  // Een item is een advertentie als het (of zijn .node) een promotie-ID heeft
  const isPromoted = (o) => {
    if (!o || typeof o !== 'object' || Array.isArray(o)) return false;
    if (o.pin_promotion_id || o.is_promoted === true) return true;
    const n = o.node;
    return !!(n && typeof n === 'object' && (n.pin_promotion_id || n.is_promoted === true));
  };

  // Loop recursief door de data en haal advertenties weg
  const prune = (node, depth) => {
    if (!node || typeof node !== 'object' || depth > 50) return;
    if (Array.isArray(node)) {
      for (let i = node.length - 1; i >= 0; i--) {
        if (isPromoted(node[i])) { node.splice(i, 1); removed++; }
        else prune(node[i], depth + 1);
      }
      return;
    }
    for (const key of Object.keys(node)) {
      const value = node[key];
      // Lijsten die op pin-ID zijn geordend, zoals { "123456": {...pin} }
      if (/^\d+$/.test(key) && isPromoted(value)) { delete node[key]; removed++; }
      else prune(value, depth + 1);
    }
  };

  let badge = null;
  const updateBadge = () => {
    if (!SHOW_COUNTER || !document.body) return;
    if (!badge) {
      badge = document.createElement('div');
      badge.style.cssText = 'position:fixed;left:8px;bottom:8px;z-index:2147483647;' +
        'padding:4px 8px;border-radius:8px;background:rgba(0,0,0,.6);color:#fff;' +
        'font:12px -apple-system,sans-serif;pointer-events:none';
      document.body.appendChild(badge);
    }
    badge.textContent = 'Advertenties weggefilterd: ' + removed;
  };
  document.addEventListener('DOMContentLoaded', updateBadge);

  // 1. JSON.parse: hier komen de beginstatus van de pagina en de meeste API-data langs
  const MARKERS = /pin_promotion_id|"is_promoted":\s*true/;
  const originalParse = JSON.parse;
  JSON.parse = function (text, reviver) {
    const result = originalParse.call(this, text, reviver);
    try {
      if (typeof text === 'string' && MARKERS.test(text)) { prune(result, 0); updateBadge(); }
    } catch (e) {}
    return result;
  };

  // 2. fetch(): response.json() omleiden via de aangepaste JSON.parse
  Response.prototype.json = function () {
    return this.text().then((t) => JSON.parse(t));
  };

  // 3. XMLHttpRequest met responseType 'json'
  const desc = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'response');
  if (desc && desc.get) {
    Object.defineProperty(XMLHttpRequest.prototype, 'response', {
      configurable: true,
      enumerable: desc.enumerable,
      get() {
        const r = desc.get.call(this);
        if (this.responseType === 'json' && r && typeof r === 'object') {
          try { prune(r, 0); updateBadge(); } catch (e) {}
        }
        return r;
      }
    });
  }
})();
"""#

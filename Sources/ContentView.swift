import SwiftUI
import WebKit

// Pinterest zonder advertenties.
// Werkende versie uit Swift Playgrounds (getest op iPad).

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        PinterestView()
            .ignoresSafeArea(edges: .bottom)
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

        // Het filter draait vóór alle code van Pinterest zelf
        let script = WKUserScript(source: adFilterJS,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: true)
        config.userContentController.addUserScript(script)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true   // veeg terug zoals in een app
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator

        // Omlaag trekken om te verversen
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator,
                          action: #selector(Coordinator.reload(_:)),
                          for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        context.coordinator.webView = webView

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

        @objc func reload(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        // Na elke geladen pagina de cookies bewaren (dus ook direct na het inloggen)
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await CookieVault.save() }
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

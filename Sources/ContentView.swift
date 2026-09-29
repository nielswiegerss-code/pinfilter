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
        // Voor de pagina-analyse: welke advertentievelden kwamen er door het filter heen (zie Columns.swift)
        config.userContentController.addUserScript(WKUserScript(source: adProbeJS,
                                                                injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))

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
        // Achtergrond volgt licht/donker, zodat er bij laden of verversen niets wit flitst
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.underPageBackgroundColor = .systemBackground

        // Omlaag trekken om te verversen
        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator,
                          action: #selector(Coordinator.reload(_:)),
                          for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        context.coordinator.attach(webView, refresh: refresh)
        bridge.webView = webView
        bridge.transitions = context.coordinator.transitions
        let layoutBridge = LayoutBridge()   // meldingen over de pin-opmaak en viewport (zie Transitions.swift)
        layoutBridge.transitions = context.coordinator.transitions
        webView.configuration.userContentController.add(layoutBridge, name: "pfLayout")
        bridge.longPress = context.coordinator.longPressMenu   // plek van de pin bij touchstart (zie PinSave.swift)
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
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, UIGestureRecognizerDelegate {
        weak var webView: WKWebView?
        let transitions = PinTransitions()
        let longPressMenu = LongPressMenu()
        private var refresh: UIRefreshControl?
        private var urlObservation: NSKeyValueObservation?
        private let dismissPan = UIPanGestureRecognizer()

        func attach(_ webView: WKWebView, refresh: UIRefreshControl) {
            self.webView = webView
            self.refresh = refresh
            transitions.webView = webView
            longPressMenu.attach(to: webView)   // lang indrukken op een pin (zie LongPressMenu.swift)
            // Pinterest wisselt van pagina zonder te herladen; de URL volgen we daarom zo
            urlObservation = webView.observe(\.url) { [weak self] _, _ in
                Task { @MainActor in self?.updateForPage() }
            }
            // Eigen sleepgebaar om een geopende pin weg te swipen (zie Transitions.swift)
            dismissPan.addTarget(self, action: #selector(handleDismissPan(_:)))
            dismissPan.delegate = self
            webView.addGestureRecognizer(dismissPan)
        }

        private var isPinPage: Bool { webView?.url?.path.contains("/pin/") == true }

        // Op een geopende pin is omlaag trekken "sluiten", dus daar geen verversen
        private func updateForPage() {
            guard let webView else { return }
            let wanted = isPinPage ? nil : refresh
            if webView.scrollView.refreshControl !== wanted { webView.scrollView.refreshControl = wanted }
            // Op een pin geen "elastiek" bovenaan: daar neemt het wegswipen het over
            webView.scrollView.bounces = !isPinPage
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

        // Geopende pin wegswipen: bovenaan de pin naar beneden slepen
        @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
            guard let webView else { return }
            let t = pan.translation(in: webView)
            switch pan.state {
            case .began:
                webView.scrollView.isScrollEnabled = false   // de pagina eronder niet laten meescrollen
                transitions.beginDrag()
            case .changed:
                transitions.updateDrag(translation: t)
            case .ended:
                webView.scrollView.isScrollEnabled = true
                transitions.endDrag(translation: t, velocity: pan.velocity(in: webView))
            case .cancelled, .failed:
                webView.scrollView.isScrollEnabled = true
                transitions.endDrag(translation: .zero, velocity: .zero)
            default:
                break
            }
        }

        // Het sleepgebaar start alleen op een pinpagina, helemaal bovenaan, bij een beweging omlaag
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard gestureRecognizer === dismissPan else { return true }
            guard let webView, isPinPage, webView.canGoBack, webView.scrollView.isScrollEnabled else { return false }
            let scrollView = webView.scrollView
            let atTop = scrollView.contentOffset.y <= -scrollView.adjustedContentInset.top + 1
            let v = dismissPan.velocity(in: webView)
            return atTop && v.y > 0 && abs(v.x) < v.y
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
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

  // Een item is een advertentie als het (of zijn .node) een promotie-ID heeft.
  // Pinterests oudere data gebruikt snake_case (pin_promotion_id, is_promoted); de nieuwere
  // GraphQL-data (o.a. "More to explore" onder een geopende pin) camelCase: pinPromotionId,
  // isPromoted, en "promoter" (de adverteerder; bij gewone pins null).
  // Ook "doorgeplaatste" advertenties (een opgeslagen advertentie die als gewone pin verschijnt,
  // maar geopend "Ad" toont): is_downstream_promotion, en adData (bij gewone pins null).
  const adFlags = (x) => !!(x.pin_promotion_id || x.is_promoted === true ||
    x.pinPromotionId || x.isPromoted === true || (x.promoter && typeof x.promoter === 'object') ||
    x.is_downstream_promotion === true || x.isDownstreamPromotion === true ||
    (x.adData && typeof x.adData === 'object') || (x.ad_data && typeof x.ad_data === 'object'));
  const isPromoted = (o) => {
    if (!o || typeof o !== 'object' || Array.isArray(o)) return false;
    if (adFlags(o)) return true;
    const n = o.node;
    return !!(n && typeof n === 'object' && !Array.isArray(n) && adFlags(n));
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
  const MARKERS = /pin_promotion_id|"is_promoted":\s*true|"isPromoted":\s*true|"pinPromotionId":\s*"?[1-9]|"promoter":\s*\{|"is_downstream_promotion":\s*true|"isDownstreamPromotion":\s*true|"ad_?[dD]ata":\s*\{/;
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

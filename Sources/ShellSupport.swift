import UIKit
import WebKit
import SafariServices

// Hulpjes voor de app-schil rond de webview (zie PinterestView in ContentView.swift):
// welke sites "Pinterest" zijn, waar externe links heen gaan, en de brug van JavaScript naar de app.

enum ShellHost {
    static let home = URL(string: "https://nl.pinterest.com/")!

    // Pinterest heeft per land een eigen domein (pinterest.nl, pinterest.co.uk, pinterest.com.au, ...)
    private static let pinterestPattern = #"^([a-z0-9-]+\.)*pinterest\.(com|[a-z]{2}|(co|com)\.[a-z]{2})$"#

    static func isPinterest(_ host: String?) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return false }
        return host.range(of: pinterestPattern, options: .regularExpression) != nil
    }

    // Hoort deze host bij de app zelf? (Pinterest, plus zijn verkorte links)
    static func isInternal(_ host: String?) -> Bool {
        isPinterest(host) || host?.lowercased() == "pin.it"
    }

    // Inloggen met Google of Apple (door Pinterest zelf gebruikt) moet in de webview blijven werken
    static func isAuth(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        if host == "accounts.google.com" || host == "appleid.apple.com" || host == "idmsa.apple.com" { return true }
        if host == "facebook.com" || host.hasSuffix(".facebook.com") {
            let path = url.path.lowercased()
            return path.contains("dialog") || path.contains("login") || path.contains("oauth")
        }
        return false
    }

    // Onze scripts mogen alleen op Pinterest-pagina's iets doen (niet op andere sites, en niet op
    // lege pagina's zonder hostnaam). Het script zelf blijft ongewijzigd, het staat alleen in een "if".
    // Let op: dit moet om de hele tekst heen, dus ook om een "const PF_APP_ZOOM = ...;" ervoor.
    static func guarded(_ js: String) -> String {
        #"if (/(^|\.)pinterest\.(com|[a-z]{2}|(co|com)\.[a-z]{2})$/.test(location.hostname)) {"# + "\n" + js + "\n}"
    }

    static func userScript(_ js: String, at time: WKUserScriptInjectionTime) -> WKUserScript {
        WKUserScript(source: guarded(js), injectionTime: time, forMainFrameOnly: true)
    }

    // Een bestaand script (bijvoorbeeld van ColumnSetting) alsnog achter de hostcontrole zetten
    static func userScript(guarding script: WKUserScript) -> WKUserScript {
        WKUserScript(source: guarded(script.source), injectionTime: script.injectionTime,
                     forMainFrameOnly: script.isForMainFrameOnly)
    }
}

// Waar gaat een link heen?
enum ShellNavigation {
    enum Route {
        case allow            // gewoon in de webview
        case cancel           // nergens heen
        case safari(URL)      // in een los venster (SFSafariViewController)
        case system(URL)      // aan iOS geven (mailto, tel, App Store)
    }

    private static let systemSchemes: Set<String> = ["mailto", "tel", "sms", "facetime", "itms-apps", "itms-appss", "maps"]

    static func route(_ url: URL, type: WKNavigationType, isMainFrame: Bool, isNewWindow: Bool) -> Route {
        let scheme = url.scheme?.lowercased() ?? ""
        if ["about", "blob", "data", "javascript"].contains(scheme) { return .allow }
        if scheme != "http" && scheme != "https" {
            // pinterest://, intent://, ...: nergens heen. Alleen bewuste tikken op mail/tel/App Store gaan naar iOS.
            if (type == .linkActivated || isNewWindow) && systemSchemes.contains(scheme) { return .system(url) }
            return .cancel
        }
        // Iframes (captcha's, Google One Tap) laten we met rust
        guard isMainFrame || isNewWindow else { return .allow }
        guard let host = url.host, !host.isEmpty else { return .cancel }
        if ShellHost.isInternal(host) && !isOffsite(url) { return .allow }
        if ShellHost.isAuth(url) { return .allow }
        // Alleen echte tikken en nieuwe vensters omleiden; doorverwijzingen (inloggen) blijven in de webview
        guard type == .linkActivated || isNewWindow else { return .allow }
        if let real = offsiteTarget(url) {
            return ShellHost.isInternal(real.host) ? .allow : .safari(real)
        }
        return ShellHost.isInternal(host) ? .allow : .safari(url)
    }

    private static func isOffsite(_ url: URL) -> Bool { url.path.hasPrefix("/offsite") }

    // Pinterests doorverwijslink (pinterest.com/offsite/?url=...): pak het echte adres eruit
    private static func offsiteTarget(_ url: URL) -> URL? {
        guard ShellHost.isPinterest(url.host), isOffsite(url),
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "url" })?.value,
              let real = URL(string: raw), real.host != nil,
              let scheme = real.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
        return real
    }

    // Voer de gekozen route uit. Geeft true als de link daarmee is afgehandeld (niet in de webview laden).
    @MainActor
    @discardableResult
    static func perform(_ route: Route, from view: UIView?) -> Bool {
        switch route {
        case .allow:
            return false
        case .cancel:
            return true
        case .safari(let url):
            presentSafari(url, from: view)
            return true
        case .system(let url):
            UIApplication.shared.open(url)
            return true
        }
    }

    // SFSafariViewController stort neer bij iets anders dan http(s); de route hierboven staat dat niet toe
    @MainActor
    private static func presentSafari(_ url: URL, from view: UIView?) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        var top = view?.window?.rootViewController
        if top == nil {
            top = UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        }
        while let presented = top?.presentedViewController { top = presented }
        guard let top, !(top is SFSafariViewController) else { return }
        top.present(SFSafariViewController(url: url), animated: true)
    }
}

// Brug van JavaScript naar de app, met een controle op de afzender: alleen de hoofdpagina van
// Pinterest mag de app aansturen. Een ander adres (of een iframe) wordt genegeerd. Berichten van
// het type "ready" (de eerste pin is getekend) handelt de schil zelf af; de rest gaat naar NativeBridge.
final class ShellBridgeGate: NSObject, WKScriptMessageHandler {
    private let inner: WKScriptMessageHandler
    var onReady: (@MainActor () -> Void)?

    init(inner: WKScriptMessageHandler) { self.inner = inner }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              ShellHost.isPinterest(message.frameInfo.securityOrigin.host) else { return }
        if let body = message.body as? [String: Any], (body["type"] as? String) == "ready" {
            MainActor.assumeIsolated { onReady?() }
            return
        }
        MainActor.assumeIsolated { inner.userContentController(userContentController, didReceive: message) }
    }
}

// WKWebView die meldt als zijn formaat verandert (draaien, Split View, venster verslepen op iPadOS 26)
final class ShellWebView: WKWebView {
    var onSizeChange: ((CGSize) -> Void)?
    private var lastSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != lastSize else { return }
        let first = lastSize == .zero
        lastSize = bounds.size
        if !first { onSizeChange?(bounds.size) }
    }
}

// Meldt aan de pagina-kant "de eerste pin staat er" (of, op pagina's zonder raster, dat er inhoud is),
// zodat de app de laadschermafdekking kan weghalen. Draait via ShellHost.guarded, dus alleen op Pinterest.
let shellReadyJS = #"""
(() => {
  let done = false;
  const native = (m) => { try { webkit.messageHandlers.pfNative.postMessage(m); } catch (e) {} };
  const fin = () => { if (done) return; done = true; clearInterval(timer); native({ type: 'ready' }); };
  const start = Date.now();
  const check = () => {
    // Een getekende afbeelding in het raster, of in de grote afbeelding van een geopende pin
    for (const img of document.querySelectorAll('[data-grid-item] img, [data-test-id="closeup-body"] img')) {
      if (img.complete && img.naturalWidth > 0) { fin(); return; }
    }
    // Pagina's zonder raster (inloggen, foutmelding): klaar zodra er tekst staat
    if (Date.now() - start > 2500 && !document.querySelector('[data-grid-item]') &&
        document.body && (document.body.innerText || '').trim().length > 50) fin();
  };
  const timer = setInterval(() => { check(); if (Date.now() - start > 15000) clearInterval(timer); }, 250);
  check();
})();
"""#

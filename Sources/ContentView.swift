import SwiftUI
import WebKit
import Network

// Pinterest zonder advertenties.
// Werkende versie uit Swift Playgrounds (getest op iPad).

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var site = SiteModel()

    var body: some View {
        GeometryReader { geo in
            // Beide weergaven blijven in de hiërarchie zodra ze bestaan (nooit een "if" om een webview heen:
            // dat zou hem weggooien en een spelende video stoppen). Wisselen = doorzichtigheid.
            // YouTube wordt pas bij de eerste keer wisselen gemaakt, zodat het opstarten van Pinterest gelijk blijft.
            ZStack {
                PinterestView()
                    .opacity(site.current == .pinterest ? 1 : 0)
                    .allowsHitTesting(site.current == .pinterest)
                    .accessibilityHidden(site.current != .pinterest)
                if site.youtubeStarted {
                    YouTubeView(model: site, active: site.current == .youtube)
                        .opacity(site.current == .youtube ? 1 : 0)
                        .allowsHitTesting(site.current == .youtube)
                        .accessibilityHidden(site.current != .youtube)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottomTrailing) {
                // Kolommenknop alleen op Pinterest en liggend; staand bepaalt Pinterest het zelf
                if site.current == .pinterest && geo.size.width > geo.size.height { ColumnButton() }
            }
            .overlay(alignment: .topTrailing) {
                SiteSwitcher(model: site, size: geo.size)
            }
            .animation(.easeInOut(duration: 0.2), value: site.current)
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
        // Alle scripts staan achter een hostcontrole (ShellHost.guarded): ze doen alleen iets op Pinterest,
        // niet op andere sites of lege pagina's. De scripts zelf zijn daarvoor niet aangepast.
        config.userContentController.addUserScript(ShellHost.userScript(adFilterJS, at: .atDocumentStart))
        // Voor de pagina-analyse: welke advertentievelden kwamen er door het filter heen (zie Columns.swift)
        config.userContentController.addUserScript(ShellHost.userScript(adProbeJS, at: .atDocumentStart))

        // Lang indrukken op een pin = rond menu om op te slaan (los van het advertentiefilter)
        config.userContentController.addUserScript(ShellHost.userScript(pinSaveJS, at: .atDocumentEnd))
        // De brug naar de app luistert alleen naar de hoofdpagina van Pinterest (zie ShellBridgeGate)
        let bridge = NativeBridge()
        let gate = ShellBridgeGate(inner: bridge)
        config.userContentController.add(gate, name: "pfNative")
        // Meldt dat de eerste pin getekend is, zodat het startscherm weg kan
        config.userContentController.addUserScript(ShellHost.userScript(shellReadyJS, at: .atDocumentEnd))

        // Kleine layoutaanpassingen, zoals de inbox-knop verbergen (zie PageTweaks.swift)
        config.userContentController.addUserScript(ShellHost.userScript(pageTweaksJS, at: .atDocumentEnd))
        // Open-animatie: tik op een pin even vasthouden en de app laten animeren (zie Transitions.swift).
        // Na pinSaveJS, zodat het lang-indrukken-menu een klik eerst kan tegenhouden.
        config.userContentController.addUserScript(ShellHost.userScript(transitionsJS, at: .atDocumentEnd))
        // 4 of 5 kolommen in liggende stand (zie Columns.swift)
        config.userContentController.addUserScript(ShellHost.userScript(guarding: ColumnSetting.shared.script))

        let webView = ShellWebView(frame: .zero, configuration: config)
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
        gate.onReady = { [weak coordinator = context.coordinator] in coordinator?.markReady() }
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
            webView.load(URLRequest(url: ShellHost.home))
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
        private var progressObservation: NSKeyValueObservation?
        private var loadingObservation: NSKeyValueObservation?
        private let dismissPan = UIPanGestureRecognizer()

        // MARK: Laadstatus
        // Eén plek die bepaalt wat er over de webview ligt (zie ShellLoadView.swift):
        // .launching = startscherm met spinner, .ready = de pagina zelf, .failed = "geen verbinding".
        private enum Phase { case launching, ready, failed }
        private var phase = Phase.launching
        private let loadView = ShellLoadView()
        private var hasCommitted = false          // is er in deze ronde al een pagina binnengekomen?
        private var failedOffline = false         // de laatste fout was een verbindingsprobleem
        private var readyTask: Task<Void, Never>?
        private var recoveryTask: Task<Void, Never>?
        private var refreshTask: Task<Void, Never>?
        private var crashDates: [Date] = []
        private var backgroundedAt: Date?
        private var scrollLocks = Set<String>()
        private let pathMonitor = NWPathMonitor()

        deinit { pathMonitor.cancel() }

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

            // Startscherm, voortgangsbalk en foutmelding liggen als één laag over de webview
            loadView.frame = webView.bounds
            loadView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            loadView.onRetry = { [weak self] in self?.retry() }
            webView.addSubview(loadView)
            progressObservation = webView.observe(\.estimatedProgress) { [weak self] _, _ in
                Task { @MainActor in self?.syncProgress() }
            }
            loadingObservation = webView.observe(\.isLoading) { [weak self] _, _ in
                Task { @MainActor in self?.syncProgress() }
            }
            beginLaunch()

            // Formaat veranderd (draaien, Split View, venster slepen): losse lagen kloppen dan niet meer
            (webView as? ShellWebView)?.onSizeChange = { [weak self] _ in self?.resetInteractionState() }

            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(appDidEnterBackground),
                               name: UIApplication.didEnterBackgroundNotification, object: nil)
            center.addObserver(self, selector: #selector(appWillEnterForeground),
                               name: UIApplication.willEnterForegroundNotification, object: nil)
            center.addObserver(self, selector: #selector(didReceiveMemoryWarning),
                               name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
            // Komt de verbinding terug terwijl het "geen verbinding"-scherm staat, dan vanzelf opnieuw proberen
            pathMonitor.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                Task { @MainActor in self?.networkCameBack() }
            }
            pathMonitor.start(queue: DispatchQueue(label: "nl.niels.pinfilter.path", qos: .utility))
        }

        // Alleen een pinpagina van Pinterest zelf; een pad met "/pin/" op een andere site telt niet mee
        private var isPinPage: Bool {
            guard let url = webView?.url, ShellHost.isPinterest(url.host) else { return false }
            return url.path.contains("/pin/")
        }

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

        // MARK: Scrollen vergrendelen
        // Scrollen uit/aan gaat via benoemde redenen, zodat het ene gebaar het andere niet per ongeluk
        // weer aanzet. (Het lang-indrukken-menu schrijft zelf nog rechtstreeks; zie resetInteractionState.)

        private func lockScroll(_ reason: String) {
            scrollLocks.insert(reason)
            webView?.scrollView.isScrollEnabled = false
        }

        private func unlockScroll(_ reason: String) {
            scrollLocks.remove(reason)
            if scrollLocks.isEmpty { webView?.scrollView.isScrollEnabled = true }
        }

        // Alles wat tijdelijk over de pagina ligt of scrollen blokkeert direct opruimen: na een gecrasht
        // webproces, bij een formaatwissel of als het geheugen krap is.
        func resetInteractionState() {
            transitions.reset()
            longPressMenu.reset()
            scrollLocks.removeAll()
            // Een lopend sleepgebaar afbreken (uit en weer aan zetten geeft .cancelled)
            if dismissPan.isEnabled {
                dismissPan.isEnabled = false
                dismissPan.isEnabled = true
            }
            webView?.scrollView.isScrollEnabled = true
        }

        // Geopende pin wegswipen: bovenaan de pin naar beneden slepen
        @objc private func handleDismissPan(_ pan: UIPanGestureRecognizer) {
            guard let webView else { return }
            let t = pan.translation(in: webView)
            switch pan.state {
            case .began:
                longPressMenu.dropLift()   // een beginnend "optillen" van een pin mag niet blijven hangen
                lockScroll("dismiss")   // de pagina eronder niet laten meescrollen
                transitions.beginDrag()
            case .changed:
                transitions.updateDrag(translation: t)
            case .ended:
                unlockScroll("dismiss")
                transitions.endDrag(translation: t, velocity: pan.velocity(in: webView))
            case .cancelled, .failed:
                unlockScroll("dismiss")
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

        // MARK: Startscherm, voortgang en fouten

        private func beginLaunch() {
            phase = .launching
            hasCommitted = false
            failedOffline = false
            loadView.hideFailure()
            loadView.showPlaceholder()
            readyTask?.cancel()
            // Vangnet: nooit blijvend afgedekt. Duurt het laden nog (en is er niets binnen), dan wachten we door.
            readyTask = Task { [weak self] in
                while true {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    if self.webView?.isLoading == true && !self.hasCommitted { continue }
                    self.markReady()
                    return
                }
            }
        }

        // De eerste pin is getekend (melding van shellReadyJS), of een vangnet ging af
        func markReady() {
            guard phase == .launching else { return }
            phase = .ready
            readyTask?.cancel()
            readyTask = nil
            loadView.hidePlaceholder()
        }

        private func syncProgress() {
            guard let webView else { return }
            loadView.updateProgress(webView.estimatedProgress, loading: webView.isLoading)
        }

        private func showFailed(_ error: NSError) {
            phase = .failed
            readyTask?.cancel()
            readyTask = nil
            let url = error.domain == NSURLErrorDomain
            let offline = url && [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                                  NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff].contains(error.code)
            let slow = url && error.code == NSURLErrorTimedOut
            // Bij een verbindingsprobleem probeert de app het vanzelf opnieuw zodra er internet is
            failedOffline = offline || slow ||
                (url && [NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed].contains(error.code))
            if offline {
                loadView.showFailure(title: "Geen verbinding",
                                     message: "Controleer of je iPad online is. Pins probeert het vanzelf opnieuw zodra er internet is.")
            } else if slow {
                loadView.showFailure(title: "Duurt te lang",
                                     message: "Pinterest reageert niet. Probeer het zo nog eens.")
            } else {
                loadView.showFailure(title: "Pinterest laadt niet",
                                     message: "De pagina kon niet worden geladen. Probeer het zo nog eens.")
            }
        }

        // Een mislukte lading. Geannuleerde ladingen (bijvoorbeeld door het wegswipen van een pin of een
        // omgeleide link) zijn geen fout.
        private func handleFailure(_ error: Error) {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
            if ns.domain == "WebKitErrorDomain" && ns.code == 102 { return }   // "frame load interrupted": beleid koos anders
            endRefreshing()
            if phase == .ready {
                // Er staat al een pagina: die laten staan, alleen even melden
                loadView.toast("Geen verbinding")
            } else {
                showFailed(ns)
            }
        }

        // "Probeer opnieuw" (of de verbinding is terug). Na een mislukte start staat er nog geen pagina,
        // en dan doet reload() niets: opnieuw de startpagina laden.
        func retry() {
            guard let webView else { return }
            let fresh = phase == .failed || webView.url == nil || webView.url?.scheme == "about"
            crashDates.removeAll()
            recoveryTask?.cancel()
            beginLaunch()
            if fresh {
                webView.load(URLRequest(url: ShellHost.home))
            } else {
                webView.reload()
            }
        }

        private func networkCameBack() {
            if phase == .failed && failedOffline { retry() }
        }

        // MARK: Verversen

        @objc func reload(_ sender: UIRefreshControl) {
            guard let webView else { sender.endRefreshing(); return }
            // Zonder geladen pagina (bijvoorbeeld na een mislukte start) doet reload() niets: dan de startpagina laden
            if phase == .failed || webView.url == nil || webView.url?.scheme == "about" {
                retry()
            } else {
                webView.reload()
            }
            // De spinner blijft draaien tot de pagina binnen is (didFinish), met een vangnet van 8 s
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                self?.endRefreshing()
            }
        }

        private func endRefreshing() {
            refreshTask?.cancel()
            refreshTask = nil
            refresh?.endRefreshing()
        }

        // MARK: Achtergrond, geheugen

        @objc private func appDidEnterBackground() {
            backgroundedAt = Date()
        }

        // Komt de app terug na lange tijd, dan is de feed oud: ververs die (alleen op de startpagina)
        @objc private func appWillEnterForeground() {
            let since = backgroundedAt
            backgroundedAt = nil
            guard let webView else { return }
            if phase == .failed { retry(); return }
            guard let since, phase == .ready, !webView.isLoading,
                  Date().timeIntervalSince(since) > 30 * 60,
                  webView.url?.path == "/" || webView.url?.path == "" else { return }
            beginLaunch()
            webView.reload()
        }

        // Weinig geheugen: in de achtergrond tijdelijke lagen (momentopnames) direct opruimen
        @objc private func didReceiveMemoryWarning() {
            if UIApplication.shared.applicationState != .active { resetInteractionState() }
        }

        // MARK: WKNavigationDelegate

        // Welke links blijven in de app en welke gaan naar een los venster of naar iOS (zie ShellNavigation)
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .cancel }
            let route = ShellNavigation.route(url,
                                              type: navigationAction.navigationType,
                                              isMainFrame: navigationAction.targetFrame?.isMainFrame ?? true,
                                              isNewWindow: navigationAction.targetFrame == nil)
            if case .allow = route { return .allow }
            ShellNavigation.perform(route, from: webView)
            return .cancel
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            hasCommitted = true
            // Was het "geen verbinding"-scherm nog zichtbaar, maar komt er nu toch een pagina: terug naar laden
            if phase == .failed {
                loadView.hideFailure()
                loadView.showPlaceholder()
                phase = .launching
            }
        }

        // Na elke geladen pagina de cookies bewaren (dus ook direct na het inloggen)
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            endRefreshing()
            Task { await CookieVault.save() }
            updateForPage()
            // Pagina zonder getekende pin (bijvoorbeeld inloggen): na enkele seconden toch tonen
            if phase == .launching {
                readyTask?.cancel()
                readyTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard !Task.isCancelled else { return }
                    self?.markReady()
                }
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleFailure(error)
        }

        // iOS stopt het webproces als het geheugen op is (Pinterest is zwaar). Zonder herstel blijft het scherm leeg.
        // Eén keer: gewoon herladen. Vaker binnen een minuut: steeds langer wachten, en na vier keer stoppen met
        // "Probeer opnieuw" (geen eindeloze lus).
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            resetInteractionState()
            endRefreshing()
            let now = Date()
            crashDates = crashDates.filter { now.timeIntervalSince($0) < 60 } + [now]
            let count = crashDates.count
            beginLaunch()
            if count > 4 {
                showFailed(NSError(domain: WKErrorDomain, code: WKError.webContentProcessTerminated.rawValue))
                return
            }
            let delay = count == 1 ? 0 : min(pow(2.0, Double(count - 2)), 8)
            recoveryTask?.cancel()
            recoveryTask = Task { [weak self] in
                if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                guard !Task.isCancelled, let self, let webView = self.webView, self.phase == .launching else { return }
                if count == 1, webView.url != nil { webView.reload() } else { webView.load(URLRequest(url: ShellHost.home)) }
            }
        }

        // MARK: WKUIDelegate

        // Links die een nieuw venster willen openen: Pinterest blijft in dezelfde weergave,
        // andere sites gaan naar een los venster (nooit een lege of about:blank-pagina laden)
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard navigationAction.targetFrame == nil, let url = navigationAction.request.url else { return nil }
            let route = ShellNavigation.route(url, type: navigationAction.navigationType,
                                              isMainFrame: true, isNewWindow: true)
            if ShellNavigation.perform(route, from: webView) { return nil }
            if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
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

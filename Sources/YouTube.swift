import AVFoundation
import SwiftUI
import UIKit
import WebKit

// YouTube in dezelfde app, naast Pinterest. Een tweede WKWebView die pas bij de eerste keer wisselen
// wordt gemaakt en daarna blijft leven (zodat een video doorspeelt en er niets opnieuw laadt).
// Pinterests eigen code (PinterestView, filter, animaties, kolommen) blijft er volledig buiten.
//
// Ontwerpkeuzes:
// - Startpagina is Abonnementen; "Home" (/) stuurt daar naartoe, Shorts-links openen als gewone video.
// - Inloggen: gewoon YouTubes eigen inlogpagina (geen OAuth). Google kijkt naar de browser-identiteit, dus
//   deze weergave geeft zich uit voor precies Safari (zie YouTubeIdentity) en heeft GEEN
//   WKScriptMessageHandler (Safari heeft er ook geen). Elk script slaat accounts.google.com over.
// - Geen scripts die van buiten worden opgehaald: alles zit in de app (YouTubeScripts.swift).
// - Cookies (YouTube + Google) staan net als die van Pinterest in de Keychain-kluis (CookieVault.swift).

enum Site: String {
    case pinterest, youtube
}

// Welke site is zichtbaar, en of YouTube al gestart is
@MainActor
final class SiteModel: ObservableObject {
    @Published private(set) var current: Site
    @Published private(set) var youtubeStarted: Bool
    // Op een video-pagina tonen we naast de wisselknop een PiP-knop
    @Published var youtubeOnWatchPage = false
    weak var youtubeWebView: WKWebView?

    init() {
        // Onthoud de laatste site; bij twijfel (niets bewaard of onbekende waarde) Pinterest
        let saved = UserDefaults.standard.string(forKey: "lastSite").flatMap(Site.init(rawValue:)) ?? .pinterest
        current = saved
        youtubeStarted = saved == .youtube
    }

    func toggle() { switchTo(current == .pinterest ? .youtube : .pinterest) }

    func switchTo(_ site: Site) {
        guard site != current else { return }
        if site == .youtube { youtubeStarted = true }
        current = site
        UserDefaults.standard.set(site.rawValue, forKey: "lastSite")
    }

    // Beeld-in-beeld aan/uit voor de video die nu speelt
    func togglePip() {
        youtubeWebView?.evaluateJavaScript("window.__pfPip ? window.__pfPip() : ''") { _, _ in }
    }

    // Testschakelaars (in de YouTube-analyse): scripts aan/uit, daarna de pagina opnieuw laden
    @Published var testFilterOn = YouTubeTest.filterOn
    @Published var testMediaOn = YouTubeTest.mediaOn

    func setTest(filter: Bool, media: Bool) {
        YouTubeTest.filterOn = filter
        YouTubeTest.mediaOn = media
        testFilterOn = filter
        testMediaOn = media
        guard let webView = youtubeWebView else { return }
        let ucc = webView.configuration.userContentController
        ucc.removeAllUserScripts()
        YouTubeTest.install(into: ucc)
        webView.reload()
    }

    // Pagina-analyse van de YouTube-weergave, met de YouTube-sectie eronder
    func youtubeReport() async -> String {
        let base = await PageReport.make(webView: youtubeWebView)
        var probe = "(YouTube is nog niet gestart)"
        if let webView = youtubeWebView {
            probe = (try? await webView.evaluateJavaScript(ytProbeJS) as? String) ?? "(pagina gaf geen antwoord)"
        }
        return base + "\n\n--- YouTube ---\n" + probe
    }
}

// Om uit te zoeken waar het zwarte scherm voor een video vandaan komt: het advertentiefilter en het
// achtergrond-script zijn apart uit te zetten (onthouden). ytLogJS (alleen meten) en ytStyleJS blijven altijd aan.
@MainActor
enum YouTubeTest {
    static var filterOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "ytTestNoFilter") }
        set { UserDefaults.standard.set(!newValue, forKey: "ytTestNoFilter") }
    }
    static var mediaOn: Bool {
        get { !UserDefaults.standard.bool(forKey: "ytTestNoMedia") }
        set { UserDefaults.standard.set(!newValue, forKey: "ytTestNoMedia") }
    }

    static func install(into ucc: WKUserContentController) {
        var sources = [ytLogJS]
        if filterOn { sources.append(ytAdFilterJS) }
        if mediaOn { sources.append(ytMediaJS) }
        sources.append(ytStyleJS)
        for source in sources {
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }
}

enum YouTubeConfig {
    static let startURL = URL(string: "https://m.youtube.com/feed/subscriptions")!
    // Home (/) doorsturen naar Abonnementen. Zet op false als je Home ooit terug wilt.
    static let homeGoesToSubscriptions = true
    static let hosts: Set<String> = ["m.youtube.com", "www.youtube.com", "youtube.com"]
}

// Geluid: een afspeel-sessie is nodig om door te spelen als de app naar de achtergrond gaat of het scherm op slot gaat
// (samen met UIBackgroundModes = audio in Info.plist, dat de bouwstap toevoegt). Pas bij het eerste YouTube-gebruik.
@MainActor
enum YouTubeMedia {
    private static var activated = false

    static func activate() {
        guard !activated else { return }
        activated = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}

// Identiteit: Google blokkeert inloggen in ingebouwde webweergaves. Deze weergave geeft zich daarom uit
// voor precies Safari (de OS-versie komt van het apparaat zelf, niet uit een vaste tekst).
// Sinds v2.1 Safari op een iPhone: met een iPad-identiteit stuurt YouTube de desktopsite (www) met
// zijbalk; met een iPhone-identiteit de mobiele site (m.youtube.com) die op de app lijkt.
@MainActor
enum YouTubeIdentity {
    // Vraagt de webweergave zelf wat hij als user agent stuurt, en bouwt daar de Safari-vorm van
    static func userAgent(for webView: WKWebView) async -> String {
        await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            let once = Once()
            let finish = { (reported: String?) in
                guard !once.done else { return }
                once.done = true
                cont.resume(returning: compose(from: reported))
            }
            webView.evaluateJavaScript("navigator.userAgent") { result, _ in finish(result as? String) }
            // Geen antwoord (bijvoorbeeld voordat er een pagina is): met de systeemversie doorgaan
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                finish(nil)
            }
        }
    }

    private final class Once { var done = false }

    // Safari op iPhone: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)
    // Version/26.0 Mobile/15E148 Safari/604.1". Uit wat de webweergave zelf meldt nemen we het OS-getal en de
    // build; "Version/" en "Safari/" voegen we toe, in de volgorde van Safari.
    static func compose(from reported: String?) -> String {
        let parts = UIDevice.current.systemVersion.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 18
        let minor = parts.count > 1 ? parts[1] : 0
        let version = "\(major).\(minor)"

        // Apple heeft het OS-getal in de user agent bevroren op 18_6 vanaf iOS 26
        var os = major >= 26 ? "18_6" : "\(major)_\(minor)"
        var mobileToken = "15E148"
        var webkit = "AppleWebKit/605.1.15 (KHTML, like Gecko)"
        if let ua = reported {
            if let r = ua.range(of: #"OS (\d+_\d+(_\d+)?) like"#, options: .regularExpression) {
                os = String(ua[r].dropFirst(3).dropLast(5))
            }
            if let m = ua.range(of: " Mobile/") {
                let end = ua[m.upperBound...].firstIndex(of: " ") ?? ua.endIndex
                mobileToken = String(ua[m.upperBound..<end])
            }
            if let w = ua.range(of: #"AppleWebKit/[\d.]+ \(KHTML, like Gecko\)"#, options: .regularExpression) {
                webkit = String(ua[w])
            }
        }
        return "Mozilla/5.0 (iPhone; CPU iPhone OS \(os) like Mac OS X) \(webkit) Version/\(version) Mobile/\(mobileToken) Safari/604.1"
    }
}

struct YouTubeView: UIViewRepresentable {
    let model: SiteModel
    let active: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // zelfde opslag als Pinterest; cookies zijn per domein, dus geen botsing
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []   // volgende video en hervatten zonder aanraking
        config.allowsPictureInPictureMediaPlayback = true

        // Alle scripts: hoofdframe, vóór de code van YouTube, en met een eigen controle op de hostnaam
        YouTubeTest.install(into: config.userContentController)
        // Bewust GEEN userContentController.add(_, name:): dat is in de pagina zichtbaar en Safari heeft dat niet

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true   // veeg terug zoals in een app
        webView.allowsLinkPreview = false
        webView.uiDelegate = context.coordinator
        webView.navigationDelegate = context.coordinator
        // Donkere achtergrond zoals bij Pinterest, zodat er niets wit flitst
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        webView.underPageBackgroundColor = .systemBackground

        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.reload(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        context.coordinator.attach(webView, refresh: refresh)
        model.youtubeWebView = webView
        context.coordinator.attachSwipe()
        YouTubeMedia.activate()

        // Eerst de bewaarde login terugzetten en de Safari-identiteit bepalen, pas daarna laden
        Task {
            await CookieVault.restore()
            webView.customUserAgent = await YouTubeIdentity.userAgent(for: webView)
            webView.load(URLRequest(url: YouTubeConfig.startURL))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        context.coordinator.setActive(active)
    }

    @MainActor
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, UIGestureRecognizerDelegate {
        private let model: SiteModel
        weak var webView: WKWebView?
        private var refresh: UIRefreshControl?
        private var urlObservation: NSKeyValueObservation?
        private var isActive = true
        private var rerouteLog: [Date] = []

        init(model: SiteModel) {
            self.model = model
            super.init()
            // Achtergrondgeluid: de pagina laten weten dat de app weggaat, en de video hervatten
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(appWillResign),
                               name: UIApplication.willResignActiveNotification, object: nil)
            center.addObserver(self, selector: #selector(appDidEnterBackground),
                               name: UIApplication.didEnterBackgroundNotification, object: nil)
            center.addObserver(self, selector: #selector(appDidBecomeActive),
                               name: UIApplication.didBecomeActiveNotification, object: nil)
        }

        func attach(_ webView: WKWebView, refresh: UIRefreshControl) {
            self.webView = webView
            self.refresh = refresh
            // YouTube wisselt van pagina zonder te herladen; de URL volgen we daarom zo
            urlObservation = webView.observe(\.url) { [weak self] _, _ in
                Task { @MainActor in self?.urlChanged() }
            }
        }

        // MARK: Omlaag vegen op een video = terug (zoals de YouTube-app)
        // Alleen op /watch, helemaal bovenaan en bij een beweging omlaag. De hele weergave volgt de vinger
        // als krimpende kaart; ver genoeg (of snel) losgelaten = terug naar de vorige pagina.
        private let swipe = UIPanGestureRecognizer()

        func attachSwipe() {
            guard let webView, swipe.view == nil else { return }
            swipe.addTarget(self, action: #selector(handleSwipe(_:)))
            swipe.delegate = self
            webView.addGestureRecognizer(swipe)
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g === swipe, let webView, isWatchPage else { return false }
            let sv = webView.scrollView
            guard sv.contentOffset.y <= -sv.adjustedContentInset.top + 1 else { return false }
            let v = swipe.velocity(in: webView)
            return v.y > 0 && abs(v.x) < v.y
        }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func handleSwipe(_ pan: UIPanGestureRecognizer) {
            guard let webView, let host = webView.superview else { return }
            let dy = max(0, pan.translation(in: host).y)
            let progress = min(dy / max(host.bounds.height, 1), 1)
            switch pan.state {
            case .began:
                webView.scrollView.isScrollEnabled = false
                webView.layer.cornerCurve = .continuous
                webView.layer.masksToBounds = true
            case .changed:
                let s = 1 - 0.25 * progress
                webView.transform = CGAffineTransform(translationX: 0, y: dy * 0.85).scaledBy(x: s, y: s)
                webView.layer.cornerRadius = 28 * min(progress * 4, 1)
            case .ended, .cancelled, .failed:
                webView.scrollView.isScrollEnabled = true
                let v = pan.velocity(in: host).y
                let commit = pan.state == .ended && (dy > 130 || (v > 700 && dy > 30))
                if commit {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseIn) {
                        webView.transform = CGAffineTransform(translationX: 0, y: host.bounds.height * 0.6).scaledBy(x: 0.6, y: 0.6)
                        webView.alpha = 0
                    } completion: { _ in
                        if webView.canGoBack { webView.goBack() } else { webView.load(URLRequest(url: YouTubeConfig.startURL)) }
                        webView.transform = .identity
                        webView.layer.cornerRadius = 0
                        UIView.animate(withDuration: 0.25, delay: 0.1) { webView.alpha = 1 }
                    }
                } else {
                    UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0) {
                        webView.transform = .identity
                        webView.layer.cornerRadius = 0
                    }
                }
            default:
                break
            }
        }

        // MARK: Zichtbaar of niet

        // Bij het wisselen naar Pinterest de video pauzeren, tenzij die in Beeld-in-beeld staat
        func setActive(_ on: Bool) {
            guard on != isActive else { return }
            isActive = on
            if !on {
                let pause = "(() => { const v = document.querySelector('video'); "
                    + "if (v && !v.paused && v.webkitPresentationMode !== 'picture-in-picture') v.pause(); })()"
                webView?.evaluateJavaScript(pause) { _, _ in }
            }
        }

        // MARK: Achtergrond

        @objc private func appWillResign() {
            webView?.evaluateJavaScript("window.__pfBg && window.__pfBg(true)") { _, _ in }
        }

        @objc private func appDidBecomeActive() {
            webView?.evaluateJavaScript("window.__pfBg && window.__pfBg(false)") { _, _ in }
        }

        // iOS pauzeert de video bij het verlaten van de app; meteen en nog twee keer daarna hervatten
        private final class BackgroundTaskBox { var id = UIBackgroundTaskIdentifier.invalid }

        @objc private func appDidEnterBackground() {
            let box = BackgroundTaskBox()
            let end = {
                guard box.id != .invalid else { return }
                UIApplication.shared.endBackgroundTask(box.id)
                box.id = .invalid
            }
            box.id = UIApplication.shared.beginBackgroundTask { MainActor.assumeIsolated { end() } }
            resume()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.resume()
                try? await Task.sleep(nanoseconds: 700_000_000)
                self?.resume()
                try? await Task.sleep(nanoseconds: 500_000_000)
                end()
            }
        }

        private func resume() {
            webView?.evaluateJavaScript("window.__pfResume && window.__pfResume()") { _, _ in }
        }

        // MARK: Pagina's

        private var isWatchPage: Bool { webView?.url?.path == "/watch" }

        private func urlChanged() {
            if let url = webView?.url, let target = rerouteTarget(for: url) {
                webView?.load(URLRequest(url: target))
                return
            }
            updateForPage()
        }

        // Op een videopagina is omlaag trekken geen verversen
        private func updateForPage() {
            guard let webView else { return }
            let wanted = isWatchPage ? nil : refresh
            if webView.scrollView.refreshControl !== wanted { webView.scrollView.refreshControl = wanted }
            if model.youtubeOnWatchPage != isWatchPage { model.youtubeOnWatchPage = isWatchPage }
        }

        // Home (/) gaat naar Abonnementen, een Short (/shorts/ID) opent als gewone video (/watch?v=ID).
        // Alleen voor YouTube zelf: inlog- en toestemmingspagina's van Google blijven onaangeroerd.
        private func rerouteTarget(for url: URL) -> URL? {
            guard let host = url.host?.lowercased(), YouTubeConfig.hosts.contains(host) else { return nil }
            var target: URL?
            // De desktopsite (www) altijd naar de mobiele site, met hetzelfde pad
            if host != "m.youtube.com", var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                c.host = "m.youtube.com"
                if YouTubeConfig.homeGoesToSubscriptions, url.path.isEmpty || url.path == "/" {
                    target = YouTubeConfig.startURL
                } else {
                    target = c.url
                }
            } else if YouTubeConfig.homeGoesToSubscriptions, url.path.isEmpty || url.path == "/" {
                target = YouTubeConfig.startURL
            } else if url.path.hasPrefix("/shorts/"), url.pathComponents.count > 2 {
                let id = url.pathComponents[2].addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                if !id.isEmpty { target = URL(string: "https://m.youtube.com/watch?v=" + id) }
            }
            guard let target else { return nil }
            // Voorkom een eindeloze lus, mocht YouTube (bijvoorbeeld uitgelogd) steeds terugsturen
            let now = Date()
            rerouteLog = rerouteLog.filter { now.timeIntervalSince($0) < 6 }
            guard rerouteLog.count < 4 else { return nil }
            rerouteLog.append(now)
            return target
        }

        @objc func reload(_ sender: UIRefreshControl) {
            webView?.reload()
            sender.endRefreshing()
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
            // Links naar andere apps (youtube://, intent://, itms-apps://) niet volgen
            if let scheme = url.scheme?.lowercased(), !["http", "https", "about", "blob", "data"].contains(scheme) {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.targetFrame?.isMainFrame ?? true, let target = rerouteTarget(for: url) {
                decisionHandler(.cancel)
                webView.load(URLRequest(url: target))
                return
            }
            decisionHandler(.allow)
        }

        // Na elke geladen pagina de cookies bewaren (dus ook direct na het inloggen)
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let host = webView.url?.host?.lowercased(), VaultSite.youtube.matches(host) {
                Task { await CookieVault.save() }
            }
            updateForPage()
        }

        // Twee webweergaves samen maken het waarschijnlijker dat iOS er een stopzet: dan opnieuw laden
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            if webView.url != nil {
                webView.reload()
            } else {
                webView.load(URLRequest(url: YouTubeConfig.startURL))
            }
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

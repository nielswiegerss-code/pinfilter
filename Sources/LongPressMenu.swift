import UIKit
import WebKit

// Lang-indrukken-menu, getekend door iOS zelf (niet door de webpagina), zodat het net zo soepel
// beweegt als het wegswipen. Houd een pin vast: na 0,16 s begint de pin al op te komen (iets groter,
// met schaduw, de rest wordt donker), na 0,32 s springen de knoppen in een boog tevoorschijn.
// Sleep naar een knop en laat los, of laat los en tik erop. Save en Hide doet JavaScript
// (window.__pfRun in PinSave.swift); Share opent het gewone iOS-deelmenu voor de pin-link.
//
// Waarom het snel is: de plek van de pin (rect) wordt al bij touchstart door de pagina naar de app
// gestuurd (bericht "pressStart"), dus er is geen wachttijd op de webpagina meer voordat het optillen
// begint. Het afschermen van Pinterest (dat het gebaar niet ook als tik of eigen menu ziet) gaat
// daarna "fire-and-forget" naar de pagina. Alleen als het bericht ontbreekt (bijv. een tik die het
// uitrollen stopte) vragen we de plek alsnog aan de pagina, zoals in v1.12.
@MainActor
final class LongPressMenu: NSObject, UIGestureRecognizerDelegate {
    weak var webView: WKWebView?
    private let preview = UILongPressGestureRecognizer()   // 0,16 s: alleen beeld, annuleert niets
    private let commit = UILongPressGestureRecognizer()    // 0,32 s: het menu zelf
    static let previewDelay: TimeInterval = 0.16
    static let commitDelay: TimeInterval = 0.32

    private struct Option {
        let key: String
        let title: String
        let symbol: String
        let view: UIView
        let icon: UIImageView
        var center: CGPoint
    }

    // De plek van de pin, door de pagina gemeld bij touchstart
    private struct Prefetch {
        let rect: CGRect
        let finger: CGPoint
        let offset: CGPoint      // scrollstand op dat moment, om latere verschuiving te corrigeren
        let time: CFTimeInterval
        let href: String
    }

    private var overlay: UIView?
    private var dim: UIView?
    private var lift: UIView?
    private var options: [Option] = []
    private var titleLabel: UILabel?
    private var hot: Int?
    private var committed = false          // menu (knoppen) is echt aan het openen of open
    private var opening = false            // wacht op de pagina (terugvalroute)
    private var waitingForPrefetch = false
    private var session = 0                // wordt opgehoogd bij elk nieuw menu, om late antwoorden te negeren
    private var prefetch: Prefetch?
    private var notPinAt: CFTimeInterval = 0   // laatste keer dat de pagina meldde: hier zit geen pin
    private var touchDown: CFTimeInterval = 0  // begin van de huidige aanraking (UITouch.timestamp)
    private var previewOrigin = CGPoint.zero
    private var liftRect = CGRect.zero         // pin in webview-punten (voor de popover van Share)
    private var pinURL: URL?
    private var idleTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?

    private var fingerDown: Bool {
        [preview, commit].contains { $0.state == .began || $0.state == .changed }
    }

    // Tijdmetingen van de laatste keren, voor de pagina-analyse (zie PageReport). Zonder Mac is dit
    // de enige manier om te zien waar de tijd heen gaat.
    private(set) static var timings: [String] = []
    static var timingSummary: String { timings.isEmpty ? "" : timings.joined(separator: "\n") }
    private var snapshotMs: Double = 0
    private var via = ""

    func attach(to webView: WKWebView) {
        self.webView = webView
        preview.minimumPressDuration = Self.previewDelay
        preview.allowableMovement = 10
        preview.cancelsTouchesInView = false   // een gewone tik moet gewoon een tik blijven
        preview.delaysTouchesBegan = false
        preview.delaysTouchesEnded = false
        commit.minimumPressDuration = Self.commitDelay
        commit.allowableMovement = 10
        for g in [preview, commit] {
            g.delegate = self
            webView.addGestureRecognizer(g)
        }
        preview.addTarget(self, action: #selector(handlePreview(_:)))
        commit.addTarget(self, action: #selector(handleCommit(_:)))
        // Verlaat de gebruiker de app met een menu open, dan blijft er niets hangen
        NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reset() }
        }
    }

    // MARK: Gebaar

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touchDown = touch.timestamp
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let webView, webView.scrollView.isScrollEnabled, !opening else { return false }
        if notPinAt > 0 && notPinAt >= touchDown { return false }   // de pagina meldde: geen pin onder de vinger
        if gestureRecognizer === commit { return overlay == nil || !committed }
        return overlay == nil
    }

    @objc private func handlePreview(_ g: UILongPressGestureRecognizer) {
        guard let webView else { return }
        let p = g.location(in: webView)
        switch g.state {
        case .began:
            previewOrigin = p
            PinHaptics.prepare()
            if !committed { startLift(at: p) }
        case .changed:
            // Gaat de vinger toch bewegen (scrollen), dan verdwijnt het optillen weer
            if !committed && hypot(p.x - previewOrigin.x, p.y - previewOrigin.y) > 10 { cancelLift() }
        case .ended, .cancelled, .failed:
            if !committed { cancelLift() }
        default:
            break
        }
    }

    @objc private func handleCommit(_ g: UILongPressGestureRecognizer) {
        guard let webView else { return }
        let p = g.location(in: webView)
        switch g.state {
        case .began:
            committed = true
            if overlay != nil {
                present(at: p, shield: true)   // het optillen liep al sinds de preview
            } else if let hit = usablePrefetch(near: p), buildLift(rect: hit.rect, href: hit.href) {
                via = "bericht"
                present(at: p, shield: true)
            } else {
                openViaJS(at: p)
            }
        case .changed:
            if menuOpen { updateHot(at: p) }
        case .ended:
            if menuOpen {
                updateHot(at: p)
                if let hot { choose(options[hot].key) } else { scheduleIdleClose() }   // anders blijft het menu open om te tikken
            }
        case .cancelled, .failed:
            if committed && menuOpen && hot == nil { close() }
        default:
            break
        }
    }

    private var menuOpen: Bool { overlay != nil && committed && !options.isEmpty }

    // MARK: Gegevens van de pagina

    // Aangeroepen door NativeBridge bij elke touchstart op een pin (in punten van de webview)
    func prefetched(rect: CGRect, finger: CGPoint, href: String) {
        guard let webView else { return }
        prefetch = Prefetch(rect: rect, finger: finger, offset: webView.scrollView.contentOffset,
                            time: CACurrentMediaTime(), href: href)
        notPinAt = 0
        PinHaptics.prepare()
        // Bericht kwam later dan de preview? Dan nu alsnog beginnen (als de vinger nog ligt)
        if waitingForPrefetch && !opening && overlay == nil && fingerDown {
            waitingForPrefetch = false
            startLift(at: previewOrigin)
            if committed && overlay != nil { present(at: previewOrigin, shield: true) }
        }
    }

    // Aanraking buiten een pin, of met meer vingers: een oude prefetch is niet meer geldig
    func prefetchMissed() {
        prefetch = nil
        notPinAt = CACurrentMediaTime()
        waitingForPrefetch = false
    }

    // Bruikbaar: van deze aanraking, dichtbij de vinger, niet aan het uitrollen. Corrigeert voor
    // een kleine verschuiving van de pagina sinds touchstart.
    private func usablePrefetch(near p: CGPoint) -> (rect: CGRect, href: String)? {
        guard let webView, let pf = prefetch, pf.time >= touchDown, CACurrentMediaTime() - pf.time < 5,
              hypot(pf.finger.x - p.x, pf.finger.y - p.y) < 30, !webView.scrollView.isDecelerating else { return nil }
        let off = webView.scrollView.contentOffset
        let rect = pf.rect.offsetBy(dx: pf.offset.x - off.x, dy: pf.offset.y - off.y)
        guard rect.insetBy(dx: -6, dy: -6).contains(p) else { return nil }
        return (rect, pf.href)
    }

    private static func menuAtJS(_ p: CGPoint) -> String {
        String(format: "window.__pfMenuAt ? window.__pfMenuAt(%.1f, %.1f) : ''", p.x, p.y)
    }

    private static func parse(_ text: String) -> (rect: CGRect, href: String)? {
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let x = (obj["x"] as? NSNumber)?.doubleValue, let y = (obj["y"] as? NSNumber)?.doubleValue,
              let w = (obj["w"] as? NSNumber)?.doubleValue, let h = (obj["h"] as? NSNumber)?.doubleValue,
              w > 10, h > 10 else { return nil }
        return (CGRect(x: x, y: y, width: w, height: h), (obj["href"] as? String) ?? "")
    }

    private static func pinURL(from href: String) -> URL? {
        guard !href.isEmpty, let url = URL(string: href), url.scheme == "https" else { return nil }
        return url
    }

    // Vraag de pagina alsnog om de plek (terugvalroute) en schermt Pinterest af
    private func openViaJS(at finger: CGPoint) {
        guard let webView, !opening else { return }
        opening = true
        waitingForPrefetch = false
        let token = session
        webView.evaluateJavaScript(Self.menuAtJS(finger)) { [weak self] result, error in
            let text = result as? String
            let failed = error != nil
            Task { @MainActor [weak self] in self?.openedViaJS(text, failed: failed, token: token, finger: finger) }
        }
    }

    private func openedViaJS(_ text: String?, failed: Bool, token: Int, finger: CGPoint) {
        guard session == token, opening else { return }   // ondertussen gereset
        opening = false
        guard !failed, let text else { reset(); return }
        guard let info = Self.parse(text) else {
            // Geen pin (of onbruikbaar): als de pagina al had afgeschermd, weer vrijgeven
            if !text.isEmpty { closePage() }
            committed = false
            return
        }
        // Het menu mag nooit verschijnen nadat de vinger al is losgelaten
        guard fingerDown, buildLift(rect: info.rect, href: info.href) else {
            closePage()
            committed = false
            return
        }
        via = "pagina"
        present(at: finger, shield: false)
    }

    // Afschermen zonder te wachten: het antwoord controleert alleen nog en sluit stil als er toch geen pin bleek
    private func shield(at p: CGPoint) {
        guard let webView else { return }
        let token = session
        webView.evaluateJavaScript(Self.menuAtJS(p)) { [weak self] result, error in
            let text = result as? String
            let failed = error != nil
            Task { @MainActor [weak self] in self?.shielded(text, failed: failed, token: token) }
        }
    }

    private func shielded(_ text: String?, failed: Bool, token: Int) {
        guard session == token, overlay != nil else { return }
        guard !failed, let text, !text.isEmpty else { reset(); return }
        if pinURL == nil, let info = Self.parse(text) { pinURL = Self.pinURL(from: info.href) }
    }

    private func closePage() {
        webView?.evaluateJavaScript("window.__pfMenuClose && window.__pfMenuClose()", completionHandler: nil)
    }

    // MARK: Optillen (preview)

    private func startLift(at finger: CGPoint) {
        guard overlay == nil, !opening else { return }
        guard let hit = usablePrefetch(near: finger) else {
            waitingForPrefetch = !(notPinAt > 0 && notPinAt >= touchDown)
            return
        }
        waitingForPrefetch = false
        guard buildLift(rect: hit.rect, href: hit.href), let lift, let dim else { return }
        via = "bericht"
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            lift.transform = CGAffineTransform(scaleX: 1.025, y: 1.025)
            dim.alpha = 0.25
        }
        animateShadow(to: 0.3, duration: 0.2)
        // Vangnet: komt het menu niet (meer), dan verdwijnt het optillen vanzelf
        previewTask?.cancel()
        previewTask = after(1.5) { [weak self] in
            if let self, !self.committed { self.dropLift() }
        }
    }

    // Bouwt overlay, dim-laag en de momentopname van de pin (nog zonder knoppen)
    private func buildLift(rect: CGRect, href: String) -> Bool {
        guard let webView, overlay == nil else { return false }
        let started = CACurrentMediaTime()
        let visible = rect.intersection(webView.bounds)   // een half buiten beeld staande pin: alleen het zichtbare deel
        guard visible.width > 10, visible.height > 10,
              let snapshot = webView.resizableSnapshotView(from: visible, afterScreenUpdates: false, withCapInsets: .zero)
        else { return false }

        let container = UIView(frame: webView.bounds)
        container.isUserInteractionEnabled = false   // pas bij het menu zelf, zodat een tik gewoon doorkomt
        let dim = UIView(frame: container.bounds)
        dim.backgroundColor = .black
        dim.alpha = 0
        container.addSubview(dim)

        // De "opgetilde" pin: schaduw op een omhulsel, ronde hoeken op de momentopname zelf
        let lift = UIView(frame: visible)
        lift.layer.shadowColor = UIColor.black.cgColor
        lift.layer.shadowOpacity = 0
        lift.layer.shadowRadius = 30
        lift.layer.shadowOffset = CGSize(width: 0, height: 18)
        lift.layer.shadowPath = UIBezierPath(roundedRect: lift.bounds, cornerRadius: 16).cgPath   // goedkoper dan uit de alfa berekenen
        snapshot.frame = lift.bounds
        snapshot.layer.cornerRadius = 16
        snapshot.layer.cornerCurve = .continuous
        snapshot.clipsToBounds = true
        lift.addSubview(snapshot)
        container.addSubview(lift)

        webView.addSubview(container)
        overlay = container
        self.dim = dim
        self.lift = lift
        liftRect = visible
        pinURL = Self.pinURL(from: href)
        session += 1
        snapshotMs = (CACurrentMediaTime() - started) * 1000
        return true
    }

    // Vinger weg of aan het scrollen voordat het menu opende: kort terugvallen en opruimen
    private func cancelLift() {
        waitingForPrefetch = false
        previewTask?.cancel()
        guard let container = overlay, !committed else { return }
        overlay = nil
        let lift = self.lift, dim = self.dim
        self.lift = nil
        self.dim = nil
        container.isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.12, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            lift?.transform = .identity
            dim?.alpha = 0
        } completion: { _ in
            container.removeFromSuperview()
        }
        lift?.layer.shadowOpacity = 0
        removeLater(container)
    }

    // Direct weg, zonder animatie. Voor een tik op een pin: de open-animatie maakt zelf een momentopname
    // van het scherm (Transitions.swift) en mag onze laag daar niet in meenemen.
    func dropLift() {
        waitingForPrefetch = false
        previewTask?.cancel()
        guard !committed, let container = overlay else { return }
        overlay = nil
        lift = nil
        dim = nil
        container.removeFromSuperview()
    }

    // Alles direct opruimen, zonder animatie (paginawissel, webproces gecrasht, app naar de achtergrond)
    func reset() {
        idleTask?.cancel()
        previewTask?.cancel()
        session += 1
        overlay?.removeFromSuperview()
        overlay = nil
        dim = nil
        lift = nil
        titleLabel = nil
        options = []
        hot = nil
        committed = false
        opening = false
        waitingForPrefetch = false
        webView?.scrollView.isScrollEnabled = true
        closePage()
    }

    // MARK: Menu openen (commit)

    private func present(at finger: CGPoint, shield doShield: Bool) {
        guard let webView, let container = overlay, let lift, let dim else { return }
        previewTask?.cancel()
        webView.scrollView.isScrollEnabled = false
        PinHaptics.impact()                  // eerst voelen, dan pas de rest
        if doShield { shield(at: finger) }   // fire-and-forget: Pinterest laten weten dat dit gebaar van ons is
        container.isUserInteractionEnabled = true

        // Knoppen in een boog boven de vinger; bij de bovenrand eronder, bij de zijkant naar binnen
        let radius: CGFloat = 80
        let up: CGFloat = finger.y > 170 ? -1 : 1
        let side = finger.x < 120 ? 1 : (finger.x > container.bounds.width - 120 ? -1 : 0)
        var specs = [("save", "Save", "pin.fill"), ("hide", "Hide", "eye.slash.fill")]
        if pinURL != nil { specs.append(("share", "Share", "square.and.arrow.up")) }
        let angles: [CGFloat]
        switch (specs.count, side) {
        case (3, 0): angles = [-55, 0, 55]
        case (3, 1): angles = [10, 50, 90]
        case (3, _): angles = [-90, -50, -10]
        case (_, 0): angles = [-38, 38]
        case (_, 1): angles = [15, 60]
        default: angles = [-60, -15]
        }
        options = zip(specs, angles).map { spec, angle in
            let a = angle * .pi / 180
            let center = CGPoint(x: finger.x + radius * sin(a), y: finger.y + up * radius * cos(a))
            let view = UIView(frame: CGRect(x: 0, y: 0, width: 52, height: 52))
            view.center = center
            view.layer.cornerRadius = 26
            view.backgroundColor = UIColor(white: 0.11, alpha: 0.9)
            view.layer.shadowColor = UIColor.black.cgColor
            view.layer.shadowOpacity = 0.35
            view.layer.shadowRadius = 10
            view.layer.shadowOffset = CGSize(width: 0, height: 4)
            view.layer.shadowPath = UIBezierPath(ovalIn: view.bounds).cgPath
            let icon = UIImageView(image: UIImage(systemName: spec.2,
                                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)))
            icon.tintColor = .white
            icon.contentMode = .center
            icon.frame = view.bounds
            view.addSubview(icon)
            view.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
            view.alpha = 0
            container.addSubview(view)
            return Option(key: spec.0, title: spec.1, symbol: spec.2, view: view, icon: icon, center: center)
        }

        // Label van de gekozen optie, boven de knoppen (of eronder als daar geen ruimte is)
        let label = UILabel()
        label.font = .systemFont(ofSize: 22, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.5
        label.layer.shadowRadius = 8
        label.layer.shadowOffset = .zero
        label.alpha = 0
        let top = options.map(\.center.y).min() ?? finger.y
        let bottom = options.map(\.center.y).max() ?? finger.y
        label.frame = CGRect(x: 0, y: 0, width: 200, height: 30)
        label.center = CGPoint(x: min(max(finger.x, 100), container.bounds.width - 100),
                               y: up < 0 ? max(top - 62, 24) : bottom + 58)
        container.addSubview(label)
        titleLabel = label
        hot = nil

        // Tikken als het menu open blijft (na loslaten zonder keuze)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        container.addGestureRecognizer(tap)

        // Vanaf de huidige stand van het optillen verder naar de volle stand
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.68, initialSpringVelocity: 0.4,
                       options: [.beginFromCurrentState]) {
            lift.transform = CGAffineTransform(scaleX: 1.05, y: 1.05).rotated(by: -2.5 * .pi / 180)
        }
        UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) { dim.alpha = 0.6 }
        animateShadow(to: 0.55, duration: 0.3)
        for (i, option) in options.enumerated() {
            UIView.animate(withDuration: 0.42, delay: 0.04 + Double(i) * 0.04,
                           usingSpringWithDamping: 0.62, initialSpringVelocity: 0.6) {
                option.view.transform = .identity
                option.view.alpha = 1
            }
        }
        // Al losgelaten voordat het menu klaar was? Dan blijft het gewoon open om te tikken.
        if !fingerDown { scheduleIdleClose() }
        recordTimings()
    }

    private func animateShadow(to value: Float, duration: CFTimeInterval) {
        guard let layer = lift?.layer else { return }
        let from = layer.presentation()?.shadowOpacity ?? layer.shadowOpacity
        layer.shadowOpacity = value
        let animation = CABasicAnimation(keyPath: "shadowOpacity")
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        layer.add(animation, forKey: "shadow")
    }

    // MARK: Kiezen

    private func nearestOption(to point: CGPoint) -> Int? {
        options.indices
            .map { ($0, hypot(options[$0].center.x - point.x, options[$0].center.y - point.y)) }
            .filter { $0.1 < 44 }
            .min { $0.1 < $1.1 }?.0
    }

    private func updateHot(at point: CGPoint) {
        let index = nearestOption(to: point)
        guard index != hot else { return }
        if let old = hot { style(options[old], hot: false) }
        if let index { style(options[index], hot: true); PinHaptics.tick() }
        hot = index
        UIView.animate(withDuration: 0.15) {
            self.titleLabel?.text = index.map { self.options[$0].title }
            self.titleLabel?.alpha = index == nil ? 0 : 1
        }
    }

    private func style(_ option: Option, hot: Bool) {
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5) {
            option.view.transform = hot ? CGAffineTransform(scaleX: 1.2, y: 1.2) : .identity
            option.view.backgroundColor = hot ? .white : UIColor(white: 0.11, alpha: 0.9)
            option.icon.tintColor = hot ? .black : .white
        }
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard let overlay else { return }
        let p = tap.location(in: overlay)
        if let index = nearestOption(to: p) {
            choose(options[index].key)
        } else {
            close()
        }
    }

    private func choose(_ key: String) {
        PinHaptics.light()
        if key == "share" {
            close()
            share()
        } else {
            close(running: key)
        }
    }

    // Het gewone iOS-deelmenu voor de pin-link. Op iPad is een popover bij de pin verplicht.
    private func share() {
        guard let webView, let url = pinURL else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = webView
            popover.sourceRect = liftRect
        }
        var top = webView.window?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        top?.present(sheet, animated: true)
    }

    // MARK: Sluiten

    private func close(running key: String? = nil) {
        guard let container = overlay else { return }
        idleTask?.cancel()
        previewTask?.cancel()
        overlay = nil
        let options = self.options
        self.options = []
        let lift = self.lift, dim = self.dim, label = titleLabel
        self.lift = nil
        self.dim = nil
        titleLabel = nil
        hot = nil
        committed = false
        container.isUserInteractionEnabled = false
        webView?.scrollView.isScrollEnabled = true
        if let key {
            webView?.evaluateJavaScript("window.__pfRun && window.__pfRun('\(key)')", completionHandler: nil)
        } else {
            closePage()
        }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState]) {
            lift?.transform = .identity
            dim?.alpha = 0
            label?.alpha = 0
            for option in options {
                option.view.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
                option.view.alpha = 0
            }
        } completion: { _ in
            container.removeFromSuperview()
        }
        lift?.layer.shadowOpacity = 0
        removeLater(container)
    }

    // Een menu waar niemand meer op tikt (bijv. losgelaten zonder keuze en weggelopen) sluit vanzelf
    private func scheduleIdleClose() {
        idleTask?.cancel()
        idleTask = after(15) { [weak self] in
            if let self, self.overlay != nil, !self.fingerDown { self.close() }
        }
    }

    // ---- kleine hulpjes ----

    private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !Task.isCancelled { body() }
        }
    }

    // Vangnet als een animatie-completion niet komt (bijv. app naar de achtergrond): een onzichtbare
    // laag mag nooit blijven staan en aanrakingen opvangen
    private func removeLater(_ view: UIView) {
        _ = after(0.7) { view.removeFromSuperview() }
    }

    private func recordTimings() {
        let down = touchDown
        let ms = { (value: CFTimeInterval) -> String in
            down > 0 && value > down ? String(format: "%.0f", (value - down) * 1000) : "-"
        }
        let msg = (prefetch?.time ?? 0)
        let now = CACurrentMediaTime()
        let line = "menu (\(via)): bericht \(ms(msg))ms · snapshot \(String(format: "%.0f", snapshotMs))ms · klaar \(ms(now))ms na aanraking"
        Self.timings.append(line)
        if Self.timings.count > 5 { Self.timings.removeFirst() }
    }
}

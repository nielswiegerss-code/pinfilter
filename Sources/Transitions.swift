import UIKit
import WebKit

// Animaties bij het openen en sluiten van een pin, zoals in de Pinterest-app.
//
// Openen: bij een tik op een pin houdt JavaScript de klik heel even vast en meldt waar de
// afbeelding staat. De app maakt een momentopname van het scherm en van de afbeelding, laat
// Pinterest de pin openen en laat de kopie naar de grote afbeelding op de pinpagina zoomen.
// Onder de momentopname bouwt Pinterest intussen de pagina op, zodat je geen verspringen ziet.
//
// Sluiten: bovenaan een pin omlaag slepen. De pinpagina volgt je vinger als een kaart die krimpt;
// daarachter zie je de feed (de momentopname van het openen). Ver genoeg losgelaten: de afbeelding
// vliegt naar haar plek in de feed, en de echte feed wordt onzichtbaar opgebouwd en daarna getoond.
//
// Waar de grote afbeelding op de pinpagina komt te staan, meldt de pagina zelf ("closeupReady", zie
// LayoutBridge onderaan en PageTweaks.swift): pas als de viewport gewisseld is, de opmaak is toegepast en
// gecontroleerd. Die melding vervangt het steeds opnieuw vragen (pollen); pollen blijft alleen als vangnet.
@MainActor
final class PinTransitions {
    weak var webView: WKWebView?
    private var overlay: UIView?

    // Plek van de grote afbeelding op de huidige pinpagina
    private var closeupImage: (path: String, rect: CGRect)?

    // Per geopende pin: hoe het scherm eruitzag vóór het openen, en waar de pin daar stond
    private var openedFrom: [String: (screen: UIView, rect: CGRect)] = [:]
    private var openOrder: [String] = []

    // Laatste melding van de pagina dat de pinpagina klaar is ("closeupReady")
    private var ready: (path: String, rect: CGRect, status: String, at: Date)?
    // Pin waarvoor al iemand op de melding of op een plek wacht (voorkomt dubbele wachtlussen)
    private var pendingPinId: String?
    // Wordt hoger bij reset(), zodat lopende animaties en wachttaken niets meer aanraken
    private var generation = 0

    // Hoe onze pin-opmaak de laatste keer uitpakte; daarmee voorspellen we de plek voor de volgende pin
    private struct KnownLayout: Codable {
        var natW: CGFloat, natH: CGFloat   // natuurlijke maat van het pinblok (vóór onze vergroting)
        var maxNatH: CGFloat               // grootste natuurlijke hoogte tot nu toe (Pinterest kapt lange pins af)
        var left: CGFloat, top: CGFloat    // waar de afbeelding komt
        var viewWidth: CGFloat             // breedte van de webview toen (andere breedte: niet gebruiken)
    }
    private var knownLayout: KnownLayout? = {
        guard let data = UserDefaults.standard.data(forKey: "pfKnownLayout") else { return nil }
        return try? JSONDecoder().decode(KnownLayout.self, from: data)
    }()
    private var lastStatus = "ok"

    // MARK: Openen

    func pinTapped(rect: CGRect, pinId: String) {
        guard let webView, overlay == nil, rect.width > 20, rect.height > 20 else { go(); return }
        ready = nil   // een oude melding (van een eerder bezoek aan deze pin) telt niet
        let tapped = Date()
        let gen = generation
        pendingPinId = pinId.isEmpty ? nil : pinId

        let container = UIView(frame: webView.bounds)
        let screen = webView.snapshotView(afterScreenUpdates: false)
        if let screen { container.addSubview(screen) }
        let backdrop = UIView(frame: container.bounds)
        backdrop.backgroundColor = .systemBackground
        backdrop.alpha = 0
        container.addSubview(backdrop)
        let image = webView.resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero) ?? UIView()
        image.frame = rect
        image.layer.cornerRadius = 16
        image.clipsToBounds = true
        container.addSubview(image)
        webView.addSubview(container)
        overlay = container

        // Bewaar het scherm van vóór het openen, voor de sluit-animatie
        if !pinId.isEmpty, let keep = webView.snapshotView(afterScreenUpdates: false) {
            openedFrom[pinId] = (keep, rect)
            openOrder.removeAll { $0 == pinId }
            openOrder.append(pinId)
            while openOrder.count > 6 { openedFrom[openOrder.removeFirst()] = nil }
        }

        go()   // nu mag Pinterest de pin openen, onder de momentopname

        // Direct naar de plek vliegen waar de afbeelding op de pinpagina komt (die plek bepaalt onze
        // eigen opmaak in PageTweaks.swift), in plaats van eerst te wachten tot Pinterest klaar is
        let predicted = predictedCloseupRect(for: rect)
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) { backdrop.alpha = 1 }
        if let predicted {
            UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.84, initialSpringVelocity: 0) {
                Self.move(image, from: rect, to: predicted)
            }
        } else {
            UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
                image.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
            }
        }

        Task {
            // Wacht op de melding van de pagina; komt die niet (of is er geen pin-ID), dan vragen we het zelf
            var target: CGRect?
            var status = "ok"
            if !pinId.isEmpty, let known = await waitForReady(pinId: pinId, since: tapped, timeout: 0.9) {
                target = known.rect
                status = known.status
            } else if gen == generation {
                target = await waitForRect(Self.closeupImageJS, timeout: 1.8, minWait: max(switchDelay, predicted == nil ? 0 : 0.42))
            }
            guard gen == generation else { return }   // intussen gereset: niets meer aanraken
            if pendingPinId == pinId { pendingPinId = nil }
            if let target, let path = webView.url?.path {
                closeupImage = (path, target)
                // Klein stukje bijschuiven als de echte plek iets anders is dan voorspeld
                let close = predicted.map { abs($0.minX - target.minX) < 3 && abs($0.minY - target.minY) < 3 &&
                                            abs($0.width - target.width) < 3 } ?? false
                // Bij "safe" (Pinterests eigen opmaak) wijkt de plek vaak flink af van de voorspelling: rustiger bijschuiven
                let duration = close ? 0.01 : (predicted == nil || status != "ok" ? 0.38 : 0.24)
                UIView.animate(withDuration: duration, delay: 0,
                               usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
                    Self.move(image, from: rect, to: target)
                } completion: { _ in
                    // Is de plek intussen nog veranderd (afbeelding laadde later)? Dan nog één keer bijschuiven
                    if gen == self.generation, !pinId.isEmpty, let late = self.ready,
                       Self.pinId(from: late.path) == pinId, late.at >= tapped,
                       abs(late.rect.minX - target.minX) > 3 || abs(late.rect.minY - target.minY) > 3 ||
                       abs(late.rect.width - target.width) > 3 {
                        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                            Self.move(image, from: rect, to: late.rect)
                        } completion: { _ in self.fadeOut(container, duration: 0.14) }
                    } else {
                        self.fadeOut(container, duration: 0.14)
                    }
                }
            } else {
                fadeOut(container, duration: 0.2)
            }
        }
    }

    // Waar de grote afbeelding ongeveer komt, op basis van hoe onze pin-opmaak de vorige keer uitpakte
    // (zelfde rekensom als in PageTweaks.swift: links en boven zoals toen, zo hoog als de ruimte toelaat,
    // maximaal 12% groter). Zonder eerdere uitkomst, of als die "safe" was, geen voorspelling: dan wacht
    // de kopie op de echte plek.
    private func predictedCloseupRect(for source: CGRect) -> CGRect? {
        guard let webView, webView.bounds.width > webView.bounds.height, webView.bounds.width >= 1000,
              lastStatus == "ok", let known = knownLayout, known.natW > 100, known.natH > 100,
              abs(known.viewWidth - webView.bounds.width) < 1 else { return nil }
        let aspect = source.width / max(source.height, 1)
        // Pinterest maakt het pinblok zo hoog als de afbeelding (breedte / verhouding), tot een maximum
        let natH = min(known.natW / max(aspect, 0.1), known.maxNatH)
        let room = webView.bounds.height - known.top - 150
        let scale = max(1, min(1.12, room / max(natH, 1)))
        var width = known.natW * scale
        var height = natH * scale
        // De afbeelding zelf past in het blok, met dezelfde verhouding als de pin
        if width / max(height, 1) > aspect { width = height * aspect } else { height = width / aspect }
        return CGRect(x: known.left, y: known.top, width: width, height: height)
    }

    // Laat JavaScript de vastgehouden klik doorgeven aan Pinterest
    private func go() {
        webView?.evaluateJavaScript("window.__pfGo && window.__pfGo()", completionHandler: nil)
    }

    // MARK: Sluiten door te slepen

    private struct Drag {
        let container: UIView
        let dim: UIView
        let card: UIView
        let image: UIView?
        let imageRect: CGRect
        let pinId: String
        let target: CGRect?
        let hasFeedSnapshot: Bool
    }
    private var drag: Drag?

    func beginDrag() {
        guard let webView, overlay == nil, drag == nil, webView.canGoBack,
              let card = webView.snapshotView(afterScreenUpdates: false) else { return }
        let path = webView.url?.path ?? ""
        let pinId = Self.pinId(from: path)

        let container = UIView(frame: webView.bounds)
        container.backgroundColor = .black
        // Achtergrond: de feed zoals die was toen de pin werd geopend (als we die hebben)
        let from = openedFrom[pinId]
        if let feed = from?.screen {
            feed.frame = container.bounds
            feed.alpha = 1
            container.addSubview(feed)
        }
        let dim = UIView(frame: container.bounds)
        dim.backgroundColor = .black
        dim.alpha = 0.55
        container.addSubview(dim)

        card.frame = container.bounds
        card.clipsToBounds = true
        container.addSubview(card)

        var image: UIView?
        var imageRect = CGRect.zero
        if let info = closeupImage, !pinId.isEmpty, Self.pinId(from: info.path) == pinId,
           let snap = webView.resizableSnapshotView(from: info.rect, afterScreenUpdates: false, withCapInsets: .zero) {
            imageRect = info.rect
            snap.frame = imageRect
            snap.layer.cornerRadius = 16
            snap.clipsToBounds = true
            card.addSubview(snap)   // beweegt mee met de kaart
            image = snap
        }

        webView.addSubview(container)
        overlay = container
        drag = Drag(container: container, dim: dim, card: card, image: image, imageRect: imageRect,
                    pinId: pinId, target: from?.rect, hasFeedSnapshot: from != nil)
    }

    func updateDrag(translation t: CGPoint) {
        guard let drag else { return }
        let dy = max(t.y, 0)
        let progress = min(dy / 420, 1)
        let scale = 1 - 0.32 * progress
        drag.card.transform = CGAffineTransform(translationX: t.x * 0.6, y: dy * 0.9).scaledBy(x: scale, y: scale)
        drag.card.layer.cornerRadius = 28 * progress / scale
        drag.dim.alpha = 0.55 * (1 - progress)
    }

    func endDrag(translation t: CGPoint, velocity v: CGPoint) {
        guard let drag, let webView else { return }
        let commit = t.y > 130 || (v.y > 700 && t.y > 30)
        if !commit {
            // Terugveren: niets veranderd, overlay weg
            UIView.animate(withDuration: 0.32, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                drag.card.transform = .identity
                drag.card.layer.cornerRadius = 0
                drag.dim.alpha = 0.55
            } completion: { _ in
                drag.container.removeFromSuperview()
                if self.overlay === drag.container { self.overlay = nil }
            }
            self.drag = nil
            return
        }

        self.drag = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        webView.goBack()   // de echte feed wordt nu onder de overlay opgebouwd

        // Afbeelding uit de kaart halen, zodat hij los kan vliegen
        var flying: UIView?
        var flyingFrom = CGRect.zero
        if let image = drag.image {
            flyingFrom = image.convert(image.bounds, to: drag.container)
            let copy = image
            copy.removeFromSuperview()
            copy.transform = .identity
            copy.frame = flyingFrom
            drag.container.addSubview(copy)
            flying = copy
        }

        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            drag.card.alpha = 0
            drag.dim.alpha = 0
        }

        Task {
            // Waar gaat de afbeelding heen? Bij voorkeur de plek van het openen (op de momentopname)
            var target = drag.target
            if !drag.hasFeedSnapshot, !drag.pinId.isEmpty {
                target = await waitForRect(Self.gridImageJS(pinId: drag.pinId), timeout: 1.4, minWait: switchDelay * 0.7)
            }
            if let flying, let target {
                await withCheckedContinuation { done in
                    UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) {
                        Self.move(flying, from: flyingFrom, to: target)
                    } completion: { _ in done.resume() }
                }
            } else if let flying {
                UIView.animate(withDuration: 0.25) {
                    flying.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                    flying.alpha = 0
                }
            }
            // Wacht tot de echte feed klaar staat, en laat hem dan zien
            if drag.hasFeedSnapshot, !drag.pinId.isEmpty {
                _ = await waitForRect(Self.gridImageJS(pinId: drag.pinId), timeout: 1.2, minWait: switchDelay * 0.7)
            } else {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            fadeOut(drag.container, duration: 0.18)
        }
    }

    // MARK: Hulpjes

    // Nieuwe pinpagina (ook zonder animatie geopend): onthoud waar de grote afbeelding staat.
    // Dat komt normaal uit de melding van de pagina (closeupReady); pas als die uitblijft vragen we het zelf.
    func pageChanged() {
        guard let webView, let path = webView.url?.path else { return }
        guard path.contains("/pin/") else {
            // Terug in de feed: meldingen en wachttaken van de pinpagina zijn verouderd
            ready = nil
            return
        }
        let pinId = Self.pinId(from: path)
        if !pinId.isEmpty, Self.pinId(from: closeupImage?.path) == pinId { return }   // plek al bekend
        if pendingPinId == pinId { return }   // pinTapped of een eerdere aanroep wacht hier al op
        pendingPinId = pinId.isEmpty ? nil : pinId
        let gen = generation
        Task {
            var rect: CGRect?
            if !pinId.isEmpty { rect = await waitForReady(pinId: pinId, since: .distantPast, timeout: 1.5)?.rect }
            if rect == nil, gen == generation {
                rect = await waitForRect(Self.closeupImageJS, timeout: 2.5, minWait: switchDelay)
            }
            guard gen == generation else { return }
            if pendingPinId == pinId { pendingPinId = nil }
            if let rect, webView.url?.path == path { closeupImage = (path, rect) }
        }
    }

    // Alles direct stoppen, zonder animatie: overlay weg, sleepgebaar beëindigd, wachttaken geannuleerd.
    // Voor als de interactie onderbroken wordt (app naar de achtergrond, pagina herladen, venster verandert).
    func reset() {
        generation += 1
        overlay?.removeFromSuperview()
        overlay = nil
        if let drag {
            drag.container.removeFromSuperview()
            self.drag = nil
        }
        pendingPinId = nil
        ready = nil
        webView?.scrollView.isScrollEnabled = true   // het sleepgebaar zette scrollen uit
    }

    // MARK: Meldingen van de pagina (via LayoutBridge)

    // De pinpagina is klaar: opmaak toegepast en gecontroleerd, met de plek van de afbeelding in punten
    func closeupReady(path: String, status: String, rect: CGRect, natSize: CGSize) {
        guard rect.width > 20, rect.height > 20 else { return }
        ready = (path, rect, status, Date())
        closeupImage = (path, rect)
        lastStatus = status == "ok" ? "ok" : "safe"
        // Bij een geslaagde eigen opmaak onthouden we de maten voor de volgende voorspelling
        guard status == "ok", natSize.width > 100, natSize.height > 100, let webView else { return }
        let maxNatH = max(natSize.height, knownLayout?.maxNatH ?? 0)
        let layout = KnownLayout(natW: natSize.width, natH: natSize.height, maxNatH: maxNatH,
                                 left: rect.minX, top: rect.minY, viewWidth: webView.bounds.width)
        knownLayout = layout
        if let data = try? JSONEncoder().encode(layout) { UserDefaults.standard.set(data, forKey: "pfKnownLayout") }
    }

    // De viewport is gewisseld (columnsJS). De pagina kan daarbij zijwaarts verschoven blijven staan,
    // waardoor een pin aan de zijkant afgesneden lijkt; als er niets zijwaarts te scrollen valt zetten we hem recht.
    func viewportSettled() {
        guard let sv = webView?.scrollView, !sv.isDragging else { return }
        let left = -sv.adjustedContentInset.left
        if abs(sv.contentOffset.x - left) > 0.5, sv.contentSize.width <= sv.bounds.width + 1 {
            sv.setContentOffset(CGPoint(x: left, y: sv.contentOffset.y), animated: false)
        }
    }

    // Wacht (zonder de pagina te bevragen) tot de melding voor deze pin binnen is
    private func waitForReady(pinId: String, since: Date, timeout: TimeInterval) async -> (rect: CGRect, status: String)? {
        let gen = generation
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if gen != generation || webView == nil { return nil }
            if let r = ready, r.at >= since, Self.pinId(from: r.path) == pinId { return (r.rect, r.status) }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return nil
    }

    private func fadeOut(_ view: UIView, duration: TimeInterval) {
        UIView.animate(withDuration: duration) { view.alpha = 0 } completion: { _ in
            view.removeFromSuperview()
            if self.overlay === view { self.overlay = nil }
        }
    }

    // Schuif en schaal een kopie van `from` naar `to`
    private static func move(_ view: UIView, from: CGRect, to: CGRect) {
        let sx = to.width / max(from.width, 1)
        let sy = to.height / max(from.height, 1)
        view.transform = CGAffineTransform(translationX: to.midX - from.midX, y: to.midY - from.midY)
            .scaledBy(x: sx, y: sy)
    }

    // In de 4-kolommenstand wisselt de pagina bij openen/sluiten van breedte. Pinterest toont dan
    // eerst ~0,4 s de oude opmaak; zo lang wachten we minstens voordat we een plek vertrouwen.
    private var switchDelay: TimeInterval {
        guard let webView, webView.bounds.width > webView.bounds.height, ColumnSetting.shared.columns == 4 else { return 0 }
        return 0.45
    }

    // Vraag de pagina herhaaldelijk om een plek, tot die twee keer achter elkaar gelijk is
    // (en er minstens `minWait` seconden voorbij zijn)
    private func waitForRect(_ js: String, timeout: TimeInterval, minWait: TimeInterval = 0) async -> CGRect? {
        let start = Date()
        let deadline = start.addingTimeInterval(timeout)
        var previous: CGRect?
        let gen = generation
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard let webView, gen == generation else { return nil }
            guard let text = try? await webView.evaluateJavaScript(js) as? String,
                  let rect = Self.rect(from: text) else { continue }
            if let p = previous, abs(p.minX - rect.minX) < 2, abs(p.minY - rect.minY) < 2,
               abs(p.width - rect.width) < 2, abs(p.height - rect.height) < 2,
               Date().timeIntervalSince(start) >= minWait {
                return rect
            }
            previous = rect
        }
        return previous
    }

    private static func rect(from text: String) -> CGRect? {
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = obj["x"], let y = obj["y"], let w = obj["w"], let h = obj["h"], w > 20, h > 20 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    static func pinId(from path: String?) -> String {
        guard let path, let range = path.range(of: "/pin/") else { return "" }
        return String(path[range.upperBound...].prefix { $0.isNumber })
    }

    // Grootste afbeelding op de pinpagina die niet in een raster staat, in punten van de webview
    private static let closeupImageJS = """
    (() => {
      if (!location.pathname.includes('/pin/')) return '';
      const s = (window.visualViewport && visualViewport.scale) || 1;
      let best = null, area = 0;
      for (const img of document.querySelectorAll('img')) {
        if (img.closest('[data-grid-item]') || img.closest('#pf-menu')) continue;
        const r = img.getBoundingClientRect();
        const a = r.width * r.height;
        if (r.width > 120 && r.height > 120 && r.bottom > 0 && r.top < innerHeight && a > area) { best = r; area = a; }
      }
      return best ? JSON.stringify({ x: best.left * s, y: best.top * s, w: best.width * s, h: best.height * s }) : '';
    })()
    """

    // Plek van een bepaalde pin in het raster van de feed
    private static func gridImageJS(pinId: String) -> String {
        """
        (() => {
          if (location.pathname.includes('/pin/\(pinId)/')) return '';
          const a = document.querySelector('[data-grid-item] a[href*="/pin/\(pinId)/"]');
          const item = a && a.closest('[data-grid-item]');
          const img = item && item.querySelector('img');
          if (!img) return '';
          const r = img.getBoundingClientRect();
          if (r.bottom < 0 || r.top > innerHeight) return '';
          const s = (window.visualViewport && visualViewport.scale) || 1;
          return JSON.stringify({ x: r.left * s, y: r.top * s, w: r.width * s, h: r.height * s });
        })()
        """
    }
}

// Brug van de pagina naar de app voor de opmaak van een geopende pin (handler "pfLayout"):
// - closeupReady: de pinpagina is klaar (opmaak toegepast en gecontroleerd), met de plek van de afbeelding
//   in punten van de webview en de natuurlijke maat van het pinblok (PageTweaks.swift)
// - viewportSettled: de viewport is echt gewisseld (Columns.swift)
// Los van NativeBridge ("pfNative"), zodat de twee niet in elkaars weg zitten.
final class LayoutBridge: NSObject, WKScriptMessageHandler {
    weak var transitions: PinTransitions?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let n = { (key: String) in CGFloat((body[key] as? NSNumber)?.doubleValue ?? 0) }
        switch type {
        case "closeupReady":
            let path = (body["path"] as? String) ?? ""
            let status = (body["status"] as? String) ?? "ok"
            let rect = CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
            let natSize = CGSize(width: n("nw"), height: n("nh"))
            MainActor.assumeIsolated { transitions?.closeupReady(path: path, status: status, rect: rect, natSize: natSize) }
        case "viewportSettled":
            MainActor.assumeIsolated { transitions?.viewportSettled() }
        default:
            break
        }
    }
}

// Houdt een tik op een pin in het raster heel even vast en meldt de app waar de afbeelding staat.
// De app antwoordt met window.__pfGo(); komt dat niet binnen 250 ms, dan gaat de klik gewoon door.
let transitionsJS = #"""
(() => {
  'use strict';
  const native = (m) => { try { webkit.messageHandlers.pfNative.postMessage(m); } catch (e) {} };
  let skipNext = false;

  document.addEventListener('click', (e) => {
    if (e.defaultPrevented) return;              // bijv. tegengehouden door het lang-indrukken-menu
    if (skipNext) { skipNext = false; return; }  // dit is onze eigen doorgegeven klik
    const a = e.target.closest && e.target.closest('a[href*="/pin/"]');
    const item = a && a.closest('[data-grid-item]');
    const img = item && item.querySelector('img');
    if (!img) return;
    const r = img.getBoundingClientRect();
    if (r.width < 20 || r.bottom < 0 || r.top > innerHeight) return;

    e.preventDefault();
    e.stopPropagation();
    const s = (window.visualViewport && visualViewport.scale) || 1;
    const pinId = ((a.getAttribute('href') || '').split('/pin/')[1] || '').split('/')[0];
    let went = false;
    window.__pfGo = () => { if (went) return; went = true; skipNext = true; a.click(); };
    native({ type: 'pinTap', x: r.left * s, y: r.top * s, w: r.width * s, h: r.height * s, pinId });
    setTimeout(() => window.__pfGo && window.__pfGo(), 250);
  }, true);
})();
"""#

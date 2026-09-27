import UIKit
import WebKit

// Animaties bij het openen en sluiten van een pin, zoals in de Pinterest-app.
//
// Openen: bij een tik op een pin houdt JavaScript de klik heel even vast en meldt waar de
// afbeelding staat. De app maakt een momentopname van het scherm en van de afbeelding, laat
// Pinterest de pin openen en laat de kopie van de afbeelding naar de grote afbeelding op de
// pinpagina zoomen. Onder de momentopname bouwt Pinterest intussen de pagina op, zodat je het
// verspringen (o.a. door de kolommenwissel) niet ziet.
//
// Sluiten: momentopname van de pinpagina, terug naar de feed, en de afbeelding vliegt terug
// naar haar plek in het raster.
@MainActor
final class PinTransitions {
    weak var webView: WKWebView?
    private var overlay: UIView?

    // Plek van de grote afbeelding op de huidige pinpagina (voor de sluit-animatie)
    private var closeupImage: (path: String, rect: CGRect)?

    // MARK: Openen

    func pinTapped(rect: CGRect) {
        guard let webView, overlay == nil, rect.width > 20, rect.height > 20 else { go(); return }

        let container = UIView(frame: webView.bounds)
        if let screen = webView.snapshotView(afterScreenUpdates: false) { container.addSubview(screen) }
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

        go()   // nu mag Pinterest de pin openen, onder de momentopname

        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            backdrop.alpha = 1
            image.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
        }

        Task {
            let target = await waitForRect(Self.closeupImageJS, timeout: 1.8, minWait: switchDelay)
            if let target, let path = webView.url?.path {
                closeupImage = (path, target)
                UIView.animate(withDuration: 0.38, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0) {
                    Self.move(image, from: rect, to: target)
                } completion: { _ in
                    self.fadeOut(container, duration: 0.14)
                }
            } else {
                fadeOut(container, duration: 0.2)
            }
        }
    }

    // Laat JavaScript de vastgehouden klik doorgeven aan Pinterest
    private func go() {
        webView?.evaluateJavaScript("window.__pfGo && window.__pfGo()", completionHandler: nil)
    }

    // MARK: Sluiten

    // Aangeroepen na omlaag swipen op een pinpagina. `pulled` is hoe ver de pagina omlaag getrokken is.
    func dismissPin(pulled: CGFloat) {
        guard let webView else { return }
        guard overlay == nil, webView.canGoBack else { webView.goBack(); return }
        let pinId = Self.pinId(from: webView.url?.path)

        let container = UIView(frame: webView.bounds)
        let screen = webView.snapshotView(afterScreenUpdates: false)
        if let screen { container.addSubview(screen) }
        var image: UIView?
        var imageRect = CGRect.zero
        if let info = closeupImage, info.path == webView.url?.path {
            imageRect = info.rect.offsetBy(dx: 0, dy: max(pulled, 0))
            image = webView.resizableSnapshotView(from: imageRect, afterScreenUpdates: false, withCapInsets: .zero)
            if let image {
                image.frame = imageRect
                image.layer.cornerRadius = 16
                image.clipsToBounds = true
                container.addSubview(image)
            }
        }
        webView.addSubview(container)
        overlay = container

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        webView.goBack()

        // De pinpagina vervaagt, zodat de feed eronder zichtbaar wordt
        UIView.animate(withDuration: 0.28, delay: 0.08, options: .curveEaseOut) { screen?.alpha = 0 }

        Task {
            let target = pinId.isEmpty ? nil
                : await waitForRect(Self.gridImageJS(pinId: pinId), timeout: 1.4, minWait: switchDelay * 0.7)
            if let image, let target {
                UIView.animate(withDuration: 0.36, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0) {
                    Self.move(image, from: imageRect, to: target)
                } completion: { _ in
                    self.fadeOut(container, duration: 0.12)
                }
            } else {
                UIView.animate(withDuration: 0.25) {
                    image?.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                    image?.alpha = 0
                } completion: { _ in
                    self.fadeOut(container, duration: 0.1)
                }
            }
        }
    }

    // MARK: Hulpjes

    // Nieuwe pinpagina (ook zonder animatie geopend): onthoud waar de grote afbeelding staat
    func pageChanged() {
        guard let webView, let path = webView.url?.path, path.contains("/pin/") else { return }
        if closeupImage?.path == path { return }
        Task {
            if let rect = await waitForRect(Self.closeupImageJS, timeout: 2.5, minWait: switchDelay),
               webView.url?.path == path {
                closeupImage = (path, rect)
            }
        }
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
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard let webView else { return nil }
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

    private static func pinId(from path: String?) -> String {
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
          if (location.pathname.includes('/pin/')) return '';
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
    let went = false;
    window.__pfGo = () => { if (went) return; went = true; skipNext = true; a.click(); };
    native({ type: 'pinTap', x: r.left * s, y: r.top * s, w: r.width * s, h: r.height * s });
    setTimeout(() => window.__pfGo && window.__pfGo(), 250);
  }, true);
})();
"""#

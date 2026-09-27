import UIKit
import WebKit

// Lang-indrukken-menu, getekend door iOS zelf (niet door de webpagina), zodat het net zo soepel
// beweegt als het wegswipen. Houd een pin een halve seconde vast: de pin komt omhoog (iets groter,
// schuin, met schaduw), de rest wordt donker en er verschijnen knoppen in een boog. Sleep naar een
// knop en laat los, of laat los en tik erop. De actie zelf (Save / See less) doet JavaScript
// (window.__pfRun in PinSave.swift).
@MainActor
final class LongPressMenu: NSObject, UIGestureRecognizerDelegate {
    weak var webView: WKWebView?
    private let recognizer = UILongPressGestureRecognizer()

    private struct Option {
        let key: String
        let title: String
        let symbol: String
        let view: UIView
        let icon: UIImageView
        var center: CGPoint
    }

    private var overlay: UIView?
    private var dim: UIView?
    private var lift: UIView?
    private var options: [Option] = []
    private var titleLabel: UILabel?
    private var hot: Int?
    private var opening = false
    private var fingerDown = false
    private let selection = UISelectionFeedbackGenerator()

    func attach(to webView: WKWebView) {
        self.webView = webView
        recognizer.minimumPressDuration = 0.45
        recognizer.allowableMovement = 10
        recognizer.delegate = self
        recognizer.addTarget(self, action: #selector(handle(_:)))
        webView.addGestureRecognizer(recognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        overlay == nil && !opening && (webView?.scrollView.isScrollEnabled ?? false)
    }

    @objc private func handle(_ g: UILongPressGestureRecognizer) {
        guard let webView else { return }
        let p = g.location(in: webView)
        switch g.state {
        case .began:
            fingerDown = true
            Task { await open(at: p) }
        case .changed:
            if overlay != nil { updateHot(at: p) }
        case .ended:
            fingerDown = false
            if overlay != nil {
                updateHot(at: p)
                if let hot { choose(options[hot].key) }   // anders blijft het menu open om te tikken
            }
        case .cancelled, .failed:
            fingerDown = false
            if overlay != nil && hot == nil { close() }
        default:
            break
        }
    }

    // MARK: Openen

    private func open(at finger: CGPoint) async {
        guard let webView, overlay == nil, !opening else { return }
        opening = true
        defer { opening = false }
        let js = String(format: "window.__pfMenuAt ? window.__pfMenuAt(%.1f, %.1f) : ''", finger.x, finger.y)
        guard let text = try? await webView.evaluateJavaScript(js) as? String,
              let rect = Self.rect(from: text),
              let snapshot = webView.resizableSnapshotView(from: rect, afterScreenUpdates: false, withCapInsets: .zero)
        else { return }

        webView.scrollView.isScrollEnabled = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        selection.prepare()

        let container = UIView(frame: webView.bounds)
        let dim = UIView(frame: container.bounds)
        dim.backgroundColor = .black
        dim.alpha = 0
        container.addSubview(dim)

        // De "opgetilde" pin: schaduw op een omhulsel, ronde hoeken op de momentopname zelf
        let lift = UIView(frame: rect)
        lift.layer.shadowColor = UIColor.black.cgColor
        lift.layer.shadowOpacity = 0
        lift.layer.shadowRadius = 30
        lift.layer.shadowOffset = CGSize(width: 0, height: 18)
        snapshot.frame = lift.bounds
        snapshot.layer.cornerRadius = 16
        snapshot.clipsToBounds = true
        lift.addSubview(snapshot)
        container.addSubview(lift)

        // Knoppen in een boog boven de vinger; bij de bovenrand eronder, bij de zijkant naar binnen
        let radius: CGFloat = 80
        let up: CGFloat = finger.y > 170 ? -1 : 1
        let side = finger.x < 120 ? 1 : (finger.x > container.bounds.width - 120 ? -1 : 0)
        let angles: [CGFloat] = side == 0 ? [-38, 38] : (side > 0 ? [15, 60] : [-60, -15])
        let specs = [("save", "Save", "pin.fill"), ("hide", "Hide", "eye.slash.fill")]
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

        // Tikken als het menu open blijft (na loslaten zonder keuze)
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        container.addGestureRecognizer(tap)

        webView.addSubview(container)
        overlay = container
        self.dim = dim
        self.lift = lift
        titleLabel = label
        hot = nil

        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.68, initialSpringVelocity: 0.4) {
            lift.transform = CGAffineTransform(scaleX: 1.05, y: 1.05).rotated(by: -2.5 * .pi / 180)
        }
        UIView.animate(withDuration: 0.25) { dim.alpha = 0.6 }
        let shadow = CABasicAnimation(keyPath: "shadowOpacity")
        shadow.fromValue = 0
        shadow.toValue = 0.55
        shadow.duration = 0.3
        lift.layer.shadowOpacity = 0.55
        lift.layer.add(shadow, forKey: "shadow")
        for (i, option) in options.enumerated() {
            UIView.animate(withDuration: 0.42, delay: 0.04 + Double(i) * 0.04,
                           usingSpringWithDamping: 0.62, initialSpringVelocity: 0.6) {
                option.view.transform = .identity
                option.view.alpha = 1
            }
        }
        // Al losgelaten voordat het menu klaar was? Dan blijft het gewoon open om te tikken.
    }

    // MARK: Kiezen

    private func updateHot(at point: CGPoint) {
        let index = options.firstIndex { hypot($0.center.x - point.x, $0.center.y - point.y) < 44 }
        guard index != hot else { return }
        if let old = hot { style(options[old], hot: false) }
        if let index { style(options[index], hot: true); selection.selectionChanged() }
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
        if let option = options.first(where: { hypot($0.center.x - p.x, $0.center.y - p.y) < 44 }) {
            choose(option.key)
        } else {
            close()
        }
    }

    private func choose(_ key: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        close(running: key)
    }

    // MARK: Sluiten

    private func close(running key: String? = nil) {
        guard let overlay else { return }
        self.overlay = nil
        let options = self.options
        self.options = []
        hot = nil
        webView?.scrollView.isScrollEnabled = true
        if let key {
            webView?.evaluateJavaScript("window.__pfRun && window.__pfRun('\(key)')", completionHandler: nil)
        } else {
            webView?.evaluateJavaScript("window.__pfMenuClose && window.__pfMenuClose()", completionHandler: nil)
        }
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            self.lift?.transform = .identity
            self.dim?.alpha = 0
            self.titleLabel?.alpha = 0
            for option in options {
                option.view.transform = CGAffineTransform(scaleX: 0.3, y: 0.3)
                option.view.alpha = 0
            }
        } completion: { _ in
            overlay.removeFromSuperview()
        }
        lift?.layer.shadowOpacity = 0
    }

    private static func rect(from text: String) -> CGRect? {
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Double],
              let x = obj["x"], let y = obj["y"], let w = obj["w"], let h = obj["h"], w > 10, h > 10 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

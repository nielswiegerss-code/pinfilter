import SwiftUI

// Kleine ronde knop aan de rechterrand (ongeveer halverwege): tik = wisselen tussen Pinterest en YouTube.
// Verticaal te slepen (de plek wordt onthouden). Lang indrukken = pagina-analyse van de site die open staat
// (op YouTube met een YouTube-sectie), voor Claude om filters en opmaak bij te stellen.
// Rechts halverwege is op beide sites vrij: bovenin staan hun koppen, onderin hun balken, links het terugvegen.
struct SiteSwitcher: View {
    @ObservedObject var model: SiteModel
    let size: CGSize

    @State private var fraction = SiteSwitcher.savedFraction()
    @State private var dragStart: Double?
    @State private var awake = true
    @State private var wake = 0
    @State private var report: String?

    private let diameter: CGFloat = 40

    private static func savedFraction() -> Double {
        let saved = UserDefaults.standard.double(forKey: "switcherY")
        return saved > 0 ? min(max(saved, 0.1), 0.9) : 0.45
    }

    var body: some View {
        VStack(spacing: 10) {
            // Een echte UIKit-knop: SwiftUI-gebaren boven een webview kwamen na het vervagen niet meer aan
            SwitcherButton(symbol: model.current == .pinterest ? "play.rectangle.fill" : "pin.fill",
                           label: model.current == .pinterest ? "Wissel naar YouTube" : "Wissel naar Pinterest",
                           onTap: {
                               poke()
                               withAnimation(.easeInOut(duration: 0.2)) { model.toggle() }
                           },
                           onLongPress: {
                    poke()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if model.current == .youtube {
                        Task { report = await model.youtubeReport() }
                    } else {
                        // Pinterest: dezelfde analyse als lang drukken op de kolommenknop, maar ook staand
                        // en op een geopende pin bereikbaar, plus de tijden van het lang-indrukken-menu
                        Task {
                            let page = await PageReport.make(webView: ColumnSetting.shared.webView)
                            let timings = LongPressMenu.timingSummary
                            report = timings.isEmpty ? page : page + "\n\nLANG INDRUKKEN (ms)\n" + timings
                        }
                    }
                },
                           onDrag: { dy, ended in dragged(by: dy, ended: ended) })
                .frame(width: diameter, height: diameter)

            // Op een video: Beeld-in-beeld (naast de knop in de speler zelf)
            if model.current == .youtube && model.youtubeOnWatchPage {
                SwitcherButton(symbol: "pip.enter", label: "Beeld-in-beeld",
                               onTap: { poke(); model.togglePip() }, onLongPress: nil, onDrag: nil)
                    .frame(width: diameter, height: diameter)
            }
        }
        .opacity(awake ? 1 : 0.55)
        .animation(.easeInOut(duration: 0.3), value: awake)
        .padding(.trailing, 6)
        .padding(.top, max(0, fraction * size.height - diameter / 2))
        .task(id: wake) {
            awake = true
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { awake = false }
        }
        .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            NavigationStack {
                ScrollView {
                    Text(report ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle(model.current == .youtube ? "YouTube-analyse" : "Pagina-analyse")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Sluit") { report = nil } }
                }
            }
        }
    }

    // Verticaal slepen (dy = verschuiving sinds het begin van het slepen, in punten)
    private func dragged(by dy: CGFloat, ended: Bool) {
        if dragStart == nil {
            dragStart = fraction
            poke()
        }
        let lowest = max(0.15, 1 - 130 / max(size.height, 1))
        fraction = min(max((dragStart ?? fraction) + Double(dy / max(size.height, 1)), 0.1), lowest)
        if ended {
            dragStart = nil
            UserDefaults.standard.set(fraction, forKey: "switcherY")
        }
    }

    // Aanraking: weer volledig zichtbaar, en na 3 s stilte weer vervagen
    private func poke() { wake += 1 }
}

// Ronde knop als echte UIKit-view: tik, lang indrukken en verticaal slepen via UIKit-gebaren.
// Ligt als eigen view boven de webview, dus krijgt de aanraking altijd (ook half doorzichtig).
struct SwitcherButton: UIViewRepresentable {
    let symbol: String
    let label: String
    let onTap: () -> Void
    let onLongPress: (() -> Void)?
    let onDrag: ((CGFloat, Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.frame = view.bounds
        blur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blur.layer.cornerRadius = 20
        blur.layer.cornerCurve = .circular
        blur.clipsToBounds = true
        blur.isUserInteractionEnabled = false
        view.addSubview(blur)
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.18
        view.layer.shadowRadius = 4
        view.layer.shadowOffset = CGSize(width: 0, height: 1)
        let icon = UIImageView()
        icon.contentMode = .center
        icon.tintColor = .label
        icon.frame = view.bounds
        icon.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(icon)
        context.coordinator.icon = icon
        view.isAccessibilityElement = true
        view.accessibilityTraits = .button

        let c = context.coordinator
        view.addGestureRecognizer(UITapGestureRecognizer(target: c, action: #selector(Coordinator.tap)))
        let long = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.long(_:)))
        long.minimumPressDuration = 0.7
        view.addGestureRecognizer(long)
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.pan(_:)))
        view.addGestureRecognizer(pan)
        update(view, context: context)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) { update(view, context: context) }

    private func update(_ view: UIView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onLongPress = onLongPress
        context.coordinator.onDrag = onDrag
        context.coordinator.icon?.image = UIImage(systemName: symbol,
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        view.accessibilityLabel = label
        view.layer.shadowPath = UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 40, height: 40)).cgPath
    }

    @MainActor
    final class Coordinator: NSObject {
        var onTap: (() -> Void)?
        var onLongPress: (() -> Void)?
        var onDrag: ((CGFloat, Bool) -> Void)?
        weak var icon: UIImageView?

        @objc func tap() { onTap?() }

        @objc func long(_ g: UILongPressGestureRecognizer) {
            if g.state == .began { onLongPress?() }
        }

        @objc func pan(_ g: UIPanGestureRecognizer) {
            guard let onDrag, let window = g.view?.window else { return }
            let dy = g.translation(in: window).y
            switch g.state {
            case .changed: onDrag(dy, false)
            case .ended, .cancelled, .failed: onDrag(dy, true)
            default: break
            }
        }
    }
}

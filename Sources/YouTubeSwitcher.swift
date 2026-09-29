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
            roundButton(symbol: model.current == .pinterest ? "play.rectangle.fill" : "pin.fill",
                        label: model.current == .pinterest ? "Wissel naar YouTube" : "Wissel naar Pinterest")
                .onTapGesture {
                    poke()
                    withAnimation(.easeInOut(duration: 0.2)) { model.toggle() }
                }
                .onLongPressGesture(minimumDuration: 0.7) {
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
                }
                .gesture(drag)

            // Op een video: Beeld-in-beeld (naast de knop in de speler zelf)
            if model.current == .youtube && model.youtubeOnWatchPage {
                roundButton(symbol: "pip.enter", label: "Beeld-in-beeld")
                    .onTapGesture {
                        poke()
                        model.togglePip()
                    }
            }
        }
        .opacity(awake ? 1 : 0.4)
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

    private func roundButton(symbol: String, label: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: diameter, height: diameter)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            .contentShape(Circle())
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
    }

    // Verticaal slepen; globale coördinaten, anders beweegt de knop onder je vinger mee en gaat het trillen
    private var drag: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = fraction
                    poke()
                }
                let lowest = max(0.15, 1 - 130 / max(size.height, 1))
                fraction = min(max((dragStart ?? fraction) + Double(value.translation.height / max(size.height, 1)), 0.1), lowest)
            }
            .onEnded { _ in
                dragStart = nil
                UserDefaults.standard.set(fraction, forKey: "switcherY")
            }
    }

    // Aanraking: weer volledig zichtbaar, en na 3 s stilte weer vervagen
    private func poke() { wake += 1 }
}

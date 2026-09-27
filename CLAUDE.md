# PinFilter — Pinterest zonder advertenties, als echte iPad-app

## Voor Claude Code: lees dit eerst

Communiceer met Niels in het Nederlands. Hij heeft geen formele programmeerervaring en bouwt door doelen te beschrijven en feedback te geven. Leg daarom kort uit wat je doet en waarom (mechanisme, niet alleen de stappen). Vraag hem alleen om handelingen die jij zelf niet kunt doen: inloggen bij GitHub, dingen op de iPad, iloader op Windows.

Hij werkt op een Windows-pc (Claude desktop app) en heeft **geen Mac**. De doel-iPad draait iPadOS 26 of nieuwer. Vraag de exacte versie als die ergens toe doet.

## Doel

Een eigen app die Pinterest schermvullend toont zonder advertentie-pins, **als echt icoon op het beginscherm**, zonder kosten. Na herstarten van de app, herstarten van de iPad en de wekelijkse verversing door SideStore moet hij ingelogd blijven.

## Wat al werkt (niet opnieuw uitvinden)

`Sources/ContentView.swift` is getest in Swift Playgrounds op de iPad en werkt volgens Niels perfect. Het is SwiftUI met een WKWebView die `https://nl.pinterest.com/` laadt. Het bestand heeft:

- swipe-navigatie
- pull-to-refresh
- `target=_blank`-links die in dezelfde webview openen
- een ingebed JavaScript-filter

Het filter wordt als `WKUserScript` bij `.atDocumentStart` in de hoofdframe geïnjecteerd. Het draait dus vóór de code van Pinterest. Het vervangt drie routes waarlangs data de pagina binnenkomt:

- `JSON.parse`, voor de beginstatus en de meeste API-data
- `Response.prototype.json`, dat wordt omgeleid via de aangepaste `JSON.parse`
- de `response`-getter van `XMLHttpRequest` bij `responseType === 'json'`

In de geparste data verwijdert het:

- array-items die zelf, of via `.node`, `pin_promotion_id` (truthy) of `is_promoted: true` hebben
- entries uit maps die op numerieke pin-ID zijn geordend

Linksonder staat een teller (`SHOW_COUNTER`).

**Uitbreiding in v1.11** (na een test op de iPad: advertenties onder "More to explore" op een geopende pin). Pinterests GraphQL-data gebruikt camelCase: `isPromoted`, `pinPromotionId` en `promoter` (een object bij advertenties, `null` bij gewone pins). `adFlags()` en `MARKERS` herkennen die nu ook.

Getest op echte data van een openbare pinpagina, waarin niets werd weggehaald, en op nagebootste feeds.

In v1.12 kwamen er "doorgeplaatste" advertenties bij (geopend tonen ze "Ad"): `is_downstream_promotion`/`isDownstreamPromotion === true` en `adData`/`ad_data` als object. `sponsorship` (betaald partnerschap) wordt bewust niet gefilterd.

`adProbeJS` draait ná het filter. Het toont in de pagina-analyse welke advertentievelden van de geopende pin erdoor kwamen.

**Waarom deze aanpak.** CSS-verbergen laat gaten achter, omdat Pinterest de pins al met JavaScript absoluut heeft gepositioneerd. Safari-extensies draaien niet in webapps op het beginscherm. Door de data te filteren vóórdat het raster wordt gebouwd, ontstaan er geen gaten. **Verander de filterlogica niet** tenzij een test op de iPad een probleem laat zien.

## Randvoorwaarden en besluiten

**Bouwen zonder Mac.** Bouw een *niet-ondertekende* `.ipa` op een macOS-runner van GitHub Actions. SideStore ondertekent die op de iPad met een gratis Apple ID.

**Repository.** Maak de repository openbaar, zodat de macOS-minuten gratis zijn. Daarom mogen er geen geheimen of persoonlijke gegevens in. Die zijn ook niet nodig, want er wordt niet ondertekend in CI.

**Bundle ID vast: `nl.niels.pinfilter`, nooit wijzigen.** Een gratis Apple ID heeft drie beperkingen:

- ondertekende apps verlopen na 7 dagen
- er mogen maximaal 3 actieve gesideloade apps zijn, en SideStore zelf telt mee
- je kunt beperkt nieuwe App ID's per week aanmaken

Een ander bundle ID betekent bovendien een nieuwe app-container, en dus uitgelogd zijn.

**App-naam en icoon.** De weergavenaam is "Pins". Maak een eigen, eenvoudig icoon, **niet** het Pinterest-logo, want dat is een handelsmerk. Een 1024×1024 PNG in `AppIcon.appiconset` is genoeg (single-size, Xcode 14+). Die kun je met Python/Pillow genereren.

**Inloggen.** Log in met e-mail en wachtwoord. Google blokkeert OAuth in ingebedde webviews.

**Swift-taalmodus.** Gebruik `SWIFT_VERSION = 5.0` om gedoe met strikte concurrency-fouten te vermijden. De Coordinator is al `@MainActor`.

## Stappenplan

### 1. Voorbereiding op Windows

Controleer of `git` en de GitHub CLI (`gh`) aanwezig zijn. Installeer ze anders, bijvoorbeeld via `winget`. Laat Niels `gh auth login` doen. Initialiseer de repo en maak een openbare GitHub-repository `pinfilter`.

### 2. Xcode-project via XcodeGen

Je kunt Xcode niet lokaal draaien. Genereer het project daarom in CI met XcodeGen vanuit een `project.yml`. Commit het gegenereerde `.xcodeproj` niet. Schets, ongetest:

```yaml
name: PinFilter
options:
  bundleIdPrefix: nl.niels
  deploymentTarget:
    iOS: "17.0"
settings:
  base:
    SWIFT_VERSION: "5.0"
targets:
  PinFilter:
    type: application
    platform: iOS
    sources: [Sources, Resources]
    scheme: {}            # nodig: xcodebuild -scheme / -derivedDataPath vereist een gedeeld scheme
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: nl.niels.pinfilter
        TARGETED_DEVICE_FAMILY: "1,2"
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_CFBundleDisplayName: Pins
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        INFOPLIST_KEY_UIApplicationSceneManifest_Generation: YES
        INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad: "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        MARKETING_VERSION: "1.0"
        CURRENT_PROJECT_VERSION: "1"
```

De icoon komt in `Resources/Assets.xcassets/AppIcon.appiconset/`, met `Contents.json` en de PNG.

### 3. GitHub Actions-workflow

Maak `.github/workflows/build.yml`. Schets, ongetest:

```yaml
name: Build IPA
on:
  workflow_dispatch:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  build:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - run: brew install xcodegen
      - run: xcodegen generate
      - name: Build (unsigned)
        run: |
          xcodebuild -project PinFilter.xcodeproj -scheme PinFilter \
            -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
            -derivedDataPath build \
            CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
            build
      - name: Package IPA
        run: |
          mkdir -p Payload
          cp -R build/Build/Products/Release-iphoneos/PinFilter.app Payload/
          zip -qry PinFilter.ipa Payload
      - uses: actions/upload-artifact@v4
        with:
          name: PinFilter-ipa
          path: PinFilter.ipa
      - name: Release
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v2
        with:
          files: PinFilter.ipa
```

Twee dingen zijn hier belangrijk. De `.ipa` moet `Payload/PinFilter.app` in de root van de zip hebben. Publiceer hem als **Release-asset**: Actions-artifacts vereisen een GitHub-login en worden extra ingepakt, terwijl Niels het bestand op de iPad in Safari moet kunnen downloaden.

Een simulatorbuild is niet installeerbaar op de iPad. Het moet `-sdk iphoneos` zijn.

**Debuglus.** Gebruik `gh run watch` en `gh run view --log-failed`. Los bouwfouten zelf op totdat de run groen is, en vraag Niels pas daarna iets op de iPad te doen.

### 4. Inloggen onthouden (zie het ontwerp hieronder)

Implementeer `Sources/CookieVault.swift` en koppel die aan ContentView.

### 5. Installeren op de iPad via SideStore (door Niels, met jouw begeleiding)

Volg de officiële documentatie op docs.sidestore.io. Het verloop in het kort:

1. Installeer **LocalDevVPN** uit de App Store op de iPad.
2. Installeer **iloader** op Windows. 32-bit Windows en Windows 10 op ARM worden niet ondersteund. De iPad moet op hetzelfde wifi-netwerk zitten; volg de iloader-instructies voor de eerste koppeling.
3. Log in iloader in met een Apple ID. Een apart, gratis Apple ID alleen hiervoor is verstandig. Installeer daarna SideStore.
4. Op de iPad:
   - vertrouw het profiel via Instellingen > Algemeen > VPN en apparaatbeheer
   - zet Ontwikkelaarsmodus aan via Instellingen > Privacy en beveiliging (de iPad herstart)
5. Open LocalDevVPN en kies Connect. Open SideStore, log in met hetzelfde Apple ID, ga naar My Apps en tik op de dagenteller naast SideStore om te verversen.
6. Download `PinFilter.ipa` in Safari van de GitHub Release en open het in SideStore. Dat kan ook via "+" in SideStore en dan het bestand kiezen in Bestanden.
7. SideStore ververst apps op de achtergrond, maar alleen als de VPN aanstaat. Na een iPadOS-update of reset kan het koppelbestand vervallen. Dan moet de iloader-stap opnieuw.

**Waarschuwing.** Gebruik géén installers die SideStore "zonder computer" beloven via gedeelde of enterprise-certificaten of DNS-profielen. Die certificaten zijn van onbekende herkomst, en zo'n profiel geeft een derde partij veel invloed op het apparaat.

### 6. SideStore-bron (gedaan)

`scripts/make_source.py` maakt bij elke tag-build een `source.json` (AltStore-formaat). Die hangt als asset aan de Release. De vaste bron-URL voor SideStore is `https://github.com/nielswiegerss-code/pinfilter/releases/latest/download/source.json`.

Het versienummer komt uit de git-tag (`v1.2` wordt 1.2) en het buildnummer uit `GITHUB_RUN_NUMBER`. Pas daarom `MARKETING_VERSION` in `project.yml` niet met de hand aan.

### Tablet-site

De app vraagt Pinterests aanraakversie op (`preferredContentMode = .mobile`). Niels wil die altijd.

### Kolommen (`Columns.swift`)

In liggende stand is er een knop om te wisselen tussen **4 kolommen** (standaard) en **5 kolommen**. Niels heeft een gewone iPad, liggend 1180 pt breed.

Bij 4 kolommen overschrijft een script Pinterests viewport-meta met `width=944, initial-scale=1.25`. Pinterest bouwt dan zelf 4 kolommen, en iOS schaalt het scherp op.

Op `/pin/`-pagina's staat dit uit, anders valt de pin aan de zijkant buiten beeld. Het script volgt `pushState` en `popstate`.

**Niet gebruiken: `WKWebView.pageZoom`.** Daarbij bleef Pinterest voor 1180 bouwen, met 5 overlappende kolommen en zijwaarts scrollen tot gevolg. Pinterests Masonry-raster (Gestalt, open source) meet de breedte van zijn wrapper met `getBoundingClientRect`.

### Lang indrukken (`PinSave.swift`)

Lang indrukken op een pin opent een rond menu met twee opties: **Save** en **Hide**. Beide openen onzichtbaar Pinterests "…"-menu (`contextual-menu-button`) en tikken daarin op een optie:

- **Save** kiest `save-repin-menu-link`. Daarna toont Pinterest de bordkeuze.
- **Hide** kiest `see-less-option`.

Vindt het script een knop niet, dan toont het een diagnosemelding met de aanwezige `data-test-id`'s.

Pinterest heeft een eigen long-press-menu. Zodra ons menu opengaat, stuurt het script `pointercancel` en `touchcancel` naar het doelelement. Daarna stopt het de verdere touch- en pointer-events van dat gebaar (`stopPropagation`).

### Layout-aanpassingen (`PageTweaks.swift`)

Het script verbergt de inbox-knop in de onderbalk. Het herkent die aan een aria-label of href met inbox, message of notification, en aan de positie onderin het scherm.

### Animaties (`Transitions.swift`)

**Openen.** `transitionsJS` houdt een klik op een rasterpin maximaal 250 ms vast en stuurt `pinTap` met de afbeeldingsrect in punten. Native maakt een snapshot en laat Pinterest doorgaan (`window.__pfGo`). Daarna vraagt native steeds de grootste afbeelding op de pinpagina op en animeert de kopie daarheen.

**Sluiten.** Dit gebeurt via een eigen `UIPanGestureRecognizer` (`dismissPan` in de Coordinator). Het gebaar start alleen op `/pin/`-pagina's, helemaal bovenaan en bij een beweging omlaag. `scrollView.bounces` staat daar uit.

- Tijdens het slepen volgt een snapshot van de pinpagina de vinger als krimpende kaart. Erachter staat de feed-snapshot die bij het openen is bewaard (`openedFrom[pinId]`).
- Bij loslaten na meer dan 130 pt, of bij een snelle beweging, volgt `goBack`. De afbeelding vliegt naar de opgeslagen bronrect, en de overlay vervaagt pas als de echte feed stabiel is.
- Anders veert de kaart terug.

### Pin-opmaak (`PageTweaks.swift`)

Dit werkt alleen bij `closeup-body-landscape`. De blokken verschuiven puur met transforms:

- `closeup-container` gaat naar links (16 pt marge) en wordt tot 12% groter. `closeup-related-modules-container` krijgt `margin-top` zodat niets overlapt.
- `header` (de knoppenbalk) gaat omhoog naar de bovenkant van de afbeelding. Wat eronder stond, schuift omhoog.
- Save staat rechts in de balk (flex `order` plus `margin-left: auto`).
- `back-button` is een donker rondje op de hoek van de afbeelding.

Het script maakt de opmaak alleen opnieuw als het pad, de breedte of de hoogte van de afbeelding verandert.

### Kolommen wisselen zonder herladen

`window.__pfSetZoom(f)` in `columnsJS` past de viewport direct aan. Bij 5 kolommen zet het Pinterests eigen viewport-regel terug (`data-pf-original`).

De webview-achtergrond is `.systemBackground` met `isOpaque = false`, zodat er niets wit flitst.

**Lang-indrukken-menu (v1.12, `LongPressMenu.swift`).** iOS tekent het menu zelf: een `UILongPressGestureRecognizer` van 0,45 s op de webview. `window.__pfMenuAt(x, y)` in `pinSaveJS` geeft de afbeeldingsrect van de pin onder de vinger en schermt het gebaar af voor Pinterest. Native tekent daarna het menu: de opgetilde snapshot, een dim-laag, SF Symbols en het label. Een keuze gaat naar `window.__pfRun(key)`.

**Open-animatie.** Die vliegt direct naar `predictedCloseupRect`, dat is gebaseerd op onze eigen pin-opmaak, en schuift daarna bij naar de echte plek.

### Pagina-analyse

Lang drukken op de kolommenknop opent een sheet met:

- de viewport- en schermmaten
- de te brede elementen
- een boom van `data-test-id`'s met maten en stijl

Niels maakt daar screenshots van als Claude de ingelogde paginastructuur nodig heeft.

### Verlanglijst (van Niels, nog te doen)

- externe links openen in een los venster (SFSafariViewController)
- donkere modus
- snellere start met een laadindicator
- een mooiere layout voor een geopende pin, zoals in de app (wacht op screenshots)
- daarna: animaties, layout en snelheid

### Pin sluiten

Op `/pin/`-pagina's gaat bovenaan omlaag swipen terug naar de feed (`goBack`). Pull-to-refresh staat daar uit. Zie de `Coordinator` in `ContentView.swift`.

---

## Ontwerp: inloggen onthouden

### Mechanisme (waarom je kunt uitloggen)

WKWebView bewaart cookies in `WKWebsiteDataStore.default()`. Die staat in de eigen container van de app op schijf. Dat is al zo ingesteld en mag **nooit** `.nonPersistent()` worden. Er zijn drie redenen waarom een login toch kan verdwijnen:

1. **Sessiecookies** (cookies zonder vervaldatum) worden bij het afsluiten van het webproces bewust weggegooid. Het is niet bekend of Pinterest de login in zo'n cookie bewaart.
2. **Asynchroon wegschrijven.** Wordt de app kort na het inloggen hard afgesloten, dan zijn nieuwe cookies mogelijk nog niet naar schijf geschreven.
3. **Nieuwe container.** Een ander bundle ID of een ander ontwikkelaarsteam geeft een lege container. Bij een normale SideStore-verversing, met hetzelfde Apple ID en hetzelfde bundle ID, blijft de container behouden.

In Swift Playgrounds draait de app als gast binnen Playgrounds. Daar is het gedrag rond opslag niet representatief.

### Oplossing

Bewaar een back-up van de Pinterest-cookies in de **Keychain**. Zet ze terug vóór de eerste pagina laadt.

**Sla het wachtwoord niet op.** De sessiecookie is precies wat Pinterest gebruikt om je ingelogd te houden. Die is beperkter dan het wachtwoord, en Pinterest kan hem intrekken. Keychain-items met `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` blijven op het apparaat en worden niet gesynchroniseerd.

**Opslaan:**

- bij elke `didFinish`-navigatie (maak de Coordinator ook `WKNavigationDelegate`)
- zodra `scenePhase` niet meer `.active` is (`.inactive` komt vóór `.background`, dus er is nog tijd)

**Terugzetten:**

- in `makeUIView` eerst `await CookieVault.restore()`, pas daarna `webView.load(...)`
- verlopen cookies overslaan

Schets, **ongetest**; laat de CI-build de compilatiefouten vangen:

```swift
import Foundation
import Security
import WebKit

@MainActor
enum CookieVault {
    private static let service = "nl.niels.pinfilter.cookies"
    private static let account = "pinterest"
    private static var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    private struct StoredCookie: Codable {
        let name, value, domain, path: String
        let expires: Date?
        let isSecure, isHTTPOnly: Bool
        let sameSite: String?
    }

    static func save() async {
        let cookies = await store.allCookies().filter { $0.domain.contains("pinterest") }
        let stored = cookies.map {
            StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                         expires: $0.expiresDate, isSecure: $0.isSecure,
                         isHTTPOnly: $0.isHTTPOnly, sameSite: $0.sameSitePolicy?.rawValue)
        }
        guard !stored.isEmpty, let data = try? JSONEncoder().encode(stored) else { return }
        writeKeychain(data)
    }

    static func restore() async {
        guard let data = readKeychain(),
              let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return }
        for s in stored {
            if let e = s.expires, e < Date() { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: s.name, .value: s.value, .domain: s.domain, .path: s.path
            ]
            if let e = s.expires { props[.expires] = e }
            if s.isSecure { props[.secure] = "TRUE" }
            if s.isHTTPOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let ss = s.sameSite { props[.sameSitePolicy] = ss }
            if let cookie = HTTPCookie(properties: props) { await store.setCookie(cookie) }
        }
    }

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func writeKeychain(_ data: Data) {
        SecItemDelete(baseQuery as CFDictionary)
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func readKeychain() -> Data? {
        var q = baseQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}
```

Koppeling in ContentView, ook als schets:

- `@Environment(\.scenePhase) private var scenePhase`, plus `.onChange(of: scenePhase) { _, phase in if phase != .active { Task { await CookieVault.save() } } }`
- de Coordinator conformeert aan `WKNavigationDelegate`, zet `webView.navigationDelegate = context.coordinator`, en roept in `webView(_:didFinish:)` `Task { await CookieVault.save() }` aan
- in `makeUIView` wordt de directe `webView.load(...)` vervangen door `Task { await CookieVault.restore(); webView.load(...) }`

Optioneel, lage prioriteit: controleer of iOS in het inlogveld Wachtwoorden-AutoFill aanbiedt. Automatische koppeling aan pinterest.com vereist associated domains die alleen Pinterest kan uitgeven, dus waarschijnlijk kun je hooguit handmatig een wachtwoord kiezen.

### Testplan voor inloggen (door Niels op de iPad)

1. Log in, sluit de app geforceerd af via de appkiezer en open hem opnieuw. Je moet nog ingelogd zijn.
2. Log in, sluit de app **meteen** na het inloggen geforceerd af en open hem opnieuw. Dit test het asynchroon wegschrijven.
3. Herstart de iPad. Je moet nog ingelogd zijn.
4. Laat SideStore de app verversen, of tik handmatig op de dagenteller. Je moet nog ingelogd zijn.

## Acceptatiecriteria

- Er staat een icoon "Pins" op het beginscherm dat direct schermvullend Pinterest opent.
- Er zijn geen advertentie-pins en geen gaten in het raster. De teller loopt op.
- Na alle vier de stappen van het testplan is Niels nog ingelogd.
- Een nieuwe versie maken kost één tag-push (`git tag v1.x && git push --tags`), waarna de `.ipa` in de Release staat.

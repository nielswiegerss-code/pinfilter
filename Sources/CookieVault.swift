import Foundation
import Security
import UIKit
import WebKit

// Reservekopie van de Pinterest-cookies in de Keychain, zodat je ingelogd blijft
// ook als WKWebView sessiecookies weggooit of nog niet naar schijf had geschreven.
// Het wachtwoord wordt nooit opgeslagen, alleen de cookies.
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

    // Vraag iOS om wat extra tijd, zodat het bewaren afkomt als de app naar de achtergrond gaat
    private static var backgroundTask = UIBackgroundTaskIdentifier.invalid

    static func saveBeforeSuspend() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask {
            MainActor.assumeIsolated { endBackgroundTask() }
        }
        Task {
            await save()
            endBackgroundTask()
        }
    }

    private static func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    static func restore() async {
        guard let data = readKeychain(),
              let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else { return }

        // Cookies die de webview zelf nog heeft zijn nieuwer dan de reservekopie: niet overschrijven
        let existing = Set(await store.allCookies().map { "\($0.name)|\($0.domain)|\($0.path)" })

        for s in stored {
            if let e = s.expires, e < Date() { continue }
            if existing.contains("\(s.name)|\(s.domain)|\(s.path)") { continue }
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

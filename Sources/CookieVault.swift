import Foundation
import os
import Security
import UIKit
import WebKit

// Een "site" in de kluis: welke cookies erbij horen en onder welk Keychain-account ze staan.
// Het Pinterest-account heet nog steeds "pinterest" (met dezelfde service), zodat het bestaande
// Keychain-item na een update gewoon blijft werken en je ingelogd blijft.
struct VaultSite: Sendable {
    let account: String
    let matches: @Sendable (String) -> Bool

    static let pinterest = VaultSite(account: "pinterest") { $0.contains("pinterest") }

    // YouTube-login staat in cookies van youtube.com én google.* (accounts.google.com, google.nl, ...)
    static let youtube = VaultSite(account: "youtube") { raw in
        let d = raw.hasPrefix(".") ? String(raw.dropFirst()) : raw
        if d == "youtube.com" || d.hasSuffix(".youtube.com") || d.hasSuffix("youtube-nocookie.com") { return true }
        // "google" moet het hoofdlabel zijn, met 1 of 2 labels erachter (com, nl, co.uk)
        let parts = d.split(separator: ".")
        guard let i = parts.firstIndex(of: "google") else { return false }
        return (1...2).contains(parts.count - i - 1)
    }

    static let all: [VaultSite] = [.pinterest, .youtube]
}

// Reservekopie van de cookies (Pinterest, YouTube/Google) in de Keychain, zodat je ingelogd blijft
// ook als WKWebView sessiecookies weggooit of nog niet naar schijf had geschreven.
// Het wachtwoord wordt nooit opgeslagen, alleen de cookies. Cookiewaarden worden nooit gelogd.
@MainActor
enum CookieVault {
    nonisolated private static let service = "nl.niels.pinfilter.cookies"
    nonisolated private static let log = Logger(subsystem: "nl.niels.pinfilter", category: "vault")
    private static var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    private struct StoredCookie: Codable {
        let name, value, domain, path: String
        let expires: Date?
        let isSecure, isHTTPOnly: Bool
        let sameSite: String?
    }

    // MARK: Opslaan

    // Pas opslaan als het terugzetten klaar is: anders kan een halve set cookies de goede kopie overschrijven
    private static var restored = false
    // Laatst weggeschreven gegevens per account, om onveranderde sets niet steeds opnieuw te schrijven
    private static var lastWritten: [String: Data] = [:]

    static func save() async {
        guard restored else { return }
        let all = await store.allCookies()
        let encoder = JSONEncoder()
        for site in VaultSite.all {
            let cookies = all.filter { site.matches($0.domain) }
            // Uitgelogd (geen cookies): de oude kopie laten staan, die overschrijven we niet met niets
            guard !cookies.isEmpty else { continue }
            let stored = cookies
                .sorted { ($0.domain, $0.name, $0.path) < ($1.domain, $1.name, $1.path) }
                .map {
                    StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                                 expires: $0.expiresDate, isSecure: $0.isSecure,
                                 isHTTPOnly: $0.isHTTPOnly, sameSite: $0.sameSitePolicy?.rawValue)
                }
            guard let data = try? encoder.encode(stored), lastWritten[site.account] != data else { continue }
            let account = site.account
            // Keychain-werk buiten de hoofdthread
            let ok = await Task.detached { writeKeychain(data, account: account) }.value
            if ok { lastWritten[site.account] = data }
        }
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

    // MARK: Cookies volgen

    // Inloggen gaat vaak via XHR en pushState (geen didFinish), en Google ververst zijn cookies
    // regelmatig. Daarom ook opslaan als de cookies veranderen, met een korte wachttijd.
    private final class Observer: NSObject, WKHTTPCookieStoreObserver {
        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in CookieVault.scheduleSave() }
        }
    }
    private static let observer = Observer()
    private static var observing = false
    private static var saveTask: Task<Void, Never>?

    private static func startObserving() {
        guard !observing else { return }
        observing = true
        store.add(observer)
    }

    private static func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { await save() }
        }
    }

    // MARK: Terugzetten

    // Pinterest en YouTube roepen dit allebei aan; de eerste doet het werk, de tweede wacht op dezelfde taak
    private static var restoreTask: Task<Void, Never>?

    static func restore() async {
        if let running = restoreTask {
            await running.value
            return
        }
        let task = Task { await performRestore() }
        restoreTask = task
        await task.value
    }

    private static func performRestore() async {
        defer {
            restored = true
            startObserving()
        }
        // Cookies die de webview zelf nog heeft zijn nieuwer dan de reservekopie: niet overschrijven
        let existing = Set(await store.allCookies().map { "\($0.name)|\($0.domain)|\($0.path)" })

        for site in VaultSite.all {
            let account = site.account
            guard let data = await Task.detached(operation: { readKeychain(account: account) }).value else { continue }
            lastWritten[account] = data
            guard let stored = try? JSONDecoder().decode([StoredCookie].self, from: data) else { continue }

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
    }

    // MARK: Keychain

    nonisolated private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    // Eerst bijwerken, pas toevoegen als er nog niets staat: zo is er nooit een moment zonder kopie
    nonisolated private static func writeKeychain(_ data: Data, account: String) -> Bool {
        let query = baseQuery(account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            for (k, v) in attributes { add[k] = v }
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status != errSecSuccess { log.error("Keychain schrijven mislukt, status \(status)") }
        return status == errSecSuccess
    }

    nonisolated private static func readKeychain(account: String) -> Data? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}

//
//  SessionManager.swift
//  Filament
//
//  Observable auth-state source of truth. Logged-in ⇔ a non-empty `sessionid`
//  cookie exists on instagram.com in the shared WKWebsiteDataStore.
//

import Foundation
import Combine
import WebKit

@MainActor
final class SessionManager: ObservableObject {

    static let shared = SessionManager()

    @Published private(set) var isAuthenticated = false

    private init() {}

    func refresh() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let wasAuthenticated = isAuthenticated
        isAuthenticated = cookies.contains {
            $0.name == "sessionid"
            && $0.domain.contains("instagram.com")
            && !$0.value.isEmpty
        }
        // A fresh session just landed: point the hidden bridge at it and stop
        // treating the old session's rate-limit history as current.
        if isAuthenticated && !wasAuthenticated {
            RequestGovernor.shared.reset()
            InstagramAPIBridge.shared.resetConnection()
        }
    }

    /// Instagram disowned the session cookie: the cookie is still on disk, so
    /// `refresh()` keeps saying "logged in", but every API call comes back as a
    /// logged-out HTML page. Retry can never fix that, so drop the cookies and
    /// let the login screen take over.
    func sessionRejected() async {
        guard isAuthenticated else { return }
        let store = WKWebsiteDataStore.default()
        let types: Set<String> = [WKWebsiteDataTypeCookies]
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
        InstagramAPIBridge.shared.invalidateCache()
        isAuthenticated = false
    }

    func logout() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records)
        InstagramAPIBridge.shared.invalidateCache()
        RequestGovernor.shared.reset()
        isAuthenticated = false
    }
}

//
//  InstagramAPIBridge.swift
//  Filament
//
//  The hidden WebView bridge — heart of the data layer.
//  ONE hidden WKWebView, logged into instagram.com, proxies API calls via
//  callAsyncJavaScript running fetch() inside IG's own origin. We fabricate no
//  fingerprint — real cookies/CSRF/UA attach automatically because we ARE the
//  real web client. Requests are human-paced and back off on challenges.
//

import Foundation
import Combine
import WebKit
import UIKit

/// One shared web identity. The login webview AND the bridge must present the
/// SAME User-Agent: the session is minted at login and used for writes (likes)
/// by the bridge — if those identities differ, IG treats a like as session
/// hijacking and invalidates the session. Desktop UA is required for the
/// `/api/v1/media/*` write endpoints (mobile UA → "useragent mismatch").
enum IGIdentity {
    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
}

enum BridgeError: LocalizedError {
    case notReady
    case badResponse
    case challengeRequired
    case rateLimited
    case sessionExpired
    case httpStatus(Int, String)
    case jsFailed(String)

    var errorDescription: String? {
        switch self {
        case .notReady:         return "Instagram session is still loading — try again in a moment."
        case .badResponse:      return "Couldn't read Instagram's response."
        case .challengeRequired:return "Instagram needs you to verify your account. Open Messages or Profile to finish the check."
        case .rateLimited:      return "Instagram asked us to slow down. Please wait a few minutes."
        case .sessionExpired:   return "Instagram signed us out (this can happen after several quick actions). Reopen the app or log in again."
        case .httpStatus(let c, let d):
            return d.isEmpty ? "Instagram returned an error (\(c))." : "Instagram error \(c): \(d)"
        case .jsFailed(let m):  return "Bridge error: \(m)"
        }
    }
}

@MainActor
final class InstagramAPIBridge: NSObject, ObservableObject {

    static let shared = InstagramAPIBridge()

    @Published private(set) var isReady = false

    private let webView: WKWebView
    private var didStart = false
    private var readySignaled = false

    // Human-pacing: small jittered gap between API calls. Kept modest so the app
    // feels responsive; still non-uniform (not machine-gun) for anti-detection.
    private var lastRequestAt = Date.distantPast
    private let minInterval: TimeInterval = 0.4

    // Standard Instagram web app id — sent so the API accepts our fetch().
    private let appID = "936619743392459"
    private let asbdID = "129477"

    // The logged-in user, resolved once and kept for the session (profile, DMs
    // and the comment composer all need it). Cleared on logout.
    private var cachedMe: User?

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // shared cookies/login
        config.allowsInlineMediaPlayback = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        // Must match the login webview's UA (see IGIdentity) so writes come from
        // the same identity the session was minted under.
        self.webView.customUserAgent = IGIdentity.desktopUserAgent
    }

    // MARK: - Lifecycle

    /// Attach the hidden webview to the key window and load IG once. Idempotent.
    func start() {
        guard !didStart else { return }
        didStart = true
        attachToWindow(retries: 12)
        webView.load(URLRequest(url: URL(string: "https://www.instagram.com/")!))
    }

    private var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    private func attachToWindow(retries: Int) {
        if let window = keyWindow {
            guard webView.superview == nil else { return }
            webView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
            webView.alpha = 0
            webView.isUserInteractionEnabled = false
            window.addSubview(webView)
        } else if retries > 0 {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 300_000_000)
                self.attachToWindow(retries: retries - 1)
            }
        }
    }

    private func ensureReady() async throws {
        if isReady { return }
        for _ in 0..<50 {                 // up to ~10s
            if isReady { return }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        throw BridgeError.notReady
    }

    private func pace() async {
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        let target = minInterval + Double.random(in: 0...0.3)   // jitter
        let wait = target - elapsed
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        lastRequestAt = Date()
    }

    // MARK: - Public API

    func feed(maxId: String?) async throws -> FeedPage {
        var body = "reason=\(maxId == nil ? "cold_start_fetch" : "pagination")"
        if let maxId { body += "&max_id=\(maxId)" }
        let text = try await callAPI(path: "/api/v1/feed/timeline/", method: "POST", body: body, form: true)
        return try ModelDecoder.timeline(from: text)
    }

    func storiesTray() async throws -> [Story] {
        let text = try await callAPI(path: "/api/v1/feed/reels_tray/", method: "GET")
        return try ModelDecoder.tray(from: text)
    }

    func like(post: Post, unlike: Bool) async throws {
        // The live route (`/web/likes/` 404s). It rejected us earlier only
        // because the app-id (desktop web) didn't match a mobile UA; now the
        // bridge presents a desktop UA, so the identity is consistent — the same
        // reason `/api/v1/feed/timeline/` works.
        let action = unlike ? "unlike" : "like"
        // The write endpoints want the numeric media PK, not the composite id.
        let body = "media_id=\(mediaPK(post.id))"
        _ = try await callAPI(path: "/api/v1/media/\(mediaPK(post.id))/\(action)/",
                              method: "POST", body: body, form: true)
    }

    func comments(for post: Post) async throws -> [Comment] {
        let text = try await callAPI(path: "/api/v1/media/\(mediaPK(post.id))/comments/?permalink_enabled=false",
                                     method: "GET")
        return try ModelDecoder.comments(from: text)
    }

    func addComment(to post: Post, text: String) async throws {
        let body = "comment_text=\(formEncode(text))"
        _ = try await callAPI(path: "/api/v1/media/\(mediaPK(post.id))/comment/",
                              method: "POST", body: body, form: true)
    }

    func storyItems(for story: Story) async throws -> [StoryItem] {
        let text = try await callAPI(path: "/api/v1/feed/user/\(story.author.id)/story/", method: "GET")
        return try ModelDecoder.story(from: text)
    }

    func currentUser() async throws -> User {
        if let cachedMe { return cachedMe }
        let text = try await callAPI(path: "/api/v1/accounts/current_user/", method: "GET")
        let user = try ModelDecoder.currentUser(from: text)
        cachedMe = user
        return user
    }

    /// Forget the resolved account (logout, or a session that expired).
    func invalidateCache() {
        cachedMe = nil
    }

    func currentUsername() async throws -> String {
        try await currentUser().username
    }

    // MARK: - Writes (API first, Instagram's own UI as the fallback)

    /// Set the like state. The private API is the fast path; if Instagram
    /// refuses the write, driving its real web UI is the reliable one.
    func setLike(_ liked: Bool, on post: Post) async throws {
        do {
            try await like(post: post, unlike: !liked)
        } catch let error as BridgeError {
            switch error {
            case .challengeRequired, .rateLimited, .sessionExpired:
                throw error
            default:
                try await WebActionBridge.shared.like(post: post, unlike: !liked)
            }
        }
    }

    /// Post a comment, same fallback ladder as likes.
    func postComment(on post: Post, text: String) async throws {
        do {
            try await addComment(to: post, text: text)
        } catch let error as BridgeError {
            switch error {
            case .challengeRequired, .rateLimited, .sessionExpired:
                throw error
            default:
                try await WebActionBridge.shared.comment(on: post, text: text)
            }
        }
    }

    // MARK: - Profile

    func profile(of user: User) async throws -> UserProfile {
        let text = try await callAPI(path: "/api/v1/users/\(user.id)/info/", method: "GET")
        return try ProfileDecoder.profile(from: text)
    }

    func userPosts(userID: String, maxId: String?) async throws -> ProfileFeedPage {
        var path = "/api/v1/feed/user/\(userID)/?count=12"
        if let maxId { path += "&max_id=\(maxId)" }
        let text = try await callAPI(path: path, method: "GET")
        return try ProfileDecoder.feed(from: text)
    }

    // MARK: - Direct messages

    func inbox() async throws -> [DirectThread] {
        let me = try await currentUser()
        let text = try await callAPI(
            path: "/api/v1/direct_v2/inbox/?use_unified_inbox=true&persistentBadging=true",
            method: "GET")
        return try DirectDecoder.threads(from: text, meID: me.id)
    }

    func thread(id: String, meID: String) async throws -> DirectThreadContent {
        let text = try await callAPI(
            path: "/api/v1/direct_v2/threads/\(id)/?use_unified_inbox=true",
            method: "GET")
        return try DirectDecoder.content(from: text, meID: meID)
    }

    func sendMessage(threadID: String, text: String) async throws {
        let body = "action=send_item"
            + "&thread_ids=[\(threadID)]"
            + "&text=\(formEncode(text))"
            + "&client_context=\(UUID().uuidString.lowercased())"
        _ = try await callAPI(path: "/api/v1/direct_v2/threads/broadcast/text/",
                              method: "POST", body: body, form: true)
    }

    // The like/comment endpoints want the numeric media PK, not IG's
    // "{pk}_{userid}" composite id.
    private func mediaPK(_ id: String) -> String {
        id.split(separator: "_").first.map(String.init) ?? id
    }

    private func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~ ")
        return (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s)
            .replacingOccurrences(of: " ", with: "+")
    }

    // MARK: - Core: run fetch() inside IG's origin

    private func callAPI(path: String, method: String = "GET",
                         body: String? = nil, form: Bool = false) async throws -> String {
        try await ensureReady()
        await pace()

        // callAsyncJavaScript wraps this in an async fn, so top-level await works
        // and `return` resolves it. Returning a plain object is fine (marshaled to
        // a dictionary); only Promises can't be marshaled.
        //
        // X-IG-WWW-Claim is IG's anti-abuse token: the real web client seeds it
        // with "0", then echoes back the `x-ig-set-www-claim` value from each
        // response. IG tolerates reads without it but flags WRITES (likes) that
        // lack it — and responds by expiring the session. We persist it on
        // `window` so it survives across calls (the bridge page loads once).
        let js = """
        if (typeof window.__strandClaim === 'undefined') { window.__strandClaim = '0'; }
        // Rollout hash that IG's real web AJAX calls send; cache it once.
        if (typeof window.__strandAjax === 'undefined') {
            var ajax = '1';
            try {
                if (window._sharedData && window._sharedData.rollout_hash) { ajax = window._sharedData.rollout_hash; }
                else { var mm = document.documentElement.innerHTML.match(/"rollout_hash":"([^"]+)"/); if (mm) { ajax = mm[1]; } }
            } catch (e) {}
            window.__strandAjax = ajax;
        }
        const headers = {
            'X-IG-App-ID': appID,
            'X-ASBD-ID': asbdID,
            'X-IG-WWW-Claim': window.__strandClaim,
            'X-Instagram-AJAX': window.__strandAjax,
            'X-Requested-With': 'XMLHttpRequest'
        };
        const csrf = (document.cookie.split('; ').find(c => c.indexOf('csrftoken=') === 0) || '').split('=')[1];
        if (csrf) { headers['X-CSRFToken'] = csrf; }
        const opts = { method: method, headers: headers, credentials: 'include' };
        if (body && body.length > 0) {
            opts.body = body;
            if (isForm) { headers['Content-Type'] = 'application/x-www-form-urlencoded'; }
        }
        const resp = await fetch(path, opts);
        try { const c = resp.headers.get('x-ig-set-www-claim'); if (c) { window.__strandClaim = c; } } catch (e) {}
        const text = await resp.text();
        return { status: resp.status, text: text };
        """

        let args: [String: Any] = [
            "path": path, "method": method, "body": body ?? "",
            "isForm": form, "appID": appID, "asbdID": asbdID
        ]

        let result: Any?
        do {
            result = try await webView.callAsyncJavaScript(js, arguments: args, in: nil, contentWorld: .page)
        } catch {
            throw BridgeError.jsFailed(error.localizedDescription)
        }

        guard let dict = result as? [String: Any],
              let status = dict["status"] as? Int,
              let text = dict["text"] as? String else {
            throw BridgeError.badResponse
        }

        // Anti-detection back-off: surface challenges/rate limits, never retry.
        if text.contains("challenge_required") || text.contains("checkpoint_required") {
            throw BridgeError.challengeRequired
        }
        if status == 429 || text.contains("feedback_required")
            || text.contains("please wait a few minutes") {
            throw BridgeError.rateLimited
        }
        guard (200..<300).contains(status) else {
            throw BridgeError.httpStatus(status, Self.message(from: text))
        }
        // 2xx but the body is HTML, not API JSON ⇒ IG served a logged-out /
        // interstitial page. Surface it clearly (instead of an opaque JSON decode
        // error downstream) and re-check whether we're still authenticated.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<") || text.contains("not-logged-in") || text.contains("\"require_login\"") {
            await SessionManager.shared.refresh()
            throw BridgeError.sessionExpired
        }
        return text
    }

    /// Pull IG's human-readable error out of a JSON body for diagnosis, else a snippet.
    private static func message(from json: String) -> String {
        struct M: Decodable { let message: String? }
        if let data = json.data(using: .utf8),
           let m = try? JSONDecoder().decode(M.self, from: data),
           let msg = m.message, !msg.isEmpty {
            return msg
        }
        return String(json.prefix(140))
    }
}

// MARK: - Navigation delegate (readiness signal)

extension InstagramAPIBridge: WKNavigationDelegate {
    // Ready as soon as the document commits — we only need a live JS context +
    // cookies for fetch(), NOT the full desktop SPA to finish downloading. This
    // is dramatically faster than waiting for `didFinish` under the desktop UA.
    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            guard !self.readySignaled else { return }
            self.readySignaled = true
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.isReady = true
            // NB: intentionally do NOT stopLoading() here — letting IG's own page
            // finish loading keeps the web session legitimate. Killing it early
            // made the client look automated and triggered intermittent
            // logged-out (HTML) responses on subsequent API calls.
        }
    }
}

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
import CryptoKit
import WebKit
import UIKit

/// One web identity: the login webview, the bridge and the action webview must
/// all present the SAME User-Agent, or Instagram treats a request as a
/// different client and revokes the session.
///
/// That identity is now **WKWebView's own** — deliberately no override. We used
/// to claim a macOS Safari 17 UA from an iPhone, which is precisely the
/// mismatch Instagram's anti-fraud looks for: the TLS and HTTP/2 stack is the
/// device's real iOS one while the header says desktop Mac. Sessions minted
/// under it get revoked a few requests later, which is the "signed us out"
/// state this app kept landing in. Leaving `customUserAgent` nil makes the UA
/// agree with the stack that actually sent the bytes.
enum IGIdentity {
    static let userAgent: String? = nil
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
        case .rateLimited:      return "Instagram asked us to slow down. Filament has stopped sending requests until the block clears."
        case .sessionExpired:   return "Instagram ended this session. Signing you back in…"
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

    /// What Instagram actually answered the last time a request failed, verbatim
    /// enough to act on. Negative states show it, so a report can say which
    /// endpoint and status instead of "it says slow down".
    @Published private(set) var lastFailure: String?

    private let webView: WKWebView
    private var didStart = false
    private var readySignaled = false

    // Reads are deliberately slow: the pacing verified against current
    // browser-origin clients is ~4s between reads. At the old 0.4s the app
    // looked like a bot and got the account cooled down within a session.
    private var lastRequestAt = Date.distantPast
    private let minInterval: TimeInterval = 4.0
    private let writeInterval: TimeInterval = 12.0

    // Standard Instagram web app id — sent so the API accepts our fetch().
    private let appID = "936619743392459"
    private let asbdID = "129477"

    // The logged-in user, resolved once and kept for the session (profile, DMs
    // and the comment composer all need it). Cleared on logout.
    private var cachedMe: User?

    // Requests currently in flight, keyed like the response cache. Two screens
    // asking for the same thing share one request instead of sending two.
    private var inFlight: [String: Task<String, Error>] = [:]

    private override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()          // shared cookies/login
        config.allowsInlineMediaPlayback = true
        self.webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        self.webView.navigationDelegate = self
        // Must match the login webview's UA (see IGIdentity) so requests come
        // from the same identity the session was minted under.
        self.webView.customUserAgent = IGIdentity.userAgent
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

    /// Wait out the gap before the next call. The gap widens on its own after
    /// Instagram has told us off, so a session that got blocked recovers more
    /// slowly than the one that caused it.
    private func pace(isWrite: Bool) async {
        let base = RequestGovernor.shared.pacedInterval(base: isWrite ? writeInterval : minInterval)
        let elapsed = Date().timeIntervalSince(lastRequestAt)
        let target = base + Double.random(in: 0...0.3)   // jitter
        let wait = target - elapsed
        if wait > 0 {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        lastRequestAt = Date()
    }

    // MARK: - Public API

    func feed(maxId: String?) async throws -> FeedPage {
        // Form fields taken from instagram-go's GetTimeline: a bare
        // `reason=...` body is not what the web client sends.
        var body = "reason=\(maxId == nil ? "cold_start_fetch" : "pagination")"
            + "&is_pull_to_refresh=0"
            + "&phone_id=00000000-0000-0000-0000-000000000000"
            + "&battery_level=100"
            + "&is_charging=1"
            + "&will_sound_on=0"
        if let maxId { body += "&max_id=\(maxId)" }
        let text = try await callAPI(path: "/api/v1/feed/timeline/", method: "POST", body: body, form: true, ttl: 60)
        return try ModelDecoder.timeline(from: text)
    }

    func storiesTray() async throws -> [Story] {
        let text = try await callAPI(path: "/api/v1/feed/reels_tray/", method: "GET", ttl: 180)
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
                                     method: "GET", ttl: 45)
        return try ModelDecoder.comments(from: text)
    }

    func addComment(to post: Post, text: String) async throws {
        let body = "comment_text=\(formEncode(text))"
        _ = try await callAPI(path: "/api/v1/media/\(mediaPK(post.id))/comment/",
                              method: "POST", body: body, form: true)
    }

    func storyItems(for story: Story) async throws -> [StoryItem] {
        // `/feed/user/{pk}/story/` is the old path and is routinely refused now.
        // The web story viewer asks `/feed/reels_media/` — the same family as
        // `reels_tray`, which still answers — so try that first.
        do {
            // POST with one `reel_ids[]` per reel and `source` — the verified
            // form in instagram-go's GetReelsMedia. The previous GET with a
            // comma-joined `reel_ids` was not a request the client makes.
            let body = "reel_ids[]=\(story.author.id)&source=reel_feed_timeline"
            let text = try await callAPI(path: "/api/v1/feed/reels_media/", method: "POST",
                                         body: body, form: true, ttl: 60)
            let items = try SwiftModelDecoder.reelsMedia(from: text)
            if !items.isEmpty { return items }
        } catch BridgeError.rateLimited {
            throw BridgeError.rateLimited
        } catch BridgeError.challengeRequired {
            throw BridgeError.challengeRequired
        } catch BridgeError.sessionExpired {
            throw BridgeError.sessionExpired
        } catch {
            // Fall through to the older endpoint below.
        }

        let text = try await callAPI(path: "/api/v1/feed/user/\(story.author.id)/story/", method: "GET", ttl: 60)
        return try ModelDecoder.story(from: text)
    }

    /// Mark a viewed story segment as seen. The v2 endpoint takes one form key
    /// per reel, valued `<media_pk>_<reel_id>_<taken_at>` — verified against
    /// instagram-go's MarkStorySeen. Called by the player, not by a tab load,
    /// so it never adds to the read budget.
    func markStorySeen(item: StoryItem, reelID: String) async throws {
        guard !reelID.isEmpty else { return }
        let key = "\(item.id)_\(reelID)_\(Int(item.takenAt.timeIntervalSince1970))"
        let body = "reels[\(reelID)][]=\(formEncode(key))&container_module=feed_timeline"
        _ = try await callAPI(path: "/api/v2/media/seen/", method: "POST",
                              body: body, form: true)
    }

    /// Resolve the logged-in user by numeric ID.
    ///
    /// This used to call `/api/v1/accounts/current_user/`. Both instagram-go
    /// and igflare document that this endpoint frequently answers with a
    /// redirect-to-login on a *healthy* web session, so it was making every
    /// feature — feed, stories, inbox, profile — look logged out. The stable
    /// route on a web session is the same `/users/{pk}/info/` used for session
    /// validation by those clients. The pk comes from the `ds_user_id` cookie.
    func currentUser() async throws -> User {
        if let cachedMe { return cachedMe }
        guard let id = await sessionUserID() else {
            throw BridgeError.sessionExpired
        }
        let text = try await callAPI(path: "/api/v1/users/\(id)/info/", method: "GET", ttl: 600)
        let user = try ModelDecoder.currentUser(from: text)
        cachedMe = user
        return user
    }

    /// `ds_user_id` is the authoritative account id on a web session. Fall back
    /// to the numeric prefix of `sessionid`, which carries the same id.
    private func sessionUserID() async -> String? {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let igCookies = cookies.filter { $0.domain.contains("instagram.com") }
        if let ds = igCookies.first(where: { $0.name == "ds_user_id" }), !ds.value.isEmpty {
            return ds.value
        }
        if let session = igCookies.first(where: { $0.name == "sessionid" }) {
            return session.value.split(separator: ":").first.map(String.init)
        }
        return nil
    }

    /// Forget the resolved account and every cached response (logout, or a
    /// session that expired).
    func invalidateCache() {
        cachedMe = nil
        ResponseCache.shared.removeAll()
    }

    /// Start over on a fresh session: reload the hidden page so it picks up the
    /// cookies the user just minted, and drop everything tied to the old one.
    func resetConnection() {
        lastFailure = nil
        invalidateCache()
        guard didStart else { return }
        isReady = false
        readySignaled = false
        webView.reload()
    }

    func currentUsername() async throws -> String {
        try await currentUser().username
    }

    // MARK: - Writes (API first, Instagram's own UI as the fallback)

    /// Set the like state.
    ///
    /// Instagram's raw write endpoints carry none of the integrity tokens its
    /// page JS attaches, and writing through them is the classic way an account
    /// gets put on `feedback_required` for everything else too. Clicking its own
    /// like button in a hidden webview is an action it trusts — and the user
    /// never sees it, so the cost is a few hundred ms, not a browser.
    func setLike(_ liked: Bool, on post: Post) async throws {
        do {
            try await WebActionBridge.shared.like(post: post, unlike: !liked)
        } catch {
            try await like(post: post, unlike: !liked)
        }
    }

    /// Post a comment, same ladder: Instagram's own UI first, raw endpoint after.
    func postComment(on post: Post, text: String) async throws {
        do {
            try await WebActionBridge.shared.comment(on: post, text: text)
        } catch {
            try await addComment(to: post, text: text)
        }
    }

    // MARK: - Profile

    func profile(of user: User) async throws -> UserProfile {
        let text = try await callAPI(path: "/api/v1/users/\(user.id)/info/", method: "GET", ttl: 300)
        return try ProfileDecoder.profile(from: text)
    }

    /// A profile header and the first grid page, preferring the endpoint the web
    /// client uses (one request, and not one of the ones being refused), and
    /// falling back to the older two-call pair.
    func profileSnapshot(username: String) async throws -> ProfileSnapshot {
        do {
            let text = try await callAPI(path: "/api/v1/users/web_profile_info/?username=\(username)",
                                         method: "GET", ttl: 240)
            return try ProfileDecoder.snapshot(from: text)
        } catch BridgeError.rateLimited {
            throw BridgeError.rateLimited
        } catch BridgeError.challengeRequired {
            throw BridgeError.challengeRequired
        } catch BridgeError.sessionExpired {
            throw BridgeError.sessionExpired
        } catch {
            let me = try await currentUser()
            let page = try await userPosts(userID: me.id, maxId: nil)
            let profile = try await profile(of: me)
            return ProfileSnapshot(profile: profile, page: page)
        }
    }

    func userPosts(userID: String, maxId: String?) async throws -> ProfileFeedPage {
        var path = "/api/v1/feed/user/\(userID)/?count=12"
        if let maxId { path += "&max_id=\(maxId)" }
        let text = try await callAPI(path: path, method: "GET", ttl: 240)
        return try ProfileDecoder.feed(from: text)
    }

    // MARK: - Direct messages

    func inbox() async throws -> [DirectThread] {
        let me = try await currentUser()
        let text = try await callAPI(
            path: "/api/v1/direct_v2/inbox/?limit=20&thread_message_limit=1&visual_message_return_type=unseen&persistentBadging=true",
            method: "GET", ttl: 45)
        return try DirectDecoder.threads(from: text, meID: me.id)
    }

    func thread(id: String, meID: String) async throws -> DirectThreadContent {
        let text = try await callAPI(
            path: "/api/v1/direct_v2/threads/\(id)/?limit=20&visual_message_return_type=unseen",
            method: "GET")
        return try DirectDecoder.content(from: text, meID: meID)
    }

    func sendMessage(threadID: String, text: String) async throws {
        let context = UUID().uuidString.lowercased()
        var digits = UInt64(0)
        for byte in SHA256.hash(data: Data(context.utf8)).prefix(8) {
            digits = (digits << 8) | UInt64(byte)
        }
        let offlineID = String(digits & 0x7FFF_FFFF_FFFF_FFFF)
        // Verified against instagram-go's broadcastDirectText: the same
        // client_context must also be sent as mutation_token and as the seed
        // for offline_threading_id, or the broadcast can be duplicated.
        let body = "action=send_item"
            + "&thread_ids=[\(threadID)]"
            + "&text=\(formEncode(text))"
            + "&client_context=\(context)"
            + "&mutation_token=\(context)"
            + "&offline_threading_id=\(offlineID)"
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
                         body: String? = nil, form: Bool = false,
                         ttl: TimeInterval = 0) async throws -> String {
        let key = "\(method) \(path) \(body ?? "")"

        // Fresh enough already: no request at all.
        if let fresh = ResponseCache.shared.fresh(for: key, ttl: ttl) { return fresh }

        // The same request is already out: share it rather than send two.
        if let existing = inFlight[key] { return try await existing.value }

        // Instagram asked us to slow down. Honour it before the webview, the
        // network or the pacing wait — and show what we already have.
        if RequestGovernor.shared.isCoolingDown {
            if let stale = ResponseCache.shared.entry(for: key) { return stale.text }
            throw BridgeError.rateLimited
        }

        try await ensureReady()

        let task = Task { try await self.perform(path: path, method: method,
                                                 body: body, form: form, key: key) }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        do {
            return try await task.value
        } catch BridgeError.rateLimited {
            // A stale body beats a dead screen while the block clears.
            if let stale = ResponseCache.shared.entry(for: key) { return stale.text }
            throw BridgeError.rateLimited
        }
    }

    /// The actual trip: paced, sent through the hidden webview's own origin, and
    /// recorded in the cache and the governor.
    private func perform(path: String, method: String, body: String?,
                         form: Bool, key: String) async throws -> String {
        await pace(isWrite: method != "GET")

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
        // Rollout hash that IG's real web AJAX calls send; cache it once. When
        // it can't be found we send NO header at all — a fabricated "1" is a
        // signature no real client has.
        if (typeof window.__strandAjax === 'undefined') {
            var ajax = '';
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
            'X-Requested-With': 'XMLHttpRequest'
        };
        if (window.__strandAjax) { headers['X-Instagram-AJAX'] = window.__strandAjax; }
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
        return { status: resp.status, text: text,
                 redirected: resp.redirected, url: resp.url };
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
        // Each failure keeps a verbatim record so the error states can show what
        // Instagram actually said instead of a guess.
        func note(_ kind: String) {
            lastFailure = "\(kind) · \(method) \(path) · HTTP \(status) · \(Self.snippet(text))"
        }

        if text.contains("challenge_required") || text.contains("checkpoint_required") {
            note("challenge")
            throw BridgeError.challengeRequired
        }
        if status == 429 || text.contains("feedback_required")
            || text.contains("please wait a few minutes") {
            // Start the cooldown BEFORE throwing, so every other screen stops
            // sending on its own instead of adding to the pile.
            note("rate limited")
            RequestGovernor.shared.registerRateLimit()
            throw BridgeError.rateLimited
        }
        guard (200..<300).contains(status) else {
            note("HTTP \(status)")
            throw BridgeError.httpStatus(status, Self.message(from: text))
        }
        // 2xx but the body is HTML, not API JSON ⇒ IG served a logged-out /
        // interstitial page. Surface it clearly (instead of an opaque JSON decode
        // error downstream) and re-check whether we're still authenticated.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let bouncedToLogin = (dict["redirected"] as? Bool == true)
            || (dict["url"] as? String ?? "").contains("/accounts/login/")
        let looksLoggedOut = trimmed.hasPrefix("<")
            || text.contains("not-logged-in")
            || text.contains("\"require_login\"")
        if looksLoggedOut {
            // A redirect to the login page on an already-validated session is
            // how Instagram signals a soft block (verified in instagram-go),
            // NOT a dead session. Killing cookies here is what made every
            // feature fail moments after login.
            if bouncedToLogin {
                note("soft block / login redirect")
                RequestGovernor.shared.registerRateLimit()
                throw BridgeError.rateLimited
            }
            note("session rejected")
            await SessionManager.shared.sessionRejected()
            throw BridgeError.sessionExpired
        }
        // Keep it: to answer the next repeat request inside its TTL, and as the
        // fallback for the next time Instagram blocks us.
        ResponseCache.shared.store(text, for: key)
        RequestGovernor.shared.registerSuccess()
        if lastFailure != nil { lastFailure = nil }
        return text
    }

    /// One collapsed line of a response body, for the diagnostics note.
    private static func snippet(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > 180 ? String(collapsed.prefix(180)) + "…" : collapsed
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

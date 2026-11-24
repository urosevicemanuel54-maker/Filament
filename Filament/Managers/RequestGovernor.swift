//
//  RequestGovernor.swift
//  Filament
//
//  One shared brake for every request the app makes to Instagram.
//
//  Instagram's "please wait a few minutes" (HTTP 429 / `feedback_required`) is
//  a temporary block on the ACCOUNT, and every extra request while it is in
//  force restarts the timer. Without a single owner of that state each screen
//  kept retrying on its own — the tab `.task`s, the manual "Try Again" buttons
//  and the DM poll loop — so the block never had a chance to clear and the app
//  looked permanently broken.
//
//  So: one observable cooldown, escalating each time it happens again, and
//  persisted across launches so reopening the app does not immediately
//  re-trigger what it was just punished for.
//

import Foundation
import Combine

@MainActor
final class RequestGovernor: ObservableObject {

    static let shared = RequestGovernor()

    /// When the current cooldown ends, or nil when requests are allowed.
    @Published private(set) var cooldownEndsAt: Date?

    /// How many times in a row Instagram has asked us to slow down. Drives the
    /// back-off ladder and the pacing between calls.
    @Published private(set) var strikes: Int

    private let defaults = UserDefaults.standard
    private let cooldownKey = "filament.governor.cooldownUntil"
    private let strikesKey = "filament.governor.strikes"
    private var expiryTask: Task<Void, Never>?

    /// 1 minute, then 3, 10, 20, 30. Long enough that a repeat offence is
    /// actually punished (Instagram's own advice is "a few minutes"), short
    /// enough that clearing it once is enough to get back to normal.
    private static let ladder: [TimeInterval] = [60, 180, 600, 1_200, 1_800]

    init() {
        strikes = defaults.integer(forKey: strikesKey)
        if let stored = defaults.object(forKey: cooldownKey) as? Date, stored > Date() {
            cooldownEndsAt = stored
        }
        scheduleExpiry()
    }

    // MARK: - Reading

    var isCoolingDown: Bool { remaining > 0 }

    /// Seconds left before requests may go out again.
    var remaining: TimeInterval {
        remaining(at: Date())
    }

    /// `remaining` evaluated against an explicit instant, so a countdown view
    /// can tick without mutating any state.
    func remaining(at date: Date) -> TimeInterval {
        guard let end = cooldownEndsAt else { return 0 }
        return max(0, end.timeIntervalSince(date))
    }

    /// Pacing between calls. Politeness is not a bug here: a burst of five
    /// calls inside one second is what trips the block in the first place.
    func pacedInterval(base: TimeInterval) -> TimeInterval {
        guard strikes > 0 else { return base }
        return min(base * pow(2, Double(strikes)), 6)
    }

    // MARK: - Writing

    /// Instagram told us to slow down: start (or extend) the cooldown.
    func registerRateLimit() {
        strikes = min(strikes + 1, Self.ladder.count)
        let wait = Self.ladder[min(strikes - 1, Self.ladder.count - 1)]
        cooldownEndsAt = Date().addingTimeInterval(wait)
        defaults.set(strikes, forKey: strikesKey)
        defaults.set(cooldownEndsAt, forKey: cooldownKey)
        scheduleExpiry()
    }

    /// A request got through, so the block has lifted: forget the strikes.
    func registerSuccess() {
        guard cooldownEndsAt == nil, strikes > 0 else { return }
        strikes = 0
        defaults.set(0, forKey: strikesKey)
    }

    /// Logout: none of this account's history is worth keeping.
    func reset() {
        expiryTask?.cancel()
        expiryTask = nil
        cooldownEndsAt = nil
        strikes = 0
        defaults.removeObject(forKey: cooldownKey)
        defaults.removeObject(forKey: strikesKey)
    }

    // MARK: - Expiry

    /// Clear the cooldown when it runs out, so every observing screen re-enables
    /// itself without polling.
    private func scheduleExpiry() {
        expiryTask?.cancel()
        guard let end = cooldownEndsAt else { return }
        expiryTask = Task { [weak self] in
            let wait = max(0, end.timeIntervalSinceNow)
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.cooldownEndsAt = nil
            self.defaults.removeObject(forKey: self.cooldownKey)
        }
    }
}

//
//  SlowedDownBanner.swift
//  Filament
//
//  The one thing shown while Instagram is refusing requests: what happened, how
//  long it lasts, and a retry that only appears once it can actually work.
//

import SwiftUI

struct SlowedDownBanner: View {
    @ObservedObject private var governor = RequestGovernor.shared
    @ObservedObject private var bridge = InstagramAPIBridge.shared

    /// Called when the retry button is tapped. Omit for a read-only banner.
    var onRetry: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: Date.now, by: 1)) { context in
            let remaining = governor.remaining(at: context.date)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hourglass")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 2) {
                    Text(remaining > 0 ? "Showing saved content" : "Instagram asked us to slow down")
                        .font(.footnote.weight(.semibold))
                    Text(remaining > 0
                         ? "Requests are paused for \(Self.clock(remaining)). Filament stops sending, instead of making the block longer."
                         : "You can try again now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // What Instagram actually answered — the difference between
                    // "it still says slow down" and a fix.
                    if let lastFailure = bridge.lastFailure {
                        Text(lastFailure)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 0)

                if remaining <= 0, let onRetry {
                    Button("Retry", action: onRetry)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
        }
    }

    /// "2:41" past a minute, "38s" below it.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        let minutes = total / 60
        let rest = total % 60
        return minutes > 0 ? String(format: "%d:%02d", minutes, rest) : "\(rest)s"
    }
}

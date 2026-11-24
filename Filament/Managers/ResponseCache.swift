//
//  ResponseCache.swift
//  Filament
//
//  Raw Instagram response bodies, keyed by request, kept in memory and on disk.
//
//  Two jobs:
//
//  - **Fewer requests.** A screen revisited inside its TTL never touches the
//    network. Switching tabs used to re-fetch everything every time, which made
//    the app hit Instagram far harder than the web client it imitates.
//  - **Something to show while Instagram refuses us.** During a cooldown the
//    last good body for a request is served instead of an error, so the app
//    degrades to slightly stale content rather than three dead screens.
//

import CryptoKit
import Foundation

@MainActor
final class ResponseCache {

    static let shared = ResponseCache()

    struct Entry {
        let text: String
        let storedAt: Date
    }

    private var memory: [String: Entry] = [:]
    private let directory: URL?

    /// Bodies bigger than this stay in memory only — a timeline page is a few
    /// hundred KB and there is no point writing several MB per endpoint.
    private static let diskLimit = 2 * 1024 * 1024

    private init() {
        directory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FilamentResponses", isDirectory: true)
        if let directory {
            try? FileManager.default.createDirectory(at: directory,
                                                     withIntermediateDirectories: true)
        }
    }

    // MARK: - Reading

    /// The body for `key` if it is younger than `ttl`, else nil.
    func fresh(for key: String, ttl: TimeInterval) -> String? {
        guard ttl > 0, let entry = entry(for: key) else { return nil }
        return Date().timeIntervalSince(entry.storedAt) < ttl ? entry.text : nil
    }

    /// The body for `key` regardless of age — the last thing Instagram said.
    func entry(for key: String) -> Entry? {
        if let cached = memory[key] { return cached }
        guard let url = fileURL(for: key),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let storedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))
            .flatMap { $0[.modificationDate] as? Date } ?? .distantPast
        let entry = Entry(text: text, storedAt: storedAt)
        memory[key] = entry
        return entry
    }

    // MARK: - Writing

    func store(_ text: String, for key: String) {
        memory[key] = Entry(text: text, storedAt: Date())
        guard let url = fileURL(for: key),
              let data = text.data(using: .utf8),
              data.count <= Self.diskLimit else { return }
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Logout: drop everything, on disk too.
    func removeAll() {
        memory.removeAll()
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    // MARK: - Keys

    /// Requests carry long paths and form bodies, so the key is hashed into a
    /// filename rather than percent-encoded.
    private func fileURL(for key: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }
}

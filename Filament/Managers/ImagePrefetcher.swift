//
//  ImagePrefetcher.swift
//  Filament
//
//  Warms the shared URLCache for photos that are about to scroll into view, so
//  AsyncImage finds them locally instead of starting a download mid-scroll.
//

import Foundation

final class ImagePrefetcher {

    static let shared = ImagePrefetcher()

    /// Prefetch only when the network is free: no cellular, no Low Data Mode.
    private let session: URLSession

    private var inFlight: Set<URL> = []

    private init() {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache.shared
        config.requestCachePolicy = .useProtocolCachePolicy
        config.allowsExpensiveNetworkAccess = false
        config.allowsConstrainedNetworkAccess = false
        session = URLSession(configuration: config)
    }

    /// Fetch `urls` (at most `limit`) into the shared cache. Already-cached and
    /// already-running URLs are skipped.
    func prefetch(_ urls: [URL], limit: Int = 6) {
        for url in urls.prefix(limit) where !inFlight.contains(url) {
            guard URLCache.shared.cachedResponse(for: URLRequest(url: url)) == nil else {
                continue
            }
            inFlight.insert(url)
            let task = session.dataTask(with: URLRequest(url: url)) { [weak self] _, _, _ in
                Task { @MainActor in
                    _ = self?.inFlight.remove(url)
                }
            }
            task.resume()
        }
    }
}

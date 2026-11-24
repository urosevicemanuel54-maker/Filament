//
//  FilamentApp.swift
//  Filament
//

import SwiftUI

@main
struct FilamentApp: App {

    init() {
        // AsyncImage keeps no images of its own and URLSession.shared's cache is
        // the 512 KB / 10 MB default — every re-scroll re-downloaded every photo.
        // Give the shared cache real budgets before anything loads.
        URLCache.shared = URLCache(
            memoryCapacity: 64 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            directory: nil
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

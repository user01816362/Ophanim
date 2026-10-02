//
//  AppContainer.swift
//  Ophanim
//
//  Per-app data-container paths (container dir, prefs plist) + existence/clear.
//  Created by Александр Дорофеев on 07.12.2021.
//

import Foundation

struct AppContainer {

    private static let containersURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Containers")

    let bundleId: String
    /// The OS-owned data-container path for an app.
    ///
    /// - Returns: The `~/Library/Containers/<bid>` URL (may not exist yet).
    var containerUrl: URL {
        AppContainer.containersURL.appendingPathComponent(bundleId)
    }

    /// The app's preferences plist. Same path the Container pane shows and the
    /// library menu deletes — agents use ContainerTools instead of rebuilding it.
    ///
    /// - Returns: The `.../Preferences/<bid>.plist` URL (may not exist yet).
    var userPrefsUrl: URL {
        containerUrl.appendingPathComponent("Data")
            .appendingPathComponent("Library")
            .appendingPathComponent("Preferences")
            .appendingPathComponent(bundleId)
            .appendingPathExtension("plist")
    }

    init(bundleId: String) {
        self.bundleId = bundleId
    }

    public func clear() {
        FileManager.default.delete(at: containerUrl)
    }

    public func doesExist() -> Bool {
        FileManager.default.fileExists(atPath: containerUrl.path)
    }
}

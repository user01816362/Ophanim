//
//  InstallSettings.swift
//  Ophanim
//
//  Install-flow preferences (Galgal default, install popup). Driven by the install
//  dialog and headless callers; no dedicated settings tab.
//

import SwiftUI

/// Install-flow preferences (no dedicated tab; the install dialog + defaults drive
/// these). The per-app Application Type lives on each app's settings instead.
class InstallPreferences: NSObject, ObservableObject {
    nonisolated(unsafe) static var shared: InstallPreferences = {
        // @AppStorage init is MainActor-isolated; first access may come from a
        // background thread (MCP transport), so hop to main instead of assuming it.
        if Thread.isMainThread { InstallPreferences() } else { DispatchQueue.main.sync { InstallPreferences() } }
    }()

    @objc @AppStorage("AlwaysInstallGalgal") var alwaysInstallGalgal = true

    @AppStorage("ShowInstallPopup") var showInstallPopup = false
}

//
//  InstallSettings.swift
//  Ophanim
//
//  Created by TheMoonThatRises on 10/9/22.
//

import SwiftUI

/// Install-flow preferences. The dedicated Install settings tab was removed; these are driven by
/// the install dialog (and sensible defaults). The per-app "Application Type" now lives on each
/// app's Application settings tab instead of a global default.
class InstallPreferences: NSObject, ObservableObject {
    nonisolated(unsafe) static var shared: InstallPreferences = {
        // @AppStorage init is MainActor-isolated; first access may come from a
        // background thread (MCP transport), so hop to main instead of assuming it.
        if Thread.isMainThread { InstallPreferences() } else { DispatchQueue.main.sync { InstallPreferences() } }
    }()

    @objc @AppStorage("AlwaysInstallGalgal") var alwaysInstallGalgal = true

    @AppStorage("ShowInstallPopup") var showInstallPopup = false
}

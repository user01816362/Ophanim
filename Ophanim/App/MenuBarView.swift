//
//  MenuBarView.swift
//  Ophanim
//
//  App menu commands: log copy + signing setup, Help replacements, cache clearing.
//  Thin Commands wrappers; no state of their own.
//

import AppKit
import SwiftUI
import DataCache

/// App-menu additions after System Services: copy the log, open signing setup.
struct OphanimMenuView: Commands {
    @Binding var isSigningSetupShown: Bool
    var body: some Commands {
        CommandGroup(after: .systemServices) {
            Button("menubar.log.copy", systemImage: "document.on.document.fill") {
                Log.shared.logdata.copyToClipBoard()
            }
            .keyboardShortcut("L", modifiers: [.command, .option])
            Button("menubar.configSigning", systemImage: "signature") {
                isSigningSetupShown = true
            }
        }
    }
}

/// Help-menu replacement: docs, website, repo links (plus a debug crash trigger).
struct OphanimHelpMenuView: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("menubar.documentation", systemImage: "document.fill") {
                if let url = URL(string: "https://docs.ophanim.io") {
                    NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                }
            }
            Divider()
            Button("menubar.website", systemImage: "network") {
                if let url = URL(string: "https://ophanim.io") {
                    NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                }
            }
            Button("menubar.github", systemImage: "arrow.up.right") {
                if let url = URL(string: "https://github.com/Ophanim/Ophanim/") {
                    NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                }
            }
            #if DEBUG
            Divider()
            Button("[DEBUG] Crash app", systemImage: "xmark.circle.fill") {
                fatalError("Crash was triggered")
            }
            #endif
        }
    }
}

/// View-menu replacement: cache clearing. Wipes both the DataCache store and the
/// app's on-disk image cache, which are separate stores.
struct OphanimViewMenuView: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(before: .sidebar) {
            Button("menubar.clearCache", systemImage: "eraser.fill") {
                DataCache.instance.cleanAll()

                if let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
                   let bundleID = Bundle.main.bundleIdentifier {
                    FileManager.default.delete(at: cacheDir.appendingPathComponent(bundleID)
                        .appendingPathComponent("Image Cache"))
                }
            }
            .keyboardShortcut("R", modifiers: [.command, .shift])
            Divider()
        }
    }
}

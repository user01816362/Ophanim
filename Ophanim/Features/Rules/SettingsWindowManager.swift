//
//  SettingsWindowManager.swift
//  Ophanim
//
//  Standalone editor-window owner plus the rules-domain shims. One resizable,
//  non-modal NSWindow per key; SwiftUI content hosted in AppKit (macOS 12 has no
//  SwiftUI openWindow(for:)).
//

import SwiftUI
import AppKit

/// Single owner for standalone, resizable, non-modal editor windows.
/// One window per key - re-opening brings the existing one to the front.
/// Lifetime owned by `windows` (`isReleasedWhenClosed = false`).
/// macOS 12 can't use SwiftUI's openWindow/WindowGroup(for:), so views are
/// hosted in AppKit windows directly. Callers keep their tiny manager shims
/// (same `.shared.show(...)` signatures); this class owns all NSWindow work.
/// @MainActor: every method touches AppKit, which is main-thread only.
@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()
    private var windows: [String: NSWindow] = [:]

    /// Shows content in a standalone window keyed by `key`; re-showing brings the
    /// existing window forward. Non-content-driven windows get a fixed size (SwiftUI
    /// ideal size is ambiguous under maxWidth/maxHeight .infinity).
    ///
    /// - Parameter key: The window identity (one window per key).
    /// - Parameter title: The window title.
    /// - Parameter size: The initial content size.
    /// - Parameter minSize: The minimum content size.
    /// - Parameter contentDrivenSize: When true, SwiftUI drives the size (Recon/Log).
    /// - Parameter content: The SwiftUI content to host.
    func show<Content: View & Sendable>(key: String, title: String,
                             size: NSSize, minSize: NSSize,
                             contentDrivenSize: Bool = false,
                             content: Content) {
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: content)
        // Don't let the SwiftUI content drive the window size (its maxWidth/maxHeight .infinity makes
        // the preferred size ambiguous → opens at the wrong size). setContentSize is the source of truth.
        // Skipped for content-driven windows (Recon/Log), which relied on the default behavior.
        if !contentDrivenSize { hosting.sizingOptions = [] }
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(size)
        window.contentMinSize = minSize
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        windows[key] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== closing }
    }
}

// MARK: - Rules-domain shims (call sites unchanged)

/// Opens the rules editor. AppSettings is a reference type, so the editor mutates
/// the shared instance in place (persisted via its didSet→encode).
@MainActor
final class RulesWindowManager: NSObject {
    static let shared = RulesWindowManager()
    func show(settings: AppSettings) {
        let key = settings.info.bundleIdentifier
        SettingsWindowManager.shared.show(key: key, title: "Interception Rules - \(key)",
                                          size: NSSize(width: 800, height: 540),
                                          minSize: NSSize(width: 620, height: 400),
                                          content: RulesEditorView(settings: settings))
    }
}

@MainActor
final class ObjCHooksWindowManager: NSObject {
    static let shared = ObjCHooksWindowManager()
    func show(settings: AppSettings) {
        let key = settings.info.bundleIdentifier
        SettingsWindowManager.shared.show(key: key, title: "ObjC Boundary Hooks - \(key)",
                                          size: NSSize(width: 800, height: 540),
                                          minSize: NSSize(width: 620, height: 400),
                                          content: ObjCHooksEditorView(settings: settings))
    }
}

@MainActor
final class SwiftHooksWindowManager: NSObject {
    static let shared = SwiftHooksWindowManager()
    func show(settings: AppSettings) {
        let key = settings.info.bundleIdentifier
        SettingsWindowManager.shared.show(key: key, title: "Swift Vtable Hooks - \(key)",
                                          size: NSSize(width: 800, height: 540),
                                          minSize: NSSize(width: 620, height: 400),
                                          content: SwiftHooksEditorView(settings: settings))
    }
}

@MainActor
final class InlineHooksWindowManager: NSObject {
    static let shared = InlineHooksWindowManager()
    func show(settings: AppSettings) {
        let key = settings.info.bundleIdentifier
        SettingsWindowManager.shared.show(key: key, title: "Inline Hooks - \(key)",
                                          size: NSSize(width: 1100, height: 640),
                                          minSize: NSSize(width: 820, height: 460),
                                          content: InlineHooksEditorView(settings: settings))
    }
}

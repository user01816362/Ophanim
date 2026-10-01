import SwiftUI
import AppKit

// MARK: - Per-app settings window (HIG: Settings on macOS)
//
// A custom settings window contains a toolbar with buttons for switching between panes;
// the toolbar is noncustomizable, remains visible, and always indicates the active button;
// the window title reflects the visible pane; minimize/maximize are dimmed; the last viewed
// pane is restored. One real NSWindow per hosted app, so panes get full window width.

enum SettingsTab: Hashable {
    case graphics
    case bypasses
    case hacking
    case keymapping
    case info
    case container
}

/// Bridges the AppKit toolbar selection into the SwiftUI content.
@Observable
final class AppSettingsPaneCoordinator {
    var selection: SettingsTab {
        didSet { onChange?(selection) }
    }
    /// Wired by the window manager: syncs toolbar, title, and the last-pane default.
    var onChange: ((SettingsTab) -> Void)? = nil

    init(selection: SettingsTab) {
        self.selection = selection
    }

    static func title(for pane: SettingsTab) -> String {
        switch pane {
        case .graphics: NSLocalizedString("settings.tab.graphics", comment: "")
        case .bypasses: NSLocalizedString("settings.tab.bypasses", comment: "")
        case .hacking: "Hacking"
        case .keymapping: NSLocalizedString("settings.tab.km", comment: "")
        case .info: NSLocalizedString("settings.tab.info", comment: "")
        case .container: NSLocalizedString("settings.container.header", comment: "")
        }
    }

    static func symbol(for pane: SettingsTab) -> String {
        switch pane {
        case .graphics: "display"
        case .bypasses: "lock.shield"
        case .hacking: "terminal"
        case .keymapping: "keyboard"
        case .info: "info.circle"
        case .container: "internaldrive"
        }
    }

    static func itemID(for pane: SettingsTab) -> NSToolbarItem.Identifier {
        switch pane {
        case .graphics: .init("pane.graphics")
        case .bypasses: .init("pane.bypasses")
        case .hacking: .init("pane.hacking")
        case .keymapping: .init("pane.keymapping")
        case .info: .init("pane.info")
        case .container: .init("pane.container")
        }
    }

    static func pane(for itemID: NSToolbarItem.Identifier) -> SettingsTab? {
        switch itemID.rawValue {
        case "pane.graphics": .graphics
        case "pane.bypasses": .bypasses
        case "pane.hacking": .hacking
        case "pane.keymapping": .keymapping
        case "pane.info": .info
        case "pane.container": .container
        default: nil
        }
    }

    static let orderedPanes: [SettingsTab] = [.graphics, .bypasses, .hacking, .keymapping, .container, .info]
}

/// Root hosted in the settings window. Owns the keymap sheet (so the in-settings keymap button
/// presents on this window) and forwards the toolbar-driven pane binding.
private struct AppSettingsWindowRoot: View {
    let app: HostedApp
    @Bindable var coordinator: AppSettingsPaneCoordinator
    let onClose: () -> Void
    @State private var showKeymapSheet = false

    var body: some View {
        AppSettingsView(viewModel: AppSettingsVM(app: app),
                        showKeymapSheet: $showKeymapSheet,
                        selectedTab: $coordinator.selection,
                        onClose: onClose)
            .sheet(isPresented: $showKeymapSheet) {
                KeymapView(showKeymapSheet: $showKeymapSheet, viewModel: KeymapViewVM(app: app))
            }
    }
}

final class AppSettingsWindowManager: NSObject, NSToolbarDelegate, NSWindowDelegate {
    nonisolated(unsafe) static let shared = AppSettingsWindowManager()

    private var windows: [String: NSWindow] = [:]
    private var coordinators: [String: AppSettingsPaneCoordinator] = [:]

    private func defaultsKey(for bundleID: String) -> String {
        "AppSettingsPane.\(bundleID)"
    }

    private func restoredPane(for bundleID: String) -> SettingsTab {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey(for: bundleID)),
              let pane = AppSettingsPaneCoordinator.pane(for: NSToolbarItem.Identifier(raw)) else { return .graphics }
        return pane
    }

    func show(app: HostedApp) {
        let bid = app.info.bundleIdentifier
        if let existing = windows[bid] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let coordinator = AppSettingsPaneCoordinator(selection: restoredPane(for: bid))
        coordinators[bid] = coordinator

        // Fixed-size, non-resizable settings window. Pinned via min==max content size because
        // NSHostingController resizes its window to track SwiftUI ideal size as it settles.
        let fixedSize = NSSize(width: 840, height: 640)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: fixedSize),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = AppSettingsPaneCoordinator.title(for: coordinator.selection)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.standardWindowButton(.miniaturizeButton)?.isEnabled = false

        let root = AppSettingsWindowRoot(app: app, coordinator: coordinator, onClose: { [weak window] in
            window?.close()
        })
        window.contentViewController = NSHostingController(rootView: root)

        let toolbar = NSToolbar(identifier: "AppSettingsPanes")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        toolbar.selectedItemIdentifier = AppSettingsPaneCoordinator.itemID(for: coordinator.selection)

        coordinator.onChange = { [weak self, weak window] pane in
            toolbar.selectedItemIdentifier = AppSettingsPaneCoordinator.itemID(for: pane)
            window?.title = AppSettingsPaneCoordinator.title(for: pane)
            if let self {
                UserDefaults.standard.set(AppSettingsPaneCoordinator.itemID(for: pane).rawValue,
                                          forKey: self.defaultsKey(for: bid))
            }
        }

        windows[bid] = window
        window.contentMinSize = fixedSize
        window.contentMaxSize = fixedSize
        if let parent = NSApp.mainWindow ?? NSApp.keyWindow {
            let topLeft = NSPoint(x: parent.frame.minX, y: parent.frame.maxY)
            window.setFrameTopLeftPoint(parent.cascadeTopLeft(from: topLeft))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        AppSettingsPaneCoordinator.orderedPanes.map { AppSettingsPaneCoordinator.itemID(for: $0) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar,
                 itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let pane = AppSettingsPaneCoordinator.pane(for: itemIdentifier) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = AppSettingsPaneCoordinator.title(for: pane)
        item.paletteLabel = item.label
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: AppSettingsPaneCoordinator.symbol(for: pane),
                             accessibilityDescription: item.label)
        item.target = self
        item.action = #selector(paneItemClicked(_:))
        return item
    }

    @objc private func paneItemClicked(_ sender: NSToolbarItem) {
        guard let pane = AppSettingsPaneCoordinator.pane(for: sender.itemIdentifier) else { return }
        for (bid, window) in windows where window.toolbar === sender.toolbar {
            coordinators[bid]?.selection = pane
            return
        }
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        for (bid, owned) in windows where owned === window {
            windows.removeValue(forKey: bid)
            coordinators.removeValue(forKey: bid)
            return
        }
    }
}

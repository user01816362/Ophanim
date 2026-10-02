//
//  OphanimApp.swift
//  Ophanim
//
//  App entry + headless MCP launch. `--mcp` runs the stdio/HTTP server instead of
//  SwiftUI; otherwise boots the GUI app, its menu commands, Settings, and the local
//  MCP endpoint.
//

import SwiftUI

/// Real entry point. When launched with `--mcp` we run a headless MCP server instead of the SwiftUI
/// app (so an MCP client can spawn this binary with no GUI / dock icon):
///   Ophanim --mcp                          → stdio transport (newline-delimited JSON-RPC)
///   Ophanim --mcp --http [--port N] [--bind loopback|all|<ip>]
///                                          → headless HTTP transport (blocking). Supplying --port
///                                            or --bind implies --http.
@main
enum OphanimMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--mcp") {
            let port = argValue(args, "--port").flatMap { UInt16($0) }
            let bind = argValue(args, "--bind")
            let httpMode = args.contains("--http") || port != nil || bind != nil
            if httpMode {
                MCPHTTPTransport.shared.start(port: port, bind: bind)
                let t = MCPHTTPTransport.shared
                guard t.isRunning else {
                    FileHandle.standardError.write(Data("ophanim: MCP HTTP failed to bind\n".utf8))
                    exit(1)
                }
                FileHandle.standardError.write(
                    Data("ophanim: MCP HTTP listening on \(t.boundHost):\(t.boundPort)\n".utf8))
                dispatchMain()   // never returns
            }
            MCPStdioTransport.run()   // never returns
        }
        OphanimApp.main()
    }

    /// Value following a `--flag` on the command line, if present.
    private static func argValue(_ args: [String], _ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

/// GUI-app delegate: background-download drain, local MCP endpoint, low-power notice,
/// first-launch defaults. Headless `--mcp` never reaches here (OphanimMain exits first).
class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    @AppStorage("ShowLowPowerModeAlert") var showLowPowerModeAlert = true

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first {
            URLHandler.shared.processURL(url: url)
        }
    }

    /// Background URLSession drain: the system wakes us when source downloads
    /// finish while suspended. Stored until the session's didFinishEvents fires.
    var backgroundSessionCompletion: (() -> Void)?

    func application(_ application: NSApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        backgroundSessionCompletion = completionHandler
    }

    /// Launches the app GUI-side: local MCP endpoint (when enabled), crash-on-exception
    /// default, power noticer, icon-cache flush, and first-launch KeyCover note.
    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateScheme.checkForUpdate()

        // Local MCP endpoint on 127.0.0.1:20033 so an AI client can drive Ophanim while it runs.
        // Toggleable in Settings; defaults on.
        if UserDefaults.standard.object(forKey: "ophanim.mcp.http") as? Bool ?? true {
            MCPHTTPTransport.shared.start()
        }

        UserDefaults.standard.register(
            defaults: ["NSApplicationCrashOnExceptions": true]
        )

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(powerStateChanged),
                                               name: Notification.Name.NSProcessInfoPowerStateDidChange,
                                               object: nil)
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            // App init runs on the main thread; pin it explicitly (init cannot hop).
            MainDispatch.sync { MainActor.assumeIsolated { powerModal() } }
        }
        URLCache.iconCache.removeAllCachedResponses()
        // Code that run once on first launch
        let launchedBefore = UserDefaults.standard.bool(forKey: "launchedBefore")
        if !launchedBefore {
            UserDefaults.standard.set(true, forKey: "launchedBefore")

            // KeyCover (at-rest encryption of the emulated keychain) is intentionally left
            // DISABLED for Ophanim - an instrumentation tool wants keychain data visible, not
            // encrypted, and auto-enabling it would store a key in the macOS login keychain
            // (a launch-time prompt) for no benefit. Enable manually in Settings ▸ KeyCover if
            // ever needed.
        }

    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    @objc func powerStateChanged(_ notification: Notification) {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            Task { @MainActor in
                self.powerModal()
            }
        }
    }

    /// Warns on entering Low Power Mode (once; suppression-checked).
    @MainActor
    func powerModal() {
        if showLowPowerModeAlert {
            let (_, suppressed) = Log.modal(
                question: NSLocalizedString("alert.power.title", comment: ""),
                text: NSLocalizedString("alert.power.subtitle", comment: ""),
                style: .critical,
                buttons: [NSLocalizedString("button.OK", comment: "")],
                suppressionTooltip: "")
            // Suppression checked = don't show again: single-button modal returns
            // first-button, so the persisted flag is the inverse of suppressed.
            showLowPowerModeAlert = !suppressed
        }
    }
}

/// GUI app scene: library window, menu commands, Settings. Signing-sheet state lives
/// here so both the main view and the menu bar can present it.
struct OphanimApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State var isSigningSetupShown = false

    var body: some Scene {
        WindowGroup {
            MainView(isSigningSetupShown: $isSigningSetupShown)
                .environment(InstallVM.shared)
                .environment(AppsVM.shared)
                .environment(AppIntegrity())
                .onAppear {
                    NSWindow.allowsAutomaticWindowTabbing = false
                    SoundDeviceService.shared.prepareSoundDevice()
                    NotifyService.shared.allowNotify()
                }
        }
        .handlesExternalEvents(matching: ["{same path of URL?}"]) // create new window if doesn't exist
        .commands {
            SidebarCommands()
            OphanimMenuView(isSigningSetupShown: $isSigningSetupShown)
            OphanimHelpMenuView()
            OphanimViewMenuView()
        }

        Settings {
            OphanimSettingsView()
        }
    }
}

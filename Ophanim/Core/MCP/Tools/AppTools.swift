import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// App lifecycle tools. Sole caller of NSWorkspace/Installer from MCP.
enum AppTools {
    /// Whether the app is currently running (workspace check; pump-authoritative
    /// liveness arrives with the Inspect batch).
    static func isAppRunning(bundleID bid: String) -> Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bid })
        #else
        return false
        #endif
    }

    static func listApps(_ args: [String: Any]) throws -> String {
        let apps = AppQueryService.listApps().map { app -> [String: Any] in
            let cfg = SettingsStore.config(app.bundleID)
            return [
                "bundleID": app.bundleID,
                "name": app.name,
                "version": app.version,
                "instrumentationEnabled": cfg?.enabled ?? false,
                "captureCategories": cfg?.categories.map { $0.rawValue } ?? [],
                "running": isAppRunning(bundleID: app.bundleID)
            ]
        }
        return try ToolRouter.json(["count": apps.count, "apps": apps])
    }

    static func launchApp(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let url = AppQueryService.appURL(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        #if canImport(AppKit)
        // Go through the same launch path the app library uses, rather than opening the
        // bundle directly. This is what makes PROHIBITED/MALICIOUS gates and unlockKeyCover
        // binding on this tool. launch() itself is non-throwing (failures go to the log),
        // so the semaphore only bounds the wait.
        let app = HostedApp(appUrl: url)
        let sema = DispatchSemaphore(value: 0)
        Task {
            await app.launch()
            sema.signal()
        }
        if sema.wait(timeout: .now() + MCPTimeouts.launch) == .timedOut {
            throw ToolRouter.bail("launch did not finish within \(Int(MCPTimeouts.launch))s: \(bid)")
        }
        return "Launched \(bid)."
        #else
        throw ToolRouter.bail("launch is not supported in this build")
        #endif
    }

    static func installApp(_ args: [String: Any]) throws -> String {
        guard let path = args["ipaPath"] as? String, !path.isEmpty else { throw ToolRouter.bail("ipaPath is required") }
        let ipaURL = ToolRouter.expandedURL(path)
        guard FileManager.default.fileExists(atPath: ipaURL.path) else { throw ToolRouter.bail("no file at \(ipaURL.path)") }
        guard ipaURL.pathExtension.lowercased() == "ipa" else {
            throw ToolRouter.bail("expected an .ipa file, got \(ipaURL.lastPathComponent)")
        }
        #if canImport(AppKit)
        // Run the same importer the GUI uses, forcing Galgal injection (no modal prompt), and block
        // until it completes. Install is a long, one-shot operation, so allow generous headroom.
        let sema = DispatchSemaphore(value: 0)
        var installed: URL?
        Installer.install(ipaUrl: ipaURL, export: false, injectGalgal: true) { url in
            installed = url
            sema.signal()
        }
        guard sema.wait(timeout: .now() + MCPTimeouts.install) == .success else { throw ToolRouter.bail("install timed out") }
        guard let appURL = installed else { throw ToolRouter.bail("install failed - see the Ophanim log for details") }
        // Same boundary check as a source install: a bundle that is not a runnable
        // Catalyst app must fail stated here, not as "Installed" followed by a dead run.
        let bid = try IPAValidate.installedApp(at: appURL)
        return "Installed \(bid) from \(ipaURL.lastPathComponent). Configure it with set_config, then run launch_app."
        #else
        throw ToolRouter.bail("install is not supported in this build")
        #endif
    }

    static func uninstallApp(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard AppQueryService.appURL(bid) != nil else { throw ToolRouter.bail("app not installed: \(bid)") }
        let purge = (args["purgeData"] as? Bool) ?? false
        // dryRun defaults to true like every other destructive tool: pass false to delete.
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(AppQueryService.uninstallPreview(bid, purgeData: purge))
        }
        return try ToolRouter.json(AppQueryService.uninstall(bid, purgeData: purge))
    }
}

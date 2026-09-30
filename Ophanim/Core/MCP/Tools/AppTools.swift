import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// App lifecycle tools. Sole caller of NSWorkspace/Installer from MCP.
enum AppTools {
    static func listApps(_ args: [String: Any]) throws -> String {
        let apps = AppQueryService.listApps().map { app -> [String: Any] in
            let cfg = SettingsStore.config(app.bundleID)
            return [
                "bundleID": app.bundleID,
                "name": app.name,
                "version": app.version,
                "instrumentationEnabled": cfg?.enabled ?? false,
                "captureCategories": cfg?.categories.map { $0.rawValue } ?? []
            ]
        }
        return try ToolRouter.json(["count": apps.count, "apps": apps])
    }

    static func launchApp(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let url = AppQueryService.appURL(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        #if canImport(AppKit)
        let sema = DispatchSemaphore(value: 0)
        var launchError: Error?
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
            launchError = err; sema.signal()
        }
        _ = sema.wait(timeout: .now() + 15)
        if let launchError { throw ToolRouter.bail("launch failed: \(launchError.localizedDescription)") }
        return "Launched \(bid)."
        #else
        throw ToolRouter.bail("launch is not supported in this build")
        #endif
    }

    static func installApp(_ args: [String: Any]) throws -> String {
        guard let path = args["ipaPath"] as? String, !path.isEmpty else { throw ToolRouter.bail("ipaPath is required") }
        let ipaURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
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
        guard sema.wait(timeout: .now() + 600) == .success else { throw ToolRouter.bail("install timed out") }
        guard let appURL = installed else { throw ToolRouter.bail("install failed - see the Ophanim log for details") }
        let info = PlistReader.appInfoDict(at: appURL.appendingPathComponent("Info.plist"))
        let bid = (info["CFBundleIdentifier"] as? String) ?? appURL.deletingPathExtension().lastPathComponent
        return "Installed \(bid) from \(ipaURL.lastPathComponent). Configure it with set_config, then run launch_app."
        #else
        throw ToolRouter.bail("install is not supported in this build")
        #endif
    }

    static func uninstallApp(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard AppQueryService.appURL(bid) != nil else { throw ToolRouter.bail("app not installed: \(bid)") }
        let purge = (args["purgeData"] as? Bool) ?? false
        let removed = AppQueryService.uninstall(bid, purgeData: purge)
        return try ToolRouter.json(["bundleID": bid, "removed": removed, "purgedData": purge, "count": removed.count])
    }
}

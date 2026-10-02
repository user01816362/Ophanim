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

    /// Install/remove the Galgal runtime in an app's executable — the headless twin
    /// of the settings-window Galgal button (AppSettingsView install/remove + relist).
    /// Destructive (rewrites load commands): dryRun previews by default.
    static func setGalgalRuntime(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let exe = AppQueryService.appExecutable(bid) else { throw ToolRouter.bail("no executable for \(bid)") }
        guard let want = args["installed"] as? Bool else {
            throw ToolRouter.bail("installed is required (true = install Galgal, false = remove it)")
        }
        #if canImport(AppKit)
        let current = (try? Galgal.installedInExec(atURL: exe)) ?? false
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid,
                                 "current": current, "requested": want,
                                 "wouldChange": current != want])
        }
        if current == want {
            return try ToolRouter.json(["bundleID": bid, "installed": current, "changed": false])
        }
        let sema = DispatchSemaphore(value: 0)
        var installError: String?
        Task {
            if want {
                do { try await Galgal.installInIPA(exe) }
                catch { installError = error.localizedDescription }
            } else {
                await Galgal.removeFromApp(exe)
            }
            sema.signal()
        }
        sema.wait()
        if let err = installError { throw ToolRouter.bail("Galgal install failed: \(err)") }
        // Removal completes via an async finish-handle: settle-poll like
        // setInjectionStrategy before reporting.
        let deadline = Date().addingTimeInterval(MCPTimeouts.installSettle)
        var verified = false
        while Date() < deadline {
            if ((try? Galgal.installedInExec(atURL: exe)) ?? !want) == want { verified = true; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        var result: [String: Any] = ["bundleID": bid, "installed": want,
                                     "changed": true, "verified": verified]
        if !verified {
            result["note"] = "Runtime state did not settle within \(Int(MCPTimeouts.installSettle))s; check list_apps and relaunch."
        }
        return try ToolRouter.json(result)
        #else
        throw ToolRouter.bail("Galgal runtime management is not supported in this build")
        #endif
    }

    /// DYLD introspection/iosFrameworks toggles — headless twin of the Injected
    /// Libraries groupbox (BypassesPane). Re-signs the binary like the GUI path.
    /// Destructive (re-signs): dryRun previews by default. Takes effect on next launch.
    static func setDyldLibraries(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let url = AppQueryService.appURL(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        #if canImport(AppKit)
        let app = HostedApp(appUrl: url)
        func current(_ path: String) -> Bool {
            (app.info.lsEnvironment["DYLD_LIBRARY_PATH"] ?? "").contains(path)
        }
        var requested: [String: Bool] = [:]
        if let v = args["introspection"] as? Bool { requested["introspection"] = v }
        if let v = args["iosFrameworks"] as? Bool { requested["iosFrameworks"] = v }
        guard !requested.isEmpty else {
            throw ToolRouter.bail("nothing to change: pass introspection and/or iosFrameworks (true/false)")
        }
        let before = ["introspection": current(HostedApp.introspection),
                      "iosFrameworks": current(HostedApp.iosFrameworks)]
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid,
                                 "current": before, "requested": requested])
        }
        let sema = DispatchSemaphore(value: 0)
        Task {
            for (key, want) in requested {
                let path = key == "introspection" ? HostedApp.introspection : HostedApp.iosFrameworks
                _ = await app.changeDyldLibraryPath(set: want, path: path)
            }
            sema.signal()
        }
        sema.wait()
        return try ToolRouter.json(["bundleID": bid,
                             "current": ["introspection": current(HostedApp.introspection),
                                         "iosFrameworks": current(HostedApp.iosFrameworks)],
                             "changed": true,
                             "note": "Takes effect on next launch (load path is baked at exec)."])
        #else
        throw ToolRouter.bail("DYLD library management is not supported in this build")
        #endif
    }

    /// Application Category picker + re-sign — headless twin of the Application Type
    /// groupbox (BypassesPane). Destructive (re-signs the binary): dryRun previews.
    static func setAppCategory(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let url = AppQueryService.appURL(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        guard let exe = AppQueryService.appExecutable(bid) else { throw ToolRouter.bail("no executable for \(bid)") }
        guard let raw = args["category"] as? String, !raw.isEmpty,
              let cat = LSApplicationCategoryType(rawValue: raw) else {
            let valid = LSApplicationCategoryType.allCases.map(\.rawValue).sorted().joined(separator: ", ")
            throw ToolRouter.bail("category is required: one of \(valid)")
        }
        #if canImport(AppKit)
        let app = HostedApp(appUrl: url)
        let current = app.info.applicationCategoryType.rawValue
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid,
                                 "current": current, "requested": raw,
                                 "wouldChange": current != raw])
        }
        if current == raw {
            return try ToolRouter.json(["bundleID": bid, "category": raw, "changed": false])
        }
        app.info.applicationCategoryType = cat
        do { try Shell.signApp(exe) } catch {
            throw ToolRouter.bail("re-sign failed: \(error.localizedDescription) - category was set but the binary may be unsigned")
        }
        return try ToolRouter.json(["bundleID": bid, "category": raw, "changed": true, "resigned": true])
        #else
        throw ToolRouter.bail("app category management is not supported in this build")
        #endif
    }

    /// Trash per-app files left behind by uninstalled apps — headless twin of the
    /// prune-dangling-files setting (UninstallSettings). Destructive: dryRun previews.
    static func pruneFiles(_ args: [String: Any]) throws -> String {
        let (files, ids) = Uninstaller.pruneCandidates()
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "wouldTrash": files.map(\.path),
                                 "bundleIDs": ids, "count": files.count])
        }
        Uninstaller.pruneFiles()
        return try ToolRouter.json(["trashed": files.map(\.path), "bundleIDs": ids, "count": files.count])
    }
}

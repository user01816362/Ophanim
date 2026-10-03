//
//  AppTools.swift
//  Ophanim
//
//  App lifecycle tools. Sole caller of NSWorkspace/Installer from MCP.
//

import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// App lifecycle tools. Sole caller of NSWorkspace/Installer from MCP.
enum AppTools {

    // MARK: - Reads

    /// Whether the app is currently running.
    ///
    /// Workspace check only; pump-authoritative liveness arrives with the
    /// Inspect batch. Host-only (`canImport(AppKit)`); always false in other
    /// builds so agents must not treat false as "safe to skip launch".
    ///
    /// - Parameter bid: App bundle ID.
    /// - Returns: True when `NSWorkspace` reports the app running.
    static func isAppRunning(bundleID bid: String) -> Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bid })
        #else
        return false
        #endif
    }

    /// Lists known apps with instrumentation state.
    ///
    /// Read-only and idempotent. Read-only.
    ///
    /// - Parameter args: Ignored.
    /// - Returns: JSON with `count` and per-app `bundleID`, `name`,
    ///   `version`, `instrumentationEnabled`, `captureCategories`, `running`.
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

    /// Launches an installed app through the hosted-app path.
    ///
    /// Goes through the same launch path the app library uses (not the bundle
    /// directly) so PROHIBITED/MALICIOUS gates and unlockKeyCover binding
    /// apply. Host-only; waits up to `MCPTimeouts.launch` for completion.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: Confirmation string.
    /// - Throws: `ToolRouter.bail` when the app is not installed, the launch
    ///   times out, or the build cannot launch.
    // MARK: - Mutations (destructive: dryRun defaults true)

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
        // Deep-link test without touching the launch path: after the normal launch,
        // open a URL through LaunchServices (URL schemes + universal links). Command
        // -line args / env override stay unsupported on purpose — runAppExec clears
        // debug-affecting environment by design, and threading overrides through it
        // would punch holes in that guarantee.
        if let raw = args["openURL"] as? String, !raw.isEmpty {
            guard let deep = URL(string: raw), deep.scheme != nil else {
                throw ToolRouter.bail("openURL is not a valid URL with a scheme: \(raw)")
            }
            NSWorkspace.shared.open(deep)
            return "Launched \(bid) and opened \(raw)."
        }
        return "Launched \(bid)."
        #else
        throw ToolRouter.bail("launch is not supported in this build")
        #endif
    }

    /// Pump-aware liveness: workspace running flag PLUS the inspect gate PLUS the
    /// config switch. `list_apps.running` alone is blind post-launch (starting vs
    /// dead look identical); this answers "is it up AND instrumented".
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with `running`, `agentLive`, `instrumentationEnabled`.
    static func launchStatus(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        #if canImport(AppKit)
        let running = NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bid })
        #else
        let running = false
        #endif
        let agentLive = (try? InspectGate.requireLive(bundleID: bid)) != nil
        let enabled = SettingsStore.config(bid)?.enabled ?? false
        return try ToolRouter.json(["bundleID": bid, "running": running,
                             "agentLive": agentLive, "instrumentationEnabled": enabled])
    }

    /// Installs an .ipa with Galgal injection forced on.
    ///
    /// Runs the same importer the GUI uses (no modal prompt) and blocks until
    /// it completes. A bundle that is not a runnable Catalyst app fails here
    /// as a stated error, never as a phantom "Installed" row. Host-only.
    ///
    /// - Parameter args: `ipaPath` (required, must name an existing `.ipa`).
    /// - Returns: Confirmation naming the installed bundle ID and the
    ///   `set_config` → `launch_app` next steps.
    /// - Throws: `ToolRouter.bail` when the path is missing, not an `.ipa`,
    ///   the install times out or fails, validation rejects the bundle, or
    ///   the build cannot install.
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

    /// Uninstalls an app, optionally purging its data container.
    ///
    /// Destructive: `dryRun` defaults to true like every other destructive
    /// tool — pass `dryRun: false` to delete.
    ///
    /// - Parameter args: `bundleID` (required); `purgeData` (bool, default
    ///   false — also deletes the container); `dryRun: false` to execute.
    /// - Returns: Preview or result JSON from `AppQueryService`.
    /// - Throws: `ToolRouter.bail` when the app is not installed.
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

    /// Installs or removes the Galgal runtime in an app's executable.
    ///
    /// Headless twin of the settings-window Galgal button (AppSettingsView
    /// install/remove + relist). Destructive (rewrites load commands):
    /// `dryRun` previews by default. Removal settle-polls like
    /// `setInjectionStrategy` before reporting. Host-only.
    ///
    /// - Parameter args: `bundleID` (required); `installed` (bool, required:
    ///   true = install, false = remove); `dryRun: false` to execute.
    /// - Returns: Preview JSON (`current`, `requested`, `wouldChange`) or
    ///   result JSON (`installed`, `changed`, `verified`, plus a `note` when
    ///   the state did not settle in time).
    /// - Throws: `ToolRouter.bail` when the executable is missing, `installed`
    ///   is not a bool, install fails, or the build is unsupported.
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
        // Box, not a captured var: mutating a captured var makes the Task
        // closure non-Sendable under Swift 6 (same pattern as SourceTools.addSource).
        final class ErrorBox: @unchecked Sendable {
            var message: String?
        }
        let box = ErrorBox()
        Task {
            if want {
                do { try await Galgal.installInIPA(exe) }
                catch { box.message = error.localizedDescription }
            } else {
                await Galgal.removeFromApp(exe)
            }
            sema.signal()
        }
        sema.wait()
        if let err = box.message { throw ToolRouter.bail("Galgal install failed: \(err)") }
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

    /// Toggles DYLD introspection/iosFrameworks library paths.
    ///
    /// Headless twin of the Injected Libraries groupbox (BypassesPane).
    /// Re-signs the binary like the GUI path. Destructive (re-signs):
    /// `dryRun` previews by default. Takes effect on next launch (load path
    /// is baked at exec). Host-only.
    ///
    /// - Parameter args: `bundleID` (required); `introspection` and/or
    ///   `iosFrameworks` (bool, at least one required); `dryRun: false` to
    ///   execute.
    /// - Returns: Preview JSON (`current`, `requested`) or result JSON
    ///   (`current`, `changed`, plus a next-launch `note`).
    /// - Throws: `ToolRouter.bail` when nothing was requested or the build is
    ///   unsupported.
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

    /// Sets an app's Application Category and re-signs.
    ///
    /// Headless twin of the Application Type groupbox (BypassesPane).
    /// Destructive (re-signs the binary): `dryRun` previews. Host-only.
    ///
    /// - Parameter args: `bundleID` (required); `category` (required: an
    ///   `LSApplicationCategoryType` raw value); `dryRun: false` to execute.
    /// - Returns: Preview JSON (`current`, `requested`, `wouldChange`) or
    ///   result JSON (`category`, `changed`, `resigned`).
    /// - Throws: `ToolRouter.bail` when the app/executable is missing, the
    ///   category is unknown (the message lists valid values), re-sign fails,
    ///   or the build is unsupported.
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

    /// Trashes per-app files left behind by uninstalled apps.
    ///
    /// Headless twin of the prune-dangling-files setting
    /// (UninstallSettings). Destructive: `dryRun` previews.
    ///
    /// - Parameter args: `dryRun: false` to execute (no other keys read).
    /// - Returns: Preview JSON (`wouldTrash`, `bundleIDs`, `count`) or result
    ///   JSON (`trashed`, `bundleIDs`, `count`).
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

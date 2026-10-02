//
//  ConfigTools.swift
//  Ophanim
//
//  Config projection + patch tools. Field-level patch via SettingsStore;
//  hook/strategy writes take effect on relaunch, capture applies live.
//

import Foundation

/// Config projection + patch tools.
///
/// Reads mirror what `set_config` can write (grouped `instrumentation` +
/// `hosting`); writes persist to the per-app settings plist. Capture
/// categories apply live via the agent config poll, newly added hooks and
/// the injection strategy on next launch.
enum ConfigTools {

    // MARK: - Reads

    /// Reads an app's full per-app config as grouped JSON.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: Grouped JSON (`instrumentation` + `hosting`).
    /// - Throws: `ToolRouter.bail` when `bundleID` is missing or has no settings.
    static func getConfig(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let projection = SettingsStore.configProjection(bid) else { throw ToolRouter.bail("no settings found for \(bid)") }
        return try ToolRouter.json(projection)
    }

    // MARK: - Writes

    /// Modifies an app's per-app settings. Any omitted field is left unchanged.
    ///
    /// Unknown keys are rejected with a did-you-mean hint. Capture categories,
    /// rules, sinks, and pinning apply live; newly added hooks and the
    /// injection strategy take effect on next launch.
    ///
    /// - Parameter args: `bundleID` (required) plus any `SettingsStore.setConfigKeys`
    ///   field to patch.
    /// - Returns: `Updated. New config:` followed by the fresh projection JSON.
    /// - Throws: `ToolRouter.bail` on unknown keys or invalid values
    ///   (e.g. out-of-range `bodyCapBytes`, missing tweak folder).
    static func setConfig(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        try ToolRouter.rejectUnknownKeys(args, allowed: SettingsStore.setConfigKeys, tool: "set_config")
        try SettingsStore.updateSettings(bid) { try SettingsStore.applyPatch(args, to: &$0) }
        let body = SettingsStore.configProjection(bid).flatMap { try? ToolRouter.json($0) } ?? "{}"
        return "Updated. New config:\n" + body
    }

    /// Lists the jailbreak/root-detection SDKs Ophanim can bypass.
    ///
    /// - Parameter args: No arguments.
    /// - Returns: JSON with `count` and the `detectors` (`id` + `label`) list.
    static func listJailbreakDetectors(_ args: [String: Any]) throws -> String {
        let dets = JBBypassCatalog.all.map { ["id": $0.id, "label": $0.label] }
        return try ToolRouter.json(["count": dets.count, "detectors": dets])
    }

    /// Switches an app's injection strategy between embedded and sibling.
    ///
    /// Rewrites the binary load commands, then polls until they reflect the
    /// request (bounded by `MCPTimeouts.installSettle`). Destructive: dryRun
    /// previews by default.
    ///
    /// - Parameter args: `bundleID` (required); `strategy` (`embedded`/`sibling`,
    ///   required); `dryRun: false` executes.
    /// - Returns: Dry-run JSON with `wouldChange`, or the result with
    ///   `changed` + poll `verified`.
    /// - Throws: `ToolRouter.bail` when `strategy` is missing/invalid or the app
    ///   is not installed.
    static func setInjectionStrategy(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let raw = args["strategy"] as? String,
              let requested = OPInjectionStrategy(rawValue: raw) else {
            throw ToolRouter.bail("strategy is required: embedded or sibling")
        }
        guard let url = AppQueryService.appURL(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        guard let exe = AppQueryService.appExecutable(bid) else { throw ToolRouter.bail("no executable for \(bid)") }
        let current = SettingsStore.appSettings(bid)?.ophanim.injectionStrategy ?? .embedded
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "current": current.rawValue,
                                 "requested": requested.rawValue, "wouldChange": current != requested])
        }
        if current == requested {
            return try ToolRouter.json(["bundleID": bid, "strategy": requested.rawValue, "changed": false])
        }
        try SettingsStore.updateConfig(bid) { $0.injectionStrategy = requested }
        let app = HostedApp(appUrl: url)
        if app.hasGalgal() {
            switch requested {
            case .sibling: Galgal.installAgentInIPA(exe)
            case .embedded: Galgal.removeAgentFromApp(exe)
            }
        }
        // Poll until the load command reflects the request (or a 15s budget expires).
        // agentInstalledInExec throws when the binary cannot even be read, which is itself
        // the answer: desired=false is unreachable, desired=true is unreached.
        let deadline = Date().addingTimeInterval(MCPTimeouts.installSettle)
        var verified = false
        while Date() < deadline {
            let installed = (try? Galgal.agentInstalledInExec(atURL: exe)) ?? false
            if installed == (requested == .sibling) { verified = true; break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        var result: [String: Any] = ["bundleID": bid, "strategy": requested.rawValue,
                                     "changed": true, "verified": verified]
        if !verified {
            result["note"] = "Load commands did not settle within \(Int(MCPTimeouts.installSettle))s; check get_config and relaunch."
        }
        return try ToolRouter.json(result)
    }

    // MARK: - Keymaps

    /// Reads an app's active keymap blob. Read-only by design.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: The keymap JSON text.
    /// - Throws: `ToolRouter.bail` when the app is not installed or the keymap
    ///   cannot be encoded.
    static func getKeymap(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let url = AppQueryService.appURL(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        let app = HostedApp(appUrl: url)
        guard let data = try? JSONEncoder().encode(app.keymapping.keymapConfig),
              let text = String(data: data, encoding: .utf8) else {
            throw ToolRouter.bail("keymap for \(bid) could not be encoded")
        }
        return text
    }

    /// Headless keymap write (full-blob replace). The blob reuses the exact decode
    /// path the GUI uses, then goes through the validated writer: name gate, enforced
    /// bundle binding, backup-before-write, atomic replace. dryRun previews by default.
    ///
    /// - Parameter args: `bundleID` (required); `name` (required); `keymap`
    ///   (full Keymap object, required); `allowBundleMismatch` (default false).
    /// - Returns: JSON with counts, `wouldOverwrite`, and (on write) the written
    ///   path + backup path.
    /// - Throws: `ToolRouter.bail` when `name`/`keymap` is missing, the blob does
    ///   not decode, or validation refuses the write — nothing is written.
    static func setKeymap(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let name = args["name"] as? String, !name.isEmpty else {
            throw ToolRouter.bail("name is required")
        }
        guard let dict = args["keymap"] as? [String: Any] else {
            throw ToolRouter.bail("keymap (object, full Keymap JSON) is required")
        }
        let map: Keymap
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            map = try JSONDecoder().decode(Keymap.self, from: data)
        } catch {
            throw ToolRouter.bail("keymap does not decode: \(error.localizedDescription) - nothing written")
        }
        guard let url = AppQueryService.appURL(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        let app = HostedApp(appUrl: url)
        let dryRun = ToolRouter.isDryRun(args)
        let allowMismatch = (args["allowBundleMismatch"] as? Bool) ?? false
        let report: Keymapping.ValidatedKeymapWrite
        do {
            report = try app.keymapping.writeValidatedKeymap(name: name, map: map,
                                                             allowBundleMismatch: allowMismatch,
                                                             dryRun: dryRun)
        } catch let e as NSError {
            throw ToolRouter.bail("\(e.localizedDescription) - nothing written")
        }
        var payload: [String: Any] = ["bundleID": bid, "name": name,
                             "buttons": report.buttons,
                             "draggableButtons": report.draggableButtons,
                             "joysticks": report.joysticks,
                             "mouseAreas": report.mouseAreas,
                             "bundleIdentifier": report.bundleIdentifier,
                             "wouldOverwrite": report.wouldOverwrite]
        if dryRun {
            payload["dryRun"] = true
        } else {
            payload["written"] = report.url?.path ?? ""
            payload["replaced"] = report.wouldOverwrite
            if let backup = report.backupURL?.path { payload["backup"] = backup }
        }
        return try ToolRouter.json(payload)
    }

    /// Reset an app's settings to defaults — headless twin of the settings-window
    /// reset button (AppSettings.reset). Destructive: dryRun previews by default.
    /// The bundle binding is preserved (GUI drops it; the store backfills it).
    ///
    /// - Parameter args: `bundleID` (required); `dryRun: false` executes.
    /// - Returns: Dry-run JSON with `wouldReset`, or confirmation JSON.
    /// - Throws: `ToolRouter.bail` when the app has no settings.
    static func resetSettings(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard SettingsStore.appSettings(bid) != nil else {
            throw ToolRouter.bail("no settings found for \(bid)")
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "wouldReset": true])
        }
        try SettingsStore.updateSettings(bid) {
            $0 = AppSettingsData()
            $0.bundleIdentifier = bid
        }
        return try ToolRouter.json(["bundleID": bid, "reset": true])
    }

    /// List an app's keymap files — headless twin of the keymap library rows
    /// (KeymapView). Read-only.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with the `keymaps` (`name`, `bytes`, `default`) and `count`.
    /// - Throws: `ToolRouter.bail` when the app is not installed.
    static func listKeymaps(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let url = AppQueryService.appURL(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        let app = HostedApp(appUrl: url)
        let dir = Keymapping.keymappingDir.appendingPathComponent(bid)
        let def = app.keymapping.keymapConfig.defaultKm.deletingPathExtension().lastPathComponent
        var maps: [[String: Any]] = []
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for f in entries where f.pathExtension == "plist" && f.lastPathComponent != ".config.plist" {
                let size = (try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let name = f.deletingPathExtension().lastPathComponent
                maps.append(["name": name, "bytes": size ?? 0, "default": name == def])
            }
        }
        maps.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        return try ToolRouter.json(["bundleID": bid, "keymaps": maps, "count": maps.count])
    }

    /// Rename a keymap file (updates the order list too). Destructive: dryRun previews.
    ///
    /// - Parameter args: `bundleID` (required); `name` + `newName` (required);
    ///   `dryRun: false` executes.
    /// - Returns: Dry-run JSON, or confirmation with `from`/`to`.
    /// - Throws: `ToolRouter.bail` when names are missing, the app is not
    ///   installed, or the rename fails.
    static func renameKeymap(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let from = args["name"] as? String, !from.isEmpty,
              let to = args["newName"] as? String, !to.isEmpty else {
            throw ToolRouter.bail("name and newName are required")
        }
        guard let url = AppQueryService.appURL(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "from": from, "to": to])
        }
        let app = HostedApp(appUrl: url)
        guard app.keymapping.renameKeymap(prevName: from, newName: to) else {
            throw ToolRouter.bail("rename failed for '\(from)' - see the Ophanim log")
        }
        return try ToolRouter.json(["bundleID": bid, "from": from, "to": to, "renamed": true])
    }

    /// Delete a keymap file (trash). Refuses the default keymap like the GUI
    /// context menu does. Destructive: dryRun previews.
    ///
    /// - Parameter args: `bundleID` (required); `name` (required);
    ///   `dryRun: false` executes.
    /// - Returns: Dry-run JSON, or confirmation with the deleted `name`.
    /// - Throws: `ToolRouter.bail` when `name` is missing, names the default
    ///   keymap, the app is not installed, or the delete fails.
    static func deleteKeymap(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let name = args["name"] as? String, !name.isEmpty else {
            throw ToolRouter.bail("name is required")
        }
        guard let url = AppQueryService.appURL(bid) else { throw ToolRouter.bail("app not installed: \(bid)") }
        let app = HostedApp(appUrl: url)
        let def = app.keymapping.keymapConfig.defaultKm.deletingPathExtension().lastPathComponent
        if name == def {
            throw ToolRouter.bail("'\(name)' is the default keymap - pick another default first")
        }
        if ToolRouter.isDryRun(args) {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "name": name])
        }
        guard app.keymapping.deleteKeymap(name: name) else {
            throw ToolRouter.bail("delete failed for '\(name)' - see the Ophanim log")
        }
        return try ToolRouter.json(["bundleID": bid, "name": name, "deleted": true])
    }
}

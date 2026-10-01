import Foundation

/// Config projection + patch tools.
enum ConfigTools {
    static func getConfig(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let projection = SettingsStore.configProjection(bid) else { throw ToolRouter.bail("no settings found for \(bid)") }
        return try ToolRouter.json(projection)
    }

    static func setConfig(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        try ToolRouter.rejectUnknownKeys(args, allowed: SettingsStore.setConfigKeys, tool: "set_config")
        try SettingsStore.updateSettings(bid) { try SettingsStore.applyPatch(args, to: &$0) }
        let body = SettingsStore.configProjection(bid).flatMap { try? ToolRouter.json($0) } ?? "{}"
        return "Updated. New config:\n" + body
    }

    static func listJailbreakDetectors(_ args: [String: Any]) throws -> String {
        let dets = JBBypassCatalog.all.map { ["id": $0.id, "label": $0.label] }
        return try ToolRouter.json(["count": dets.count, "detectors": dets])
    }

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
}

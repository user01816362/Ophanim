import Foundation

/// Rule preset + rule-replace tools. Preset dicts + rule merge/replace.
enum RuleTools {
    static func listPresets(_ args: [String: Any]) throws -> String {
        return try ToolRouter.json(["presets": [
            ["name": "block-trackers", "description": "Block network requests to known tracker/analytics/ad hosts"],
            ["name": "fake-idfv", "description": "Return a fixed fake identifierForVendor"],
            ["name": "fake-idfa", "description": "Return a fixed fake advertising identifier"]
        ]])
    }

    static func applyPreset(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let name = args["preset"] as? String else { throw ToolRouter.bail("preset is required") }
        let dicts = try Self.presetRules(name)
        let data = try JSONSerialization.data(withJSONObject: dicts)
        let preset = try JSONDecoder().decode([OPRule].self, from: data)
        var finalCount = 0
        try SettingsStore.updateSettings(bid) { s in
            let ids = Set(s.ophanim.rules.map { $0.id })
            s.ophanim.rules.append(contentsOf: preset.filter { !ids.contains($0.id) })
            finalCount = s.ophanim.rules.count
        }
        return "Applied preset '\(name)' (\(preset.count) rule(s)); \(bid) now has \(finalCount) rule(s)."
    }

    static func setRules(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let rulesArg = args["rules"] else { throw ToolRouter.bail("rules array is required") }
        let rules: [OPRule] = try ToolRouter.decode(rulesArg, label: "rules")
        try SettingsStore.updateSettings(bid) { $0.ophanim.rules = rules }
        return "Set \(rules.count) rule(s) for \(bid)."
    }

    /// Rule dictionaries for a named preset (decoded into [OPRule] by applyPreset).
    private static func presetRules(_ name: String) throws -> [[String: Any]] {
        switch name {
        case "block-trackers":
            let domains = ReportBuilder.trackerCatalog.keys.map { "\"\($0)\"" }.joined(separator: ",")
            let js = "var t=[\(domains)];if(ctx.host){for(var i=0;i<t.length;i++)" +
                     "{if(ctx.host.indexOf(t[i])>=0){ctx.block=true;break;}}}"
            return [["id": "op-block-trackers", "enabled": true, "note": "Block known tracker/analytics/ad hosts",
                     "match": ["categories": ["network"]],
                     "action": ["kind": "script", "script": js]]]
        case "fake-idfv":
            return [["id": "op-fake-idfv", "enabled": true, "note": "Fake identifierForVendor",
                     "match": ["apiGlob": "UIDevice.identifierForVendor"],
                     "action": ["kind": "script", "script": "ctx.returnValue='00000000-0000-0000-0000-0000DEADBEEF';"]]]
        case "fake-idfa":
            return [["id": "op-fake-idfa", "enabled": true, "note": "Fake advertising identifier",
                     "match": ["apiGlob": "ASIdentifierManager.advertisingIdentifier"],
                     "action": ["kind": "script", "script": "ctx.returnValue='00000000-0000-0000-0000-00000000AD1D';"]]]
        default:
            throw ToolRouter.ToolError(message: "unknown preset '\(name)' - use list_presets")
        }
    }
}

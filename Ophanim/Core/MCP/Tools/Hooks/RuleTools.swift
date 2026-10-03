//
//  RuleTools.swift
//  Ophanim
//
//  Rule preset + rule-replace tools. Preset dicts + rule merge/replace.
//

import Foundation
import JavaScriptCore

/// Rule preset + rule-replace tools. Preset dicts + rule merge/replace.
///
/// Hook/rule writers use explicit-true preview like the hook setters
/// (omitted `dryRun` = apply, the historical contract).
enum RuleTools {

    // MARK: - Reads

    /// Lists the built-in rule presets.
    ///
    /// Read-only. No parameters are read.
    ///
    /// - Parameter args: Ignored.
    /// - Returns: JSON with `presets` (name + description each).
    static func listPresets(_ args: [String: Any]) throws -> String {
        return try ToolRouter.json(["presets": [
            ["name": "block-trackers", "description": "Block network requests to known tracker/analytics/ad hosts"],
            ["name": "fake-idfv", "description": "Return a fixed fake identifierForVendor"],
            ["name": "fake-idfa", "description": "Return a fixed fake advertising identifier"],
            ["name": "block-host", "description": "Block one host (glob). Parameters: {host} (required).",
             "parameters": ["host"]],
            ["name": "fake-device-id", "description": "Fake identifierForVendor with your value. Parameters: {value} (UUID string, required).",
             "parameters": ["value"]]
        ]])
    }

    /// Merges a named preset's rules into an app's rule list.
    ///
    /// Merge, not replace: preset rules whose ids already exist are skipped,
    /// so re-applying a preset is idempotent.
    ///
    /// - Parameter args: `bundleID` (required); `preset` (required: one of
    ///   `block-trackers`, `fake-idfv`, `fake-idfa`); `dryRun: true` reports
    ///   which ids would merge vs skip without persisting.
    /// - Returns: Confirmation string with final rule count, or dry-run JSON
    ///   with `wouldAdd` and `skipped`.
    /// - Throws: `ToolRouter.bail` when `bundleID`/`preset` is missing or the
    ///   preset name is unknown.
    // MARK: - Preset apply

    static func applyPreset(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let name = args["preset"] as? String else { throw ToolRouter.bail("preset is required") }
        // frida-trace -P analogue: templated presets take string parameters.
        let params = (args["parameters"] as? [String: String]) ?? [:]
        let dicts = try Self.presetRules(name, parameters: params)
        let data = try JSONSerialization.data(withJSONObject: dicts)
        let preset = try JSONDecoder().decode([OPRule].self, from: data)
        // Explicit-true preview like the hook setters (omitted = apply, the
        // historical contract): report which ids would merge vs skip.
        if args["dryRun"] as? Bool == true {
            let existing = Set(SettingsStore.appSettings(bid)?.ophanim.rules.map { $0.id } ?? [])
            let wouldAdd = preset.map(\.id).filter { !existing.contains($0) }
            let skipped = preset.map(\.id).filter { existing.contains($0) }
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "preset": name,
                                 "wouldAdd": wouldAdd, "skipped": skipped])
        }
        var finalCount = 0
        try SettingsStore.updateSettings(bid) { s in
            let ids = Set(s.ophanim.rules.map { $0.id })
            s.ophanim.rules.append(contentsOf: preset.filter { !ids.contains($0.id) })
            finalCount = s.ophanim.rules.count
        }
        return "Applied preset '\(name)' (\(preset.count) rule(s)); \(bid) now has \(finalCount) rule(s)."
    }

    /// Replaces an app's full interception rule list.
    ///
    /// Full replace: the given array becomes the rule list (unlike
    /// `applyPreset`, which merges). Observe-by-default — with no rules every
    /// hook only logs.
    ///
    /// - Parameter args: `bundleID` (required); `rules` ([OPRule] array,
    ///   required); `dryRun: true` previews the count without persisting.
    /// - Returns: Confirmation string, or dry-run JSON with `wouldSet`.
    /// - Throws: `ToolRouter.bail` when `bundleID`/`rules` is missing or undecodable.
    // MARK: - Writes (explicit-true preview)

    static func setRules(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let rulesArg = args["rules"] else { throw ToolRouter.bail("rules array is required") }
        let rules: [OPRule] = try ToolRouter.decode(rulesArg, label: "rules")
        if args["dryRun"] as? Bool == true {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid, "wouldSet": rules.count])
        }
        try SettingsStore.updateSettings(bid) { $0.ophanim.rules = rules }
        return "Set \(rules.count) rule(s) for \(bid)."
    }

    /// Syntax-checks a JS rule body without writing anything.
    ///
    /// The source is wrapped in an uncalled function so it PARSES but never
    /// executes (no stub-ctx side effects, no infinite-loop risk from
    /// top-level code). Scripts using top-level `return` fail validation —
    /// the rule contract is ctx mutation
    /// (`ctx.block`/`ctx.returnValue`/…), matching `OPInterceptor.runScript`,
    /// so that rejection is correct. Read-only.
    ///
    /// - Parameter args: `script` (JS source, required, non-empty).
    /// - Returns: JSON with `valid` plus `error` when invalid.
    /// - Throws: `ToolRouter.bail` when `script` is missing or empty.
    // MARK: - Script validation

    static func validateRuleScript(_ args: [String: Any]) throws -> String {
        guard let source = args["script"] as? String, !source.isEmpty else {
            throw ToolRouter.bail("script is required")
        }
        let ctx = JSContext()
        var syntaxError: String?
        ctx?.exceptionHandler = { _, exc in
            syntaxError = exc?.toString()
        }
        ctx?.evaluateScript("function __ophanim_validate(){\n" + source + "\n}")
        if let err = syntaxError {
            return try ToolRouter.json(["valid": false, "error": err])
        }
        return try ToolRouter.json(["valid": true])
    }

    /// Rule dictionaries for a named preset.
    ///
    /// Decoded into `[OPRule]` by `applyPreset`.
    ///
    /// - Parameter name: One of `block-trackers`, `fake-idfv`, `fake-idfa`.
    /// - Returns: Array of rule dictionaries.
    /// - Throws: `ToolError` for an unknown preset name.
    // MARK: - Private preset data

    private static func presetRules(_ name: String, parameters: [String: String] = [:]) throws -> [[String: Any]] {
        switch name {
        case "block-trackers":
            let domains = ReportBuilder.trackerCatalog.keys.map { "\"\($0)\"" }.joined(separator: ",")
            // Lowercase once: Swift matching is case-insensitive, JS indexOf is not.
            let js = "var t=[\(domains)];var h=(ctx.host||'').toLowerCase();for(var i=0;i<t.length;i++)" +
                     "{if(h.indexOf(t[i])>=0){ctx.block=true;break;}}}"
            return [["id": "op-block-trackers", "enabled": true, "note": "Block known tracker/analytics/ad hosts (breaks deep-link resolution + in-app ads while active)",
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
        case "block-host":
            guard let host = parameters["host"], !host.isEmpty else {
                throw ToolRouter.bail("preset 'block-host' needs parameters.host (e.g. {\"host\": \"ads.example.com\"})")
            }
            // OPGlob has no escape syntax (* and ? are always wildcards): reject
            // metacharacters so a literal host can never widen into a broad block.
            if host.contains(where: { "*?[]".contains($0) }) {
                throw ToolRouter.bail("parameters.host must be a literal host (no *?[] wildcards)")
            }
            return [["id": "op-block-host", "enabled": true, "note": "Block host '\(host)'",
                     "match": ["categories": ["network"], "hostGlob": "*\(host)*"],
                     "action": ["kind": "block"]]]
        case "fake-device-id":
            guard let value = parameters["value"], !value.isEmpty else {
                throw ToolRouter.bail("preset 'fake-device-id' needs parameters.value (a UUID string)")
            }
            // Quote-strip: the value lands inside a JS string literal; a quote would
            // break the script (fail-safe via the JS exception path, but reject early).
            let safe = value.replacingOccurrences(of: "'", with: "")
            return [["id": "op-fake-device-id", "enabled": true, "note": "Fake identifierForVendor",
                     "match": ["apiGlob": "UIDevice.identifierForVendor"],
                     "action": ["kind": "script", "script": "ctx.returnValue='\(safe)';"]]]
        default:
            throw ToolRouter.ToolError(message: "unknown preset '\(name)' - use list_presets")
        }
    }
}

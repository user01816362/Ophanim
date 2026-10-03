//
//  ToolRouter.swift
//  Ophanim
//
//  Host-only MCP tool plumbing. Single owner of arg decode, bail errors, and
//  JSON output plus the name→handler table; tool logic lives in Tools/*.
//

import Foundation

/// Single owner for tool arg decode, errors, and JSON output.
/// Tool family files call these; the router owns the name→handler table.
enum ToolRouter {

    // MARK: - Decoding, errors, safety contracts

    struct ToolError: Error { let message: String }

    static func bail(_ message: String) -> ToolError { ToolError(message: message) }

    /// Decode a JSON-object argument into `T`, throwing a `bail("invalid <label>: …")` on failure.
    ///
    /// - Parameter obj: The raw argument value (array or object from `args`).
    /// - Parameter label: The argument name used in the refusal message.
    /// - Returns: The decoded value.
    /// - Throws: `ToolRouter.bail` when the value does not decode as `T`.
    static func decode<T: Decodable>(_ obj: Any, as type: T.Type = T.self, label: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: try JSONSerialization.data(withJSONObject: obj)) }
        catch { throw bail("invalid \(label): \(error.localizedDescription)") }
    }

    /// Renders a JSON-compatible object as pretty-printed text for a tool result.
    ///
    /// - Parameter obj: Dictionary or array from a tool handler.
    /// - Returns: The JSON string (`"{}"` when encoding somehow fails).
    /// - Throws: Rethrows `JSONSerialization` errors on non-encodable input.
    static func json(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Requires a non-empty `bundleID` argument.
    ///
    /// - Parameter args: The tool's `args` dict.
    /// - Returns: The bundle identifier.
    /// - Throws: `ToolRouter.bail` (`bundleID is required`) when missing or empty.
    static func requireBundleID(_ args: [String: Any]) throws -> String {
        guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
        return bid
    }

    /// Expand a user-supplied path (tilde + standardize) into a file URL.
    ///
    /// - Parameter path: The raw path (a leading `~` is expanded).
    /// - Returns: The standardized file URL.
    static func expandedURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// JSON numbers arrive as Int or Double depending on the client — and some
    /// bridges deliver them as numeric strings. Accept all three so a valid
    /// coordinate never fails as "required in 0...1" on type alone.
    ///
    /// - Parameter args: The tool's `args` dict.
    /// - Parameter key: The numeric argument name.
    /// - Returns: The value as a `Double`, or nil when absent or non-numeric.
    static func coerceDouble(_ args: [String: Any], _ key: String) -> Double? {
        if let d = args[key] as? Double { return d }
        if let i = args[key] as? Int { return Double(i) }
        if let s = args[key] as? String { return Double(s) }
        return nil
    }

    /// Integer twin of coerceDouble (limits, steps: a client may send 8.0 for 8,
    /// or "8" through a string-typed bridge).
    ///
    /// - Parameter args: The tool's `args` dict.
    /// - Parameter key: The integer argument name.
    /// - Returns: The value as an `Int`, or nil when absent or non-numeric.
    static func coerceInt(_ args: [String: Any], _ key: String) -> Int? {
        if let i = args[key] as? Int { return i }
        if let d = args[key] as? Double { return Int(d) }
        if let s = args[key] as? String { return Int(s) ?? Double(s).map(Int.init) }
        return nil
    }

    /// Destructive tools preview by default (OLD safety contract): pass
    /// dryRun:false to execute. Omitted dryRun previews; nothing is deleted.
    /// Only for tools that route through this helper — the hook/rule writers
    /// use the opposite explicit-true contract (omitted writes).
    ///
    /// - Parameter args: The tool's `args` dict.
    /// - Returns: True unless `dryRun` is explicitly false.
    static func isDryRun(_ args: [String: Any]) -> Bool { (args["dryRun"] as? Bool) ?? true }

    // MARK: - Argument validation

    /// Reject unknown argument names, naming the closest match when there is one.
    ///
    /// - Parameter args: The tool's `args` dict.
    /// - Parameter allowed: The accepted argument names for this tool.
    /// - Parameter tool: The wire name used in the refusal message.
    /// - Throws: `ToolRouter.bail` listing the unknown names (plus a
    ///   did-you-mean hint and the accepted list) when any is present.
    static func rejectUnknownKeys(_ args: [String: Any], allowed: Set<String>, tool: String) throws {
        let unknown = args.keys.filter { !allowed.contains($0) }.sorted()
        guard !unknown.isEmpty else { return }

        var message = "\(tool): unknown argument"
        message += unknown.count == 1 ? " " : "s "
        message += unknown.map { "'\($0)'" }.joined(separator: ", ")

        let suggestions = unknown.compactMap { key -> String? in
            guard let best = allowed.min(by: { editDistance(key, $0) < editDistance(key, $1) }),
                  editDistance(key, best) <= max(2, key.count / 3) else { return nil }
            return "'\(key)' -> did you mean '\(best)'?"
        }
        if !suggestions.isEmpty { message += "; " + suggestions.joined(separator: "; ") }

        let known = allowed.subtracting(["bundleID"]).sorted()
        message += ". Accepted arguments: \(known.joined(separator: ", "))."
        throw bail(message)
    }

    /// Plain Levenshtein distance. Argument names are short and this runs once per call.
    private static func editDistance(_ first: String, _ second: String) -> Int {
        let x = Array(first), y = Array(second)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            previous = current
        }
        return previous[y.count]
    }

    // MARK: - Name to handler table

    /// Name → handler. Only file that knows tool names besides the catalog.
    nonisolated(unsafe) static let handlers: [String: ([String: Any]) throws -> String] = [
        "list_apps": AppTools.listApps,
        "launch_app": AppTools.launchApp,
        "launch_status": AppTools.launchStatus,
        "install_app": AppTools.installApp,
        "uninstall_app": AppTools.uninstallApp,
        "set_galgal_runtime": AppTools.setGalgalRuntime,
        "set_dyld_libraries": AppTools.setDyldLibraries,
        "set_app_category": AppTools.setAppCategory,
        "prune_files": AppTools.pruneFiles,
        "query_events": EventTools.queryEvents,
        "tail_events": EventTools.tailEvents,
        "export_curl": EventTools.exportCurl,
        "subscribe_events": EventTools.subscribeEvents,
        "unsubscribe_events": EventTools.unsubscribeEvents,
        "analyze_app": ReconTools.analyzeApp,
        "app_imports": ReconTools.appImports,
        "find_symbols": ReconTools.findSymbols,
        "suggest_hooks": SuggestTools.suggestHooks,
        "list_libraries": ReconTools.listLibraries,
        "scan_signature": ReconTools.scanSignature,
        "set_objc_hooks": HookTools.setObjcHooks,
        "remove_hook": HookTools.removeHook,
        "get_hooks": HookTools.getHooks,
        "set_swift_hooks": HookTools.setSwiftHooks,
        "set_inline_hooks": HookTools.setInlineHooks,
        "list_presets": RuleTools.listPresets,
        "apply_preset": RuleTools.applyPreset,
        "set_rules": RuleTools.setRules,
        "remove_rule": RuleTools.removeRule,
        "set_rule_enabled": RuleTools.setRuleEnabled,
        "validate_rule_script": RuleTools.validateRuleScript,
        "get_config": ConfigTools.getConfig,
        "set_config": ConfigTools.setConfig,
        "reset_settings": ConfigTools.resetSettings,
        "list_keymaps": ConfigTools.listKeymaps,
        "rename_keymap": ConfigTools.renameKeymap,
        "delete_keymap": ConfigTools.deleteKeymap,
        "list_jailbreak_detectors": ConfigTools.listJailbreakDetectors,
        "list_sources": SourceTools.listSources,
        "search_source_apps": SourceTools.searchSourceApps,
        "refresh_sources": SourceTools.refreshSources,
        "rename_source": SourceTools.renameSource,
        "edit_source_url": SourceTools.editSourceURL,
        "reset_sources": SourceTools.resetSources,
        "source_transfer": SourceTools.sourceTransfer,
        "add_source": SourceTools.addSource,
        "remove_source": SourceTools.removeSource,
        "install_source_app": SourceTools.installSourceApp,
        "list_tweaks": TweakTools.listTweaks,
        "inspect_tweak": TweakTools.inspectTweak,
        "add_tweak": TweakTools.addTweak,
        "move_tweak": TweakTools.moveTweak,
        "remove_tweak": TweakTools.removeTweak,
        "set_tweak_enabled": TweakTools.setTweakEnabled,
        "tweak_folder": TweakTools.tweakFolder,
        "resync_tweaks": TweakTools.resyncTweaks,
        "get_log_path": ContainerTools.getLogPath,
        "sqlite_tables": ContainerTools.sqliteTables,
        "sqlite_rows": ContainerTools.sqliteRows,
        "keychain_items": ContainerTools.keychainItems,
        "container_read": ContainerTools.containerRead,
        "set_pref": ContainerTools.setPref,
        "clear_logs": ContainerTools.clearLogs,
        "container_info": ContainerTools.containerInfo,
        "list_profiles": ContainerTools.listProfiles,
        "create_profile": ContainerTools.createProfile,
        "switch_profile": ContainerTools.switchProfile,
        "remove_profile": ContainerTools.removeProfile,
        "clear_container": ContainerTools.clearContainer,
        "backup_container": ContainerTools.backupContainer,
        "restore_container": ContainerTools.restoreContainer,
        "list_classes": ReconTools.listClasses,
        "set_injection_strategy": ConfigTools.setInjectionStrategy,
        "get_keymap": ConfigTools.getKeymap,
        "set_keymap": ConfigTools.setKeymap,
        "tool_matrix": { _ in try ToolRouter.json(ToolRouter.matrix()) },
    ]

    /// Machine-readable tool contract matrix: readOnly/destructive annotations
    /// plus dryRun behavior per tool. dryRun families (verified against handler
    /// bodies — update these sets when adding a mutating tool):
    /// - "default": omitted dryRun previews (isDryRun contract).
    /// - "explicit": only dryRun:true previews; omitted WRITES (legacy hook/rule writers).
    /// - "none": acts immediately, no preview branch.
    /// - "na": read-only, nothing to preview.
    static func matrix() -> [String: Any] {
        let explicit: Set<String> = ["set_objc_hooks", "set_swift_hooks", "set_inline_hooks",
                                     "set_rules", "apply_preset"]
        let none: Set<String> = ["launch_app", "install_app", "resync_tweaks",
                                  "refresh_sources", "subscribe_events", "unsubscribe_events",
                                  "set_config", "tap_element", "swipe", "set_text", "tap_and_read"]
        var tools: [[String: Any]] = []
        for name in handlers.keys.sorted() {
            let readOnly = MCPServer.readOnlyTools.contains(name)
            var dryRun = "na"
            if !readOnly {
                if explicit.contains(name) { dryRun = "explicit" }
                else if none.contains(name) { dryRun = "none" }
                else { dryRun = "default" }
            }
            tools.append(["name": name, "readOnly": readOnly,
                          "destructive": MCPServer.destructiveTools.contains(name),
                          "dryRun": dryRun])
        }
        return ["count": tools.count, "tools": tools]
    }
}

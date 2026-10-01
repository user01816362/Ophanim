import Foundation

/// Single owner for tool arg decode, errors, and JSON output.
/// Tool family files call these; the router owns the name→handler table.
enum ToolRouter {
    struct ToolError: Error { let message: String }

    static func bail(_ m: String) -> ToolError { ToolError(message: m) }

    /// Decode a JSON-object argument into `T`, throwing a `bail("invalid <label>: …")` on failure.
    static func decode<T: Decodable>(_ obj: Any, as type: T.Type = T.self, label: String) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: try JSONSerialization.data(withJSONObject: obj)) }
        catch { throw bail("invalid \(label): \(error.localizedDescription)") }
    }

    static func json(_ obj: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes])
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func requireBundleID(_ args: [String: Any]) throws -> String {
        guard let bid = args["bundleID"] as? String, !bid.isEmpty else { throw bail("bundleID is required") }
        return bid
    }

    /// Expand a user-supplied path (tilde + standardize) into a file URL.
    static func expandedURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    /// JSON numbers arrive as Int or Double depending on the client: accept both.
    static func coerceDouble(_ args: [String: Any], _ key: String) -> Double? {
        (args[key] as? Double) ?? (args[key] as? Int).map(Double.init)
    }

    /// Integer twin of coerceDouble (limits, steps: a client may send 8.0 for 8).
    static func coerceInt(_ args: [String: Any], _ key: String) -> Int? {
        (args[key] as? Int) ?? (args[key] as? Double).map(Int.init)
    }

    /// Destructive tools preview by default (OLD safety contract): pass
    /// dryRun:false to execute. Omitted dryRun previews; nothing is deleted.
    static func isDryRun(_ args: [String: Any]) -> Bool { (args["dryRun"] as? Bool) ?? true }

    /// Reject unknown argument names, naming the closest match when there is one.
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
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
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

    /// Name → handler. Only file that knows tool names besides the catalog.
    nonisolated(unsafe) static let handlers: [String: ([String: Any]) throws -> String] = [
        "list_apps": AppTools.listApps,
        "launch_app": AppTools.launchApp,
        "install_app": AppTools.installApp,
        "uninstall_app": AppTools.uninstallApp,
        "query_events": EventTools.queryEvents,
        "tail_events": EventTools.tailEvents,
        "subscribe_events": EventTools.subscribeEvents,
        "unsubscribe_events": EventTools.unsubscribeEvents,
        "analyze_app": ReconTools.analyzeApp,
        "app_imports": ReconTools.appImports,
        "find_symbols": ReconTools.findSymbols,
        "set_objc_hooks": HookTools.setObjcHooks,
        "set_swift_hooks": HookTools.setSwiftHooks,
        "set_inline_hooks": HookTools.setInlineHooks,
        "list_presets": RuleTools.listPresets,
        "apply_preset": RuleTools.applyPreset,
        "set_rules": RuleTools.setRules,
        "get_config": ConfigTools.getConfig,
        "set_config": ConfigTools.setConfig,
        "list_jailbreak_detectors": ConfigTools.listJailbreakDetectors,
        "list_sources": SourceTools.listSources,
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
    ]
}

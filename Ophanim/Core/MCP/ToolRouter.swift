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

    /// Name → handler. Only file that knows tool names besides the catalog.
    nonisolated(unsafe) static let handlers: [String: ([String: Any]) throws -> String] = [
        "list_apps": AppTools.listApps,
        "launch_app": AppTools.launchApp,
        "install_app": AppTools.installApp,
        "uninstall_app": AppTools.uninstallApp,
        "query_events": EventTools.queryEvents,
        "tail_events": EventTools.tailEvents,
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
    ]
}

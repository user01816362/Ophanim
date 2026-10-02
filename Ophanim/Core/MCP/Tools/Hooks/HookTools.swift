import Foundation

/// Hook-installation tools. Codable hook-array decode + settings write.
///
/// dryRun note: unlike most destructive tools these WRITERS honor dryRun only
/// when it is explicitly true (omitted = write, the historical contract —
/// agents already call set_*_hooks/set_rules without dryRun:false and flipping
/// the default would silently turn their writes into previews). Pass
/// dryRun:true to preview counts/validation without persisting.
enum HookTools {
    static func setObjcHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let hooksArg = args["hooks"] else { throw ToolRouter.bail("hooks array is required") }
        let hooks: [OPObjCHook] = try ToolRouter.decode(hooksArg, label: "hooks")
        if args["dryRun"] as? Bool == true {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid,
                                 "wouldSet": hooks.count, "kind": "objc"])
        }
        try SettingsStore.updateSettings(bid) { $0.ophanim.objcHooks = hooks }
        return "Set \(hooks.count) ObjC boundary hook(s) for \(bid)."
    }

    static func setSwiftHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let hooksArg = args["hooks"] else { throw ToolRouter.bail("hooks array is required") }
        let hooks: [OPSwiftHook] = try ToolRouter.decode(hooksArg, label: "hooks")
        if args["dryRun"] as? Bool == true {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid,
                                 "wouldSet": hooks.count, "kind": "swift"])
        }
        try SettingsStore.updateSettings(bid) { $0.ophanim.swiftHooks = hooks }
        return "Set \(hooks.count) native-Swift vtable hook(s) for \(bid)."
    }

    static func setInlineHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let hooksArg = args["hooks"] else { throw ToolRouter.bail("hooks array is required") }
        let hooks: [OPInlineHook] = try ToolRouter.decode(hooksArg, label: "hooks")
        if args["dryRun"] as? Bool == true {
            return try ToolRouter.json(["dryRun": true, "bundleID": bid,
                                 "wouldSet": hooks.count, "kind": "inline",
                                 "gateOn": SettingsStore.appSettings(bid)?.ophanim.enableInlineHooks ?? false])
        }
        try SettingsStore.updateSettings(bid) { $0.ophanim.inlineHooks = hooks }
        let gate = (SettingsStore.appSettings(bid)?.ophanim.enableInlineHooks ?? false)
        return "Set \(hooks.count) inline hook(s) for \(bid)."
            + (gate ? "" : " NOTE: inline hooks are OFF - call set_config enableInlineHooks=true to arm them.")
    }

    /// Lightweight hooks reader. get_config already carries these arrays inside
    /// `instrumentation`, but agents managing hooks shouldn't pay for the full
    /// hosting dump on every poll — this returns just the three hook arrays
    /// plus the inline gate. Read-only.
    static func getHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let cfg = SettingsStore.config(bid) else {
            throw ToolRouter.bail("no settings found for \(bid)")
        }
        func asArray<T: Encodable>(_ value: [T]) -> [[String: Any]] {
            (try? JSONEncoder().encode(value))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        }
        return try ToolRouter.json([
            "bundleID": bid,
            "enableInlineHooks": cfg.enableInlineHooks,
            "objcHooks": asArray(cfg.objcHooks),
            "swiftHooks": asArray(cfg.swiftHooks),
            "inlineHooks": asArray(cfg.inlineHooks),
        ])
    }
}

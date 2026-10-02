//
//  HookTools.swift
//  Ophanim
//
//  Hook-installation tools. Codable hook-array decode + settings write.
//

import Foundation

/// Hook-installation tools. Codable hook-array decode + settings write.
///
/// Unlike most destructive tools these WRITERS honor dryRun only
/// when it is explicitly true (omitted = write, the historical contract —
/// agents already call set_*_hooks/set_rules without dryRun:false and flipping
/// the default would silently turn their writes into previews). Pass
/// dryRun:true to preview counts/validation without persisting.
enum HookTools {
    /// Replaces the ObjC boundary hooks for an app.
    ///
    /// Swizzles (className, selector) pairs and logs the call plus its object
    /// args. Pure-Swift (non-@objc) methods are not reachable this way —
    /// those need inline hooking.
    ///
    /// - Parameter args: `bundleID` (required); `hooks` ([OPObjCHook] array,
    ///   required); `dryRun: true` previews the count without persisting.
    /// - Returns: Confirmation string, or dry-run JSON with `wouldSet`.
    /// - Throws: `ToolRouter.bail` when `bundleID`/`hooks` is missing or undecodable.
    // MARK: - Writes (explicit-true preview)

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

    /// Replaces the native-Swift vtable hooks for an app.
    ///
    /// Patches an overridable Swift method's vtable slot to log the call and
    /// pass through. Reaches non-@objc Swift that ObjC swizzling cannot — but
    /// only methods dispatched through the vtable (polymorphic/cross-module;
    /// `-O` may devirtualize concrete calls).
    ///
    /// - Parameter args: `bundleID` (required); `hooks` ([OPSwiftHook] array,
    ///   required); `dryRun: true` previews the count without persisting.
    /// - Returns: Confirmation string, or dry-run JSON with `wouldSet`.
    /// - Throws: `ToolRouter.bail` when `bundleID`/`hooks` is missing or undecodable.
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

    /// Replaces the Tier-3 inline (machine-code) hooks for an app.
    ///
    /// arm64 only; gated behind `OPConfig.enableInlineHooks` (live code
    /// patching). When the gate is off the hooks persist but stay dormant,
    /// and the result carries a NOTE telling the agent how to arm them.
    ///
    /// - Parameter args: `bundleID` (required); `hooks` ([OPInlineHook] array,
    ///   required); `dryRun: true` previews the count and gate state without
    ///   persisting.
    /// - Returns: Confirmation string (plus arming NOTE when the gate is off),
    ///   or dry-run JSON with `wouldSet` and `gateOn`.
    /// - Throws: `ToolRouter.bail` when `bundleID`/`hooks` is missing or undecodable.
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

    /// Reads back just the three hook arrays plus the inline gate.
    ///
    /// `get_config` already carries these arrays inside `instrumentation`,
    /// but agents managing hooks should not pay for the full hosting dump on
    /// every poll. Read-only.
    ///
    /// - Parameter args: `bundleID` (required).
    /// - Returns: JSON with `bundleID`, `enableInlineHooks`, `objcHooks`,
    ///   `swiftHooks`, `inlineHooks`.
    /// - Throws: `ToolRouter.bail` when `bundleID` is missing or the app has
    ///   no settings.
    // MARK: - Reads

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

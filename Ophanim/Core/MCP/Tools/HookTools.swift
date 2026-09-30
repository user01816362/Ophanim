import Foundation

/// Hook-installation tools. Codable hook-array decode + settings write.
enum HookTools {
    static func setObjcHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let hooksArg = args["hooks"] else { throw ToolRouter.bail("hooks array is required") }
        let hooks: [OPObjCHook] = try ToolRouter.decode(hooksArg, label: "hooks")
        try SettingsStore.updateSettings(bid) { $0.ophanim.objcHooks = hooks }
        return "Set \(hooks.count) ObjC boundary hook(s) for \(bid)."
    }

    static func setSwiftHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let hooksArg = args["hooks"] else { throw ToolRouter.bail("hooks array is required") }
        let hooks: [OPSwiftHook] = try ToolRouter.decode(hooksArg, label: "hooks")
        try SettingsStore.updateSettings(bid) { $0.ophanim.swiftHooks = hooks }
        return "Set \(hooks.count) native-Swift vtable hook(s) for \(bid)."
    }

    static func setInlineHooks(_ args: [String: Any]) throws -> String {
        let bid = try ToolRouter.requireBundleID(args)
        guard let hooksArg = args["hooks"] else { throw ToolRouter.bail("hooks array is required") }
        let hooks: [OPInlineHook] = try ToolRouter.decode(hooksArg, label: "hooks")
        try SettingsStore.updateSettings(bid) { $0.ophanim.inlineHooks = hooks }
        let gate = (SettingsStore.appSettings(bid)?.ophanim.enableInlineHooks ?? false)
        return "Set \(hooks.count) inline hook(s) for \(bid)."
            + (gate ? "" : " NOTE: inline hooks are OFF - call set_config enableInlineHooks=true to arm them.")
    }
}

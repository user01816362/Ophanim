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
}
